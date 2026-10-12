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
  ) => stream(path, Stream.value(request), options);
  ResponseStream<List<int>> stream(
    String path,
    Stream<List<int>> requests,
    CallOptions options,
  ) => $createStreamingCall(
    ClientMethod<List<int>, List<int>>(path, (v) => v, (v) => v),
    requests,
    options: options,
  );
}

/// Limits bound both the local queue and gRPC's transport-owned outgoing buffer.
abstract final class RequestStreamLimits {
  static const messages = 1000,
      wireBytes = 64 * 1024 * 1024,
      jsonBytes = 64 * 1024 * 1024;
  static const queuedMessages = 64, queuedBytes = 32 * 1024 * 1024;
}

/// A live request stream: send snapshots, then explicitly half-close it.
class RequestStreamCall {
  final ProtoCodec codec;
  final ProtoMethod method;
  final _requests = StreamController<List<int>>();
  late final Future<CallResult> result;
  bool _inputClosed = false, _completed = false;
  int _sentCount = 0,
      _sentBytes = 0,
      _jsonBytes = 0,
      _queuedCount = 0,
      _queuedBytes = 0;
  bool get inputClosed => _inputClosed;
  bool get completed => _completed;
  int get sentCount => _sentCount;
  int get queuedCount => _queuedCount;
  int get queuedBytes => _queuedBytes;
  RequestStreamCall._(this.codec, this.method);
  Stream<List<int>> get requests => _requests.stream.map((bytes) {
    _queuedCount--;
    _queuedBytes -= bytes.length;
    return bytes;
  });
  void send(Object? message) {
    if (_inputClosed || _completed) {
      throw StateError('Request send side is closed');
    }
    final bytes = codec.encode(method.input, message);
    final size = utf8.encode(jsonEncode(message)).length;
    if (_sentCount >= RequestStreamLimits.messages ||
        _sentBytes + bytes.length > RequestStreamLimits.wireBytes ||
        _jsonBytes + size > RequestStreamLimits.jsonBytes) {
      throw const GrpcError.resourceExhausted(
        'Request stream exceeds 1000 messages or 64 MiB',
      );
    }
    if (_queuedCount >= RequestStreamLimits.queuedMessages ||
        _queuedBytes + bytes.length > RequestStreamLimits.queuedBytes) {
      throw const GrpcError.resourceExhausted(
        'Send queue is full (64 messages / 32 MiB); wait before sending again',
      );
    }
    _sentCount++;
    _sentBytes += bytes.length;
    _jsonBytes += size;
    _queuedCount++;
    _queuedBytes += bytes.length;
    _requests.add(bytes);
  }

  void finishSending() {
    if (_inputClosed) return;
    _inputClosed = true;
    // Closing queues the half-close after every previously accepted message.
    // A channel that never subscribed must not block cancellation cleanup.
    unawaited(_requests.close());
  }

  void _complete() {
    _completed = true;
    finishSending();
  }
}

class GrpcEngine {
  final ProtoLoader loader;
  ClientChannel? _channel;
  ConnectionConfig? _config;
  SchemaRegistry schema = SchemaRegistry();
  final _calls = <ResponseStream<List<int>>>{};
  final _outgoing = <RequestStreamCall>{};
  int _generation = 0;
  GrpcEngine(this.loader);
  Future<void> disconnect() async {
    _generation++;
    for (final outgoing in _outgoing.toList()) {
      outgoing._complete();
    }
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
    if (method.clientStreaming) {
      if (method.serverStreaming) {
        return const CallResult(
          [],
          'UNIMPLEMENTED',
          'Bidirectional streaming is pending the next increment',
          0,
          {},
          {},
        );
      }
      try {
        final stream = startClientStream(
          method,
          metadata: metadata,
          timeoutMs: timeoutMs,
          authority: authority,
          onMessage: onMessage,
        );
        try {
          stream.send(body);
          stream.finishSending();
        } catch (_) {
          await cancel();
          rethrow;
        }
        return await stream.result;
      } catch (e) {
        final grpc = e is GrpcError
            ? e
            : GrpcError.invalidArgument(e.toString());
        return CallResult(
          [],
          _code(grpc.code),
          grpc.message ?? '',
          clock.elapsedMilliseconds,
          {},
          {},
        );
      }
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
    return _invokeEncoded(
      method,
      Stream.value(bytes),
      metadata: metadata,
      timeoutMs: timeoutMs,
      authority: authority,
      onMessage: onMessage,
    );
  }

  RequestStreamCall startClientStream(
    ProtoMethod method, {
    Map<String, String> metadata = const {},
    int timeoutMs = 5000,
    String authority = '',
    void Function(Object? message)? onMessage,
  }) {
    if (!method.clientStreaming) {
      throw const GrpcError.invalidArgument('Method has no streaming request');
    }
    if (method.serverStreaming) {
      throw const GrpcError.unimplemented(
        'Bidirectional streaming is pending the next increment',
      );
    }
    if (_channel == null || _config == null) {
      throw const GrpcError.failedPrecondition('No server connected');
    }
    final stream = RequestStreamCall._(ProtoCodec(schema), method);
    _outgoing.add(stream);
    stream.result =
        _invokeEncoded(
          method,
          stream.requests,
          metadata: metadata,
          timeoutMs: timeoutMs,
          authority: authority,
          onMessage: onMessage,
        ).whenComplete(() {
          stream._complete();
          _outgoing.remove(stream);
        });
    return stream;
  }

  Future<CallResult> _invokeEncoded(
    ProtoMethod method,
    Stream<List<int>> requests, {
    required Map<String, String> metadata,
    required int timeoutMs,
    required String authority,
    void Function(Object? message)? onMessage,
  }) async {
    final clock = Stopwatch()..start();
    final codec = ProtoCodec(schema);
    final messages = <Object?>[];
    final headers = <String, String>{}, trailers = <String, String>{};
    final temporary = authority.isEmpty ? null : _create(_config!, authority);
    final channel = temporary ?? _channel!;
    final call = DynamicClient(channel).stream(
      method.path,
      requests,
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
