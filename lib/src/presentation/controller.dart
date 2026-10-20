import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../transport/engine.dart';
import '../transport/tls_identity.dart';
import '../schema/schema.dart';
import '../schema/codec.dart';
import '../sources/manager.dart';
import '../sources/configuration.dart';
import '../persistence/store.dart';

const pretty = JsonEncoder.withIndent('  ');

class DeskController extends ChangeNotifier {
  final WorkspaceStore store;
  final GrpcEngine engine;
  List<Record> servers = [], collections = [], history = [];
  Record? server;
  SchemaRegistry schema = SchemaRegistry();
  ProtoMethod? method;
  String body = '{}',
      metadata = '{}',
      authority = '',
      status = 'Disconnected',
      warning = '',
      responseFilter = '';
  int timeoutMs = 5000, responseRevision = 0;
  final callClock = Stopwatch();
  bool connected = false, connecting = false, invoking = false;
  CallResult? result;
  final messages = <Object?>[];
  final queuedRequests = <Object?>[];
  List<Object?> sentRequests = [];
  RequestStreamCall? requestStream;
  bool replaying = false;
  bool get sendingFinished => requestStream?.inputClosed ?? true;
  bool get canSend =>
      invoking && !replaying && requestStream != null && !sendingFinished;

  int _generation = 0;
  bool _disposed = false;
  SourceOperation? sourceOperation;
  DeskController(this.store, this.engine) {
    refresh();
  }
  void emit() {
    if (!_disposed) notifyListeners();
  }

  void refresh() {
    servers = store.list('servers');
    collections = store.list('collections');
    history = store.list('history_items').take(100).toList();
    server ??= servers.firstOrNull;
    emit();
  }

  Future<void> selectServer(Record selected) async {
    await disconnect();
    server = selected;
    metadata = '{}';
    emit();
  }

  Future<void> browseSources() async {
    if (server == null || connecting) return;
    if (connected) await disconnect();
    final generation = ++_generation;
    connecting = true;
    final operation = sourceOperation = SourceOperation(
      onProgress: (text) {
        if (generation == _generation) {
          status = text;
          emit();
        }
      },
    );
    status = 'Validating proto sources…';
    emit();
    try {
      final (validation, manifest) = await SourceManager.forWorkspace(
        engine.loader,
        store.path,
      ).validate(SourceConfiguration.fromRecord(server!), operation);
      if (_disposed || generation != _generation) return;
      schema = validation.schema;
      method = method == null ? null : schema.methods[method!.path];
      server = store.save('servers', {
        ...server!,
        'protoSources': manifest.configuration.data,
      });
      refresh();
      status =
          'Schema ready · ${schema.services.length} services · ${connected ? 'connected' : 'offline; connect to execute RPCs'}';
    } catch (e) {
      if (!_disposed && generation == _generation) {
        status = 'Schema validation failed: $e';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        connecting = false;
        emit();
      }
    }
  }

  Future<void> connect() async {
    if (server == null) {
      status = 'Create a server profile first';
      emit();
      return;
    }
    final generation = ++_generation;
    connecting = true;
    warning = '';
    sourceOperation?.cancel();
    final operation = sourceOperation = SourceOperation();
    status = 'Connecting…';
    emit();
    try {
      final s = server!;
      Future<SchemaRegistry> compileLocal() async {
        final config = SourceConfiguration.fromRecord(s);
        if (config.isEmpty) return SchemaRegistry();
        final (validation, manifest) = await SourceManager.forWorkspace(
          engine.loader,
          store.path,
        ).validate(config, operation);
        if (generation != _generation || _disposed) {
          throw const FormatException('Source discovery cancelled');
        }
        schema = validation.schema;
        server = store.save('servers', {
          ...s,
          'protoSources': manifest.configuration.data,
        });
        return schema;
      }

      final identity = await TlsIdentity.load(
        s['tlsClientCertificateFile'] as String? ?? '',
        s['tlsClientKeyFile'] as String? ?? '',
      );
      final reflectionJson = (s['reflectionMetadataJson'] as String? ?? '')
          .trim();
      List<int>? certificates;
      final caFile = s['tlsCaFile'] as String? ?? '';
      if (s['tlsEnabled'] == true && caFile.isNotEmpty) {
        final file = File(caFile);
        if (await file.length() > 1024 * 1024) {
          throw const FormatException('TLS CA file exceeds 1 MiB');
        }
        certificates = await file.readAsBytes();
        if (certificates.isEmpty || certificates.length > 1024 * 1024) {
          throw const FormatException(
            'TLS CA file must contain a certificate (at most 1 MiB)',
          );
        }
      }
      if (generation != _generation) return;
      final discovery = await engine.connect(
        ConnectionConfig(
          s['address'] as String,
          tls: s['tlsEnabled'] == true,
          certificates: certificates,
          identity: identity,
          serverName: (s['tlsServerName'] as String? ?? '').trim(),
          reflectionMetadata: reflectionJson.isEmpty
              ? null
              : parseMetadata(reflectionJson),
          reflection: s['reflectionEnabled'] != false,
          schemaProvider: compileLocal,
          metadata: parseMetadata(s['metadataJson'] as String? ?? '{}'),
        ),
      );
      if (generation != _generation) return;
      schema = discovery.schema;
      method = method == null ? null : schema.methods[method!.path];
      connected = true;
      warning = [
        warning,
        discovery.warning,
      ].where((s) => s.isNotEmpty).join('\n');
      status =
          'Connected · ${discovery.source} · ${schema.services.length} services';
    } catch (e) {
      if (generation == _generation) {
        connected = false;
        try {
          final config = SourceConfiguration.fromRecord(server!);
          if (!config.isEmpty) {
            final (validation, manifest) = await SourceManager.forWorkspace(
              engine.loader,
              store.path,
            ).validate(config, operation);
            if (generation != _generation || _disposed) return;
            schema = validation.schema;
            server = store.save('servers', {
              ...server!,
              'protoSources': manifest.configuration.data,
            });
          }
        } catch (sourceError) {
          if (generation == _generation) {
            warning = 'Schema validation failed: $sourceError';
          }
        }
        if (generation != _generation || _disposed) return;
        status =
            'Server transport failed: $e${schema.services.isEmpty ? '' : ' · local schema remains available'}';
      }
    } finally {
      if (generation == _generation) {
        connecting = false;
        emit();
      }
    }
  }

