import '../transport/diagnostics.dart';

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
import '../security/credentials.dart';
import '../security/catalog.dart';
import '../security/native_vault.dart';
import '../security/redaction.dart';
import '../security/metadata.dart';
import '../request_options.dart';

const pretty = JsonEncoder.withIndent('  ');

class DeskController extends ChangeNotifier {
  final WorkspaceStore store;
  final GrpcEngine engine;
  late final CredentialService credentials;
  late final SqliteCredentialCatalog credentialCatalog;
  MetadataReferences requestCredentials = MetadataReferences({});
  int? _resolvingCredentialGeneration;
  CredentialScope? _connectedRecipient;
  String? _importedMethod;
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
  CallDiagnostics? diagnostics;
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
  DeskController(this.store, this.engine, {CredentialVault? credentialVault}) {
    credentialCatalog = SqliteCredentialCatalog(store);
    credentials = CredentialService(
      credentialVault ?? NativeCredentialVault(),
      credentialCatalog,
    );
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
    _importedMethod = null;
    metadata = '{}';
    requestCredentials = MetadataReferences({});
    emit();
  }

  Future<void> loadImportedRequest(
    Record profile,
    Record request,
    RequestOptions options,
  ) async {
    if (invoking || connecting) {
      throw const FormatException(
        'Finish or cancel the active operation before importing.',
      );
    }
    await selectServer(profile);
    if (_disposed) return;
    loadRequest(request);
    _importedMethod = request['fullMethod'] as String;
    timeoutMs = options.timeoutMs;
    authority = options.authority;
    status = 'Imported and saved request. Connect explicitly to resolve its method; no RPC was invoked.';
    emit();
  }

