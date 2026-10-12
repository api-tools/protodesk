import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grpc/grpc.dart';

import '../schema/schema.dart';
import '../schema/codec.dart';
import '../schema/wire.dart';
import '../schema/proto_loader.dart';

class ConnectionConfig {
  final String address;
  final bool tls, reflection;
  final List<String> files, folders;
  final Map<String, String> metadata;
  final List<int>? certificates;
  const ConnectionConfig(
    this.address, {
    this.tls = false,
    this.reflection = true,
    this.files = const [],
    this.folders = const [],
    this.metadata = const {},
    this.certificates,
  });
  (String, int) get endpoint {
    final uri = Uri.tryParse('http://$address');
    if (address.contains('://') ||
        uri == null ||
        uri.host.isEmpty ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.path.isNotEmpty) {
      throw const FormatException(
        'Server address must be host:port (port 1–65535)',
      );
    }
    return (uri.host, uri.port);
  }
}

class DiscoveryResult {
  final SchemaRegistry schema;
  final String source, warning;
  DiscoveryResult(this.schema, this.source, this.warning);
}

class CallResult {
  final List<Object?> messages;
  final String code, error;
  final int durationMs;
  final Map<String, String> headers, trailers;
  const CallResult(
    this.messages,
    this.code,
    this.error,
    this.durationMs,
    this.headers,
    this.trailers,
  );
}

class DynamicClient extends Client {
  DynamicClient(super.channel);
  ResponseStream<List<int>> call(
    String path,
    List<int> request,
    CallOptions options,
  ) => $createStreamingCall(
    ClientMethod<List<int>, List<int>>(path, (v) => v, (v) => v),
    Stream.value(request),
    options: options,
  );
}

class GrpcEngine {
  final ProtoLoader loader;
  ClientChannel? _channel;
  ConnectionConfig? _config;
  SchemaRegistry schema = SchemaRegistry();
  final _calls = <ResponseStream<List<int>>>{};
  int _generation = 0;
  GrpcEngine(this.loader);
  Future<void> disconnect() async {
    _generation++;
    for (final call in _calls.toList()) {
      await call.cancel();
    }
    _calls.clear();
    final channel = _channel;
    _channel = null;
    _config = null;
    schema = SchemaRegistry();
    await channel?.shutdown();
  }

  ClientChannel _create(ConnectionConfig config, [String? authority]) {
    final (host, port) = config.endpoint;
    return ClientChannel(
      host,
      port: port,
      options: ChannelOptions(
        connectTimeout: const Duration(seconds: 5),
        credentials: config.tls
            ? ChannelCredentials.secure(
                certificates: config.certificates,
                authority: authority,
              )
            : ChannelCredentials.insecure(authority: authority),
      ),
    );
  }

  Future<DiscoveryResult> connect(ConnectionConfig config) async {
    await disconnect();
    final generation = _generation;
    final (host, port) = config.endpoint;
    // Probe with the same TLS trust rules before recording a connected state.
    final socket = config.tls
        ? await SecureSocket.connect(
            host,
            port,
            timeout: const Duration(seconds: 5),
            context: config.certificates == null
                ? null
                : (SecurityContext()
                    ..setTrustedCertificatesBytes(config.certificates!)),
            supportedProtocols: ['h2'],
          )
        : await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    socket.destroy();
    if (generation != _generation) {
      throw const GrpcError.cancelled('Connection superseded');
    }
    final channel = _create(config);
    _channel = channel;
    _config = config;
    var registry = SchemaRegistry();
    var source = 'none';
    var warning = '';
    try {
      if (config.reflection) {
        try {
          registry = await _reflect(channel, config.metadata);
          source = 'reflection';
        } catch (e) {
          warning = 'Reflection unavailable: $e';
        }
      }
      if (source == 'none' &&
          (config.files.isNotEmpty || config.folders.isNotEmpty)) {
        try {
          registry = await loader.load(config.files, config.folders);
          source = 'proto';
        } catch (e) {
          warning = '$warning\nProto sources unavailable: $e'.trim();
        }
      }
      if (generation != _generation) {
        throw const GrpcError.cancelled('Connection superseded');
      }
      schema = registry;
      return DiscoveryResult(registry, source, warning);
    } catch (_) {
      await channel.shutdown();
      if (identical(_channel, channel)) _channel = null;
      rethrow;
    }
  }