  Future<void> cancelDiscovery() async {
    ++_generation;
    sourceOperation?.cancel();
    await engine.disconnect();
    connected = false;
    connecting = false;
    status = 'Discovery cancelled';
    emit();
  }

  Future<void> disconnect() async {
    sourceOperation?.cancel();
    ++_generation;
    await engine.disconnect();
    connected = false;
    connecting = false;
    invoking = false;
    schema = SchemaRegistry();
    method = null;
    requestStream = null;
    replaying = false;
    queuedRequests.clear();
    sentRequests = [];
    result = null;
    messages.clear();
    responseRevision++;
    callClock.stop();
    warning = '';
    status = 'Disconnected';
    emit();
  }

  void selectMethod(ProtoMethod selected) {
    // Offline methods remain selectable while discovery is in progress.
    if (!connecting) ++_generation;
    engine.cancel();
    invoking = false;
    method = selected;
    requestStream = null;
    replaying = false;
    queuedRequests.clear();
    sentRequests = [];
    body = '{}';
    result = null;
    messages.clear();
    responseRevision++;
    callClock.stop();
    status = selected.path;
    emit();
  }

  String? validateBody(String value) {
    try {
      final parsed = jsonDecode(value);
      if (method != null) ProtoCodec(schema).encode(method!.input, parsed);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  void setBody(String value) {
    body = value;
    emit();
  }

  String? validateQueue(List<Object?> values, {bool replay = false}) {
    try {
      if (values.length >
          (replay
              ? RequestStreamLimits.messages
              : RequestStreamLimits.queuedMessages)) {
        throw FormatException(
          'Queue is limited to ${replay ? 1000 : 64} messages',
        );
      }
      var wire = 0, json = 0;
      for (final value in values) {
        wire += ProtoCodec(schema).encode(method!.input, value).length;
        json += utf8.encode(jsonEncode(value)).length;
      }
      if (wire >
              (replay
                  ? RequestStreamLimits.wireBytes
                  : RequestStreamLimits.queuedBytes) ||
          json > RequestStreamLimits.jsonBytes) {
        throw FormatException(
          'Queue exceeds ${replay ? 64 : 32} MiB wire or 64 MiB JSON',
        );
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  void queueDraft() {
    if (method?.clientStreaming != true || invoking) return;
    final error = validateBody(body);
    if (error != null) {
      status = error;
      emit();
      return;
    }
    final value = jsonDecode(body);
    final invalid = validateQueue([...queuedRequests, value]);
    if (invalid != null) {
      status = invalid;
      emit();
      return;
    }
    queuedRequests.add(value);
    status = '${queuedRequests.length} messages queued';
    emit();
  }

  void removeQueuedRequest(int index) {
    if (invoking) return;
    queuedRequests.removeAt(index);
    emit();
  }

  void sendDraft() {
    if (!canSend) return;
    final error = validateBody(body);
    if (error != null) {
      status = error;
      emit();
      return;
    }
    try {
      final value = jsonDecode(body);
      requestStream!.send(value);
      sentRequests.add(value);
      status = '${sentRequests.length} messages sent';
    } catch (e) {
      status = e.toString();
    }
    emit();
  }

  void finishSending() {
    if (!canSend) return;
    requestStream!.finishSending();
    status = 'Send side finished; waiting for response';
    emit();
  }

  Future<void> invoke() async {
    if (!connected || method == null || invoking) return;
    final error = validateBody(body);
    if (error != null) {
      status = error;
      emit();
      return;
    }
    if (method!.clientStreaming) {
      final invalid = validateQueue(queuedRequests, replay: true);
      if (invalid != null) {
        status = invalid;
        emit();
        return;
      }
    }
    final generation = ++_generation;
    final selected = method!;
    final request = body;
    final selectedServer = {...server!};
    Map<String, String> headers;
    try {
      headers = parseMetadata(metadata);
    } catch (e) {
      status = e.toString();
      emit();
      return;
    }
    invoking = true;
    result = null;
    messages.clear();
    responseRevision++;
    callClock.stop();
    callClock
      ..reset()
      ..start();
    status = 'Invoking ${selected.name}…';
    emit();
    final outgoing = <Object?>[];
    if (selected.clientStreaming) sentRequests = outgoing;
    void onMessage(Object? message) {
      if (generation == _generation) {
        messages.add(message);
        emit();
      }
    }

    void onHeaders(Map<String, String> received) {
      if (generation == _generation) {
        result = CallResult(
          List.of(messages),
          'IN_PROGRESS',
          '',
          callClock.elapsedMilliseconds,
          received,
          const {},
        );
        emit();
      }
    }

    CallResult response;
    try {
      if (selected.clientStreaming) {
        requestStream = engine.startRequestStream(
          selected,
          metadata: headers,
          timeoutMs: timeoutMs,
          authority: authority,
          onMessage: onMessage,
          onHeaders: onHeaders,
        );
        final call = requestStream!;
        final sequence = List<Object?>.of(queuedRequests);
        queuedRequests.clear();
        replaying = sequence.isNotEmpty;
        emit();
        for (final value in sequence) {
          if (!await call.sendWhenReady(value)) break;
          outgoing.add(value);
        }
        if (generation != _generation) return;
        replaying = false;
        status =
            '${selected.serverStreaming ? 'Bidirectional' : 'Client'} stream open; ${outgoing.length} messages sent';
        emit();
        response = await requestStream!.result;
      } else {
        response = await engine.invoke(
          selected,
          jsonDecode(request),
          metadata: headers,
          timeoutMs: timeoutMs,
          authority: authority,
          onMessage: onMessage,
          onHeaders: onHeaders,
        );
      }
    } catch (e) {
      await engine.cancel();
      response = CallResult(
        List.of(messages),
        'FAILED_PRECONDITION',
        e.toString(),
        callClock.elapsedMilliseconds,
        {},
        {},
      );
    }
    if (generation != _generation) return;
    callClock.stop();
    replaying = false;
    result = response;
    invoking = false;
    status =
        '${response.code} · ${response.durationMs} ms${response.error.isEmpty ? '' : ' · ${response.error}'}';
    try {
      store.save('history_items', {
        'serverId': selectedServer['id'],
        'serverName': selectedServer['name'],
        'serverAddress': selectedServer['address'],
        'serviceName': selected.service,
        'methodName': selected.name,
        'fullMethod': selected.path,
        'requestJson': request,
        'requestStreamJson': jsonEncode(outgoing),
        'requestMetadataJson': jsonEncode({
          ...parseMetadata(selectedServer['metadataJson'] as String? ?? '{}'),
          ...headers,
        }),
        'responseJson': pretty.convert(
          selected.serverStreaming
              ? response.messages
              : response.messages.firstOrNull ?? {},
        ),
        'statusCode': response.code,
        'statusMessage': response.error,
        'durationMs': response.durationMs,
        'error': response.error,
      });
      refresh();
    } catch (e) {
      status += ' · History could not be saved: $e';
    }
    emit();
  }

  Future<void> cancel() async {
    await engine.cancel();
  }

  void loadRequest(Record item) {
    ++_generation;
    engine.cancel();
    invoking = false;
    method = schema.methods[item['fullMethod']];
    requestStream = null;
    replaying = false;
    sentRequests = [];
    queuedRequests.clear();
    final queue = jsonDecode(item['requestStreamJson'] as String? ?? '[]');
    if (queue is List) queuedRequests.addAll(queue);
    body = item['requestJson'] as String? ?? '{}';
    metadata = item['requestMetadataJson'] as String? ?? '{}';
    result = null;
    messages.clear();
    responseRevision++;
    callClock.stop();
    status = method == null
        ? 'Request loaded; connect to its server and select the matching method'
        : 'Loaded ${method!.path}';
    emit();
  }

  Record requestSnapshot() => {
    'serverId': server?['id'] ?? '',
    'serverName': server?['name'] ?? '',
    'serverAddress': server?['address'] ?? '',
    'serviceName': method?.service ?? '',
    'methodName': method?.name ?? '',
    'fullMethod': method?.path ?? '',
    'requestJson': body,
    'requestStreamJson': jsonEncode(
      queuedRequests.isNotEmpty ? queuedRequests : sentRequests,
    ),
    'requestMetadataJson': metadata,
  };
  String get responseJson => pretty.convert(
    method?.serverStreaming == true
        ? messages
        : messages.isEmpty
        ? {}
        : messages.first,
  );
  static Map<String, String> parseMetadata(String text) {
    final value = jsonDecode(text);
    if (value is! Map || value.values.any((v) => v is! String)) {
      throw const FormatException('Metadata must be a JSON object of strings');
    }
    return value.cast<String, String>();
  }

  @override
  void dispose() {
    _disposed = true;
    sourceOperation?.cancel();
    callClock.stop();
    ++_generation;
    engine.disconnect();
    store.close();
    super.dispose();
  }
}