  void _resolveImportedMethod() {
    if (_importedMethod == null) return;
    final found = schema.methods[_importedMethod];
    if (found == null) return;
    method = found;
    _importedMethod = null;
    if (found.clientStreaming) {
      warning = 'The imported method uses request streaming. Command sequences are unsupported; use Queue/Send and Finish sending explicitly.';
    }
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
        credentials: credentials,
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
    final connectionSecrets = <String>[];
    try {
      final s = server!;
      Future<SchemaRegistry> compileLocal() async {
        final config = SourceConfiguration.fromRecord(s);
        if (config.isEmpty) return SchemaRegistry();
        final (validation, manifest) = await SourceManager.forWorkspace(
          engine.loader,
          store.path,
          credentials: credentials,
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
      final reflectionHeaders = s['reflectionEnabled'] == false
          ? <String, String>{}
          : await MetadataPlan.reflection(s)
                .resolve(credentials, credentialScope(s));
      if (generation != _generation || _disposed) return;
      connectionSecrets.addAll(reflectionHeaders.values);
      final discovery = await engine.connect(
        ConnectionConfig(
          s['address'] as String,
          tls: s['tlsEnabled'] == true,
          certificates: certificates,
          identity: identity,
          serverName: (s['tlsServerName'] as String? ?? '').trim(),
          httpAuthority: (s['httpAuthority'] as String? ?? '').trim(),
          reflectionMetadata: reflectionHeaders,
          reflection: s['reflectionEnabled'] != false,
          schemaProvider: compileLocal,
          metadata: const {},
        ),
      );
      if (generation != _generation) return;
      schema = discovery.schema;
      method = method == null ? null : schema.methods[method!.path];
      _connectedRecipient = credentialScope(s);
      connected = true;
      _resolveImportedMethod();
      warning = [
        warning,
        redactKnownSecrets(discovery.warning, connectionSecrets),
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
              credentials: credentials,
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
        _resolveImportedMethod();
        status =
            'Server transport failed: ${redactKnownSecrets(e.toString(), connectionSecrets)}${schema.services.isEmpty ? '' : ' · local schema remains available'}';
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
    _connectedRecipient = null;
    connecting = false;
    status = 'Discovery cancelled';
    emit();
  }

  Future<void> disconnect() async {
    sourceOperation?.cancel();
    ++_generation;
    await engine.disconnect();
    connected = false;
    _connectedRecipient = null;
    connecting = false;
    invoking = false;
    schema = SchemaRegistry();
    method = null;
    requestStream = null;
    replaying = false;
    queuedRequests.clear();
    sentRequests = [];
    result = null;
    diagnostics = null;
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
    if (_importedMethod != selected.path) body = '{}';
    _importedMethod = null;
    result = null;
    diagnostics = null;
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
    if (!connected || connecting || method == null || invoking) return;
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
    final callAuthority = authority;
    final callTimeoutMs = timeoutMs;
    final selectedServer = {...server!};
    Map<String, String> headers;
    Map<String, String> literalHeaders;
    late MetadataReferences usedReferences;
    try {
      if (_connectedRecipient != null &&
          !_connectedRecipient!.matches(credentialScope(selectedServer))) {
        throw const CredentialFailure(
          'Connection settings changed. Reconnect before invoking; no credential was resolved or sent.',
        );
      }
      final plan = MetadataPlan.rpc(
        selectedServer,
        metadata,
        requestCredentials,
      );
      usedReferences = plan.references;
      literalHeaders = plan.literals;
      headers = literalHeaders;
    } catch (e) {
      status = e.toString();
      emit();
      return;
    }
    invoking = true;
    result = null;
    diagnostics = null;
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

    void onDiagnostics(CallDiagnostics value) {
      if (generation == _generation && !_disposed) {
        diagnostics = value;
        emit();
      }
    }

    CallResult response;
    try {
      _resolvingCredentialGeneration = generation;
      try {
        headers = await usedReferences.resolve(
          literalHeaders,
          credentials,
          credentialScope(selectedServer, authority: callAuthority),
        );
      } finally {
        if (_resolvingCredentialGeneration == generation) {
          _resolvingCredentialGeneration = null;
        }
      }
      if (generation != _generation || _disposed) return;
      if (selected.clientStreaming) {
        requestStream = engine.startRequestStream(
          selected,
          metadata: headers,
          timeoutMs: callTimeoutMs,
          authority: callAuthority,
          onMessage: onMessage,
          onHeaders: onHeaders,
          onDiagnostics: onDiagnostics,
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
          timeoutMs: callTimeoutMs,
          authority: callAuthority,
          onMessage: onMessage,
          onHeaders: onHeaders,
          onDiagnostics: onDiagnostics,
        );
      }
    } catch (e) {
      if (generation != _generation || _disposed) return;
      await engine.cancel();
      diagnostics?.complete('FAILED_PRECONDITION');
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
    final safeError = redactKnownSecrets(response.error, headers.values);
    if (safeError != response.error) {
      response = CallResult(
        response.messages,
        response.code,
        safeError,
        response.durationMs,
        response.headers,
        response.trailers,
        diagnostics: response.diagnostics,
      );
    }
    callClock.stop();
    replaying = false;
    result = response;
    diagnostics = response.diagnostics ?? diagnostics;
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
        'requestMetadataJson': jsonEncode(literalHeaders),
        'requestCredentialReferencesJson': usedReferences.encode(),
        'requestOptionsJson': RequestOptions(
          callTimeoutMs,
          callAuthority,
        ).encode(),
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
    if (_resolvingCredentialGeneration == _generation) {
      ++_generation;
      invoking = false;
      callClock.stop();
      status = 'Cancelled before credentials resolved';
      emit();
    }
    await engine.cancel();
  }

  void loadRequest(Record item) {
    late MetadataReferences references;
    RequestOptions? options;
    try {
      options = RequestOptions.decode(item['requestOptionsJson'] as String?);
      references = MetadataReferences.decode(
        item['requestCredentialReferencesJson'] as String?,
      );
    } catch (_) {
      status = 'Request has invalid protected references or call options. Repair the saved request configuration.';
      emit();
      return;
    }
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
    requestCredentials = references;
    if (options != null) {
      timeoutMs = options.timeoutMs;
      authority = options.authority;
    }
    result = null;
    diagnostics = null;
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
    'requestCredentialReferencesJson': requestCredentials.encode(),
    'requestOptionsJson': RequestOptions(timeoutMs, authority).encode(),
  };
  String get responseJson => pretty.convert(
    method?.serverStreaming == true
        ? messages
        : messages.isEmpty
        ? {}
        : messages.first,
  );
  static CredentialScope credentialScope(
    Record server, {
    String authority = '',
  }) => CredentialScope.metadata(
    server['address'] as String,
    tls: server['tlsEnabled'] == true,
    serverName: server['tlsServerName'] as String? ?? '',
    caFileReference: server['tlsCaFile'] as String? ?? '',
    httpAuthority: server['httpAuthority'] as String? ?? '',
    authority: authority,
  );
  static Map<String, String> parseMetadata(String text) =>
      parseLiteralMetadata(text);

  @override
  void dispose() {
    _disposed = true;
    credentials.dispose();
    sourceOperation?.cancel();
    callClock.stop();
    ++_generation;
    engine.disconnect();
    store.close();
    super.dispose();
  }
}