  Future<SchemaRegistry> _reflect(
    ClientChannel channel,
    Map<String, String> metadata,
  ) async {
    Object? last;
    for (final version in ['v1', 'v1alpha']) {
      try {
        final registry = SchemaRegistry();
        final client = DynamicClient(channel);
        Future<Map<int, List<Object>>> query(int field, String value) async {
          final w = WireWriter()..text(field, value);
          final call = client.call(
            '/grpc.reflection.$version.ServerReflection/ServerReflectionInfo',
            w.finish(),
            CallOptions(
              timeout: const Duration(seconds: 5),
              metadata: metadata,
            ),
          );
          _calls.add(call);
          try {
            final response = WireReader(await call.single).fields();
            if (response.containsKey(7)) {
              throw GrpcError.custom(
                response.messages(7).first.integer(1),
                response.messages(7).first.text(2),
              );
            }
            return response;
          } finally {
            await call.cancel();
            _calls.remove(call);
          }
        }

        final list = await query(7, '');
        final services = list
            .messages(6)
            .expand((m) => m.messages(1))
            .map((m) => m.text(1))
            .where((n) => !n.startsWith('grpc.reflection.'))
            .toList();
        for (final service in services) {
          final response = await query(4, service);
          for (final file
              in response.messages(4).expand((m) => m[1] ?? <Object>[])) {
            registry.addFile(file as List<int>);
          }
        }
        // Some servers omit cached dependencies; request unresolved files explicitly.
        final visited = <String>{};
        while (true) {
          final missing = <String>{};
          for (final file in registry.files.values) {
            for (final dep in WireReader(file).fields()[3] ?? <Object>[]) {
              final name = utf8.decode(dep as List<int>);
              if (!registry.files.containsKey(name)) missing.add(name);
            }
          }
          if (missing.isEmpty) break;
          for (final name in missing) {
            if (!visited.add(name)) {
              throw FormatException('Missing reflection dependency $name');
            }
            final response = await query(3, name);
            for (final file
                in response.messages(4).expand((m) => m[1] ?? <Object>[])) {
              registry.addFile(file as List<int>);
            }
          }
        }
        registry.validate();
        return registry;
      } catch (e) {
        last = e;
      }
    }
    throw last!;
  }

  Future<CallResult> invoke(
    ProtoMethod method,
    Object? body, {
    Map<String, String> metadata = const {},
    int timeoutMs = 5000,
    String authority = '',
    void Function(Object? message)? onMessage,
  }) async {
    final clock = Stopwatch()..start();
    final messages = <Object?>[];
    final headers = <String, String>{};
    final trailers = <String, String>{};
    if (method.clientStreaming) {
      return CallResult(
        [],
        'UNIMPLEMENTED',
        method.serverStreaming
            ? 'Bidirectional streaming is unsupported'
            : 'Client streaming is unsupported',
        0,
        {},
        {},
      );
    }
    if (_channel == null || _config == null) {
      return const CallResult(
        [],
        'FAILED_PRECONDITION',
        'No server connected',
        0,
        {},
        {},
      );
    }
    final codec = ProtoCodec(schema);
    List<int> bytes;
    try {
      bytes = codec.encode(method.input, body);
    } catch (e) {
      return CallResult(
        [],
        'INVALID_ARGUMENT',
        e.toString(),
        clock.elapsedMilliseconds,
        {},
        {},
      );
    }
    final temporary = authority.isEmpty ? null : _create(_config!, authority);
    final channel = temporary ?? _channel!;
    final call = DynamicClient(channel).call(
      method.path,
      bytes,
      CallOptions(
        timeout: Duration(milliseconds: timeoutMs > 0 ? timeoutMs : 5000),
        metadata: {..._config!.metadata, ...metadata},
      ),
    );
    _calls.add(call);
    var code = 'OK', error = '';
    var bufferedBytes = 0;
    final headerFuture = call.headers.then(
      (v) => headers.addAll(v),
      onError: (Object _) {},
    );
    try {
      await for (final data in call) {
        bufferedBytes += data.length;
        if (bufferedBytes > 64 * 1024 * 1024) {
          throw const GrpcError.resourceExhausted(
            'Response buffer exceeds 64 MiB',
          );
        }
        if (messages.length == 1000) {
          throw const GrpcError.resourceExhausted(
            'Server stream exceeds 1000 messages',
          );
        }
        final message = codec.decode(method.output, data);
        messages.add(message);
        onMessage?.call(message);
        if (!method.serverStreaming && messages.length > 1) {
          throw const GrpcError.internal(
            'Unary method returned multiple messages',
          );
        }
      }
    } catch (e) {
      final grpc = e is GrpcError ? e : GrpcError.internal(e.toString());
      code = _code(grpc.code);
      error = grpc.message ?? '';
    } finally {
      await headerFuture;
      try {
        trailers.addAll(await call.trailers);
      } catch (_) {}
      await call.cancel();
      _calls.remove(call);
      await temporary?.shutdown();
    }
    return CallResult(
      messages,
      code,
      error,
      clock.elapsedMilliseconds,
      headers,
      trailers,
    );
  }

  Future<void> cancel() async {
    for (final c in _calls.toList()) {
      await c.cancel();
    }
  }

  String _code(int code) => const [
    'OK',
    'CANCELLED',
    'UNKNOWN',
    'INVALID_ARGUMENT',
    'DEADLINE_EXCEEDED',
    'NOT_FOUND',
    'ALREADY_EXISTS',
    'PERMISSION_DENIED',
    'RESOURCE_EXHAUSTED',
    'FAILED_PRECONDITION',
    'ABORTED',
    'OUT_OF_RANGE',
    'UNIMPLEMENTED',
    'INTERNAL',
    'UNAVAILABLE',
    'DATA_LOSS',
    'UNAUTHENTICATED',
  ][code.clamp(0, 16)];
}
