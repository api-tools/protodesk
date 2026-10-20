import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart' as http2;

import 'tls_identity.dart';

import '../schema/schema.dart';
import '../schema/codec.dart';
import '../schema/wire.dart';
import '../schema/proto_loader.dart';

class ConnectionConfig {
  final String address;
  final bool tls, reflection;
  final List<String> files, folders;
  final Map<String, String> metadata;
  final Map<String, String>? reflectionMetadata;
  final TlsIdentity? identity;
  final String serverName;
  final List<int>? certificates;
  final SchemaRegistry? localSchema;
  final Future<SchemaRegistry> Function()? schemaProvider;
  const ConnectionConfig(
    this.address, {
    this.tls = false,
    this.reflection = true,
    this.files = const [],
    this.folders = const [],
    this.metadata = const {},
    this.certificates,
    this.identity,
    this.serverName = '',
    this.reflectionMetadata,
    this.localSchema,
    this.schemaProvider,
  });
  SecurityContext? get securityContext {
    if (!tls) {
      if (identity != null) {
        throw const FormatException('Client identity requires TLS');
      }
      return null;
    }
    if (identity != null) return identity!.context(certificates);
    final context = SecurityContext(withTrustedRoots: certificates == null);
    if (certificates != null) {
      context.setTrustedCertificatesBytes(certificates!);
    }
    context.setAlpnProtocols(['h2'], false);
    return context;
  }

  Future<Socket> openSocket([String? authority]) async {
    final (host, port) = endpoint;
    final context = securityContext;
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    if (context == null) return socket;
    try {
      // Preserve the legacy authority-as-TLS-name behavior unless an explicit
      // TLS server name is configured. HTTP/2 authority remains independent.
      return await SecureSocket.secure(
        socket,
        host: serverName.isNotEmpty ? serverName : authority ?? host,
        context: context,
        supportedProtocols: ['h2'],
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

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

class _Connector implements ClientTransportConnector {
  final ConnectionConfig config;
  final String? overrideAuthority;
  Socket? socket;
  _Connector(this.config, this.overrideAuthority);
  @override
  String get authority => overrideAuthority ?? config.address;
  @override
  Future<http2.ClientTransportConnection> connect() async {
    final connected = await config.openSocket(overrideAuthority);
    socket = connected;
    connected.setOption(SocketOption.tcpNoDelay, true);
    return http2.ClientTransportConnection.viaSocket(connected);
  }

  @override
  Future get done => socket?.done ?? Future.value();
  @override
  void shutdown() => socket?.destroy();
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
  Completer<void>? _capacity;
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
    _wakeSender();
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

  void _wakeSender() {
    _capacity?.complete();
    _capacity = null;
  }

  /// Replay a saved snapshot without exceeding the live transport queue.
  /// Closure wakes a waiting sender so cancellation/errors never strand replay.
  Future<bool> sendWhenReady(Object? message) async {
    final snapshot = jsonDecode(jsonEncode(message));
    final length = codec.encode(method.input, snapshot).length;
    if (length > RequestStreamLimits.queuedBytes) {
      throw const GrpcError.resourceExhausted(
        'Message exceeds 32 MiB send queue',
      );
    }
    while (!_inputClosed &&
        !_completed &&
        (_queuedCount >= RequestStreamLimits.queuedMessages ||
            _queuedBytes + length > RequestStreamLimits.queuedBytes)) {
      _capacity ??= Completer<void>();
      await _capacity!.future;
    }
    if (_inputClosed || _completed) return false;
    send(snapshot);
    return true;
  }

  void finishSending() {
    if (_inputClosed) return;
    _inputClosed = true;
    _wakeSender();
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
  ClientTransportConnectorChannel? _channel;
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

  ClientTransportConnectorChannel _create(
    ConnectionConfig config, [
    String? authority,
  ]) {
    return ClientTransportConnectorChannel(
      _Connector(config, authority),
      options: ChannelOptions(
        connectTimeout: const Duration(seconds: 5),
        credentials: config.tls
            ? const ChannelCredentials.secure()
            : const ChannelCredentials.insecure(),
      ),
    );
  }

  Future<DiscoveryResult> connect(ConnectionConfig config) async {
    await disconnect();
    final generation = _generation;
    // The probe and every gRPC channel use the same trust and client identity.
    final socket = await config.openSocket();
    // TLS 1.3 can return the client socket before the peer rejects its client
    // identity. Receiving HTTP/2 SETTINGS proves the peer accepted the session,
    // without invoking a health method, application RPC or keepalive PING.
    final probe = http2.ClientTransportConnection.viaSocket(socket);
    try {
      await probe.onInitialPeerSettingsReceived.timeout(
        const Duration(seconds: 5),
      );
    } finally {
      socket.destroy();
    }
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
          registry = await _reflect(
            channel,
            config.reflectionMetadata ?? config.metadata,
          );
          source = 'reflection';
        } catch (e) {
          warning = 'Reflection unavailable: $e';
        }
      }
      if (source == 'none' && config.schemaProvider != null) {
        try {
          registry = await config.schemaProvider!();
          source = 'proto';
        } catch (e) {
          warning = '$warning\nSchema validation failed: $e'.trim();
        }
      }
      if (source == 'none' && config.localSchema != null) {
        registry = config.localSchema!;
        source = 'proto';
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
    ClientTransportConnectorChannel channel,
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
    void Function(Map<String, String> headers)? onHeaders,
  }) async {
    final clock = Stopwatch()..start();
    if (method.clientStreaming) {
      try {
        final stream = startRequestStream(
          method,
          metadata: metadata,
          timeoutMs: timeoutMs,
          authority: authority,
          onMessage: onMessage,
          onHeaders: onHeaders,
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
      onHeaders: onHeaders,
    );
  }

  RequestStreamCall startRequestStream(
    ProtoMethod method, {
    Map<String, String> metadata = const {},
    int timeoutMs = 5000,
    String authority = '',
    void Function(Object? message)? onMessage,
    void Function(Map<String, String> headers)? onHeaders,
  }) {
    if (!method.clientStreaming) {
      throw const GrpcError.invalidArgument('Method has no streaming request');
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
          onHeaders: onHeaders,
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
    void Function(Map<String, String> headers)? onHeaders,
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
    final headerFuture = call.headers.then((v) {
      headers.addAll(v);
      onHeaders?.call(Map.unmodifiable(headers));
    }, onError: (Object _) {});
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
