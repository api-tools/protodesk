import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../schema/proto_loader.dart';
import '../workflow/storage.dart';
import '../persistence/store.dart';
import 'engine.dart';

/// Explicit release diagnostic; uses temporary data and never opens the user DB.
Future<void> releaseSmoke(
  ProtoLoader loader,
  Directory tools,
  String endpoint, {
  String? nativeDataPath,
}) async {
  if (nativeDataPath != null &&
      nativeDataPath != Platform.environment['PROTODESK_EXPECT_DATA_PATH']) {
    throw StateError('Native application data path is incorrect');
  }
  final databaseRoot = nativeDataPath == null
      ? tools
      : await (Directory(
          p.dirname(nativeDataPath),
        )..createSync(recursive: true)).createTemp('release-check-');
  final source = Platform.environment['PROTODESK_SMOKE_PROTO'];
  final files = <String>[];
  if (source != null) {
    final file = File('${tools.path}/runtime.proto');
    await file.writeAsString(utf8.decode(base64.decode(source)));
    files.add(file.path);
  }
  final engine = GrpcEngine(loader);
  try {
    final discovery = await engine.connect(
      ConnectionConfig(endpoint, reflection: files.isEmpty, files: files),
    );
    if (discovery.schema.methods.isEmpty) throw StateError(discovery.warning);
    final unary = discovery.schema.methods.values.firstWhere(
      (m) => !m.serverStreaming && !m.clientStreaming,
    );
    final result = await engine.invoke(
      unary,
      {'text': 'compiled desktop'},
      metadata: {'x-test': 'release'},
    );
    if (result.code != 'OK' ||
        (result.messages.single as Map)['text'] != 'compiled desktop') {
      throw StateError('Release dynamic invocation failed: ${result.code}');
    }
    final streaming = discovery.schema.methods.values.firstWhere(
      (m) => m.serverStreaming && !m.clientStreaming,
    );
    var received = 0;
    final stream = await engine.invoke(
      streaming,
      {},
      onMessage: (_) => received++,
    );
    if (stream.code != 'OK' || received != 3) {
      throw StateError('Release streaming failed');
    }
    final uploadMethod = discovery.schema.methods.values.firstWhere(
      (m) => m.clientStreaming && !m.serverStreaming,
    );
    final upload = engine.startRequestStream(
      uploadMethod,
      metadata: {'x-test': 'release-upload'},
    );
    upload.send({'text': 'first'});
    upload.send({'text': 'second'});
    upload.finishSending();
    final uploaded = await upload.result;
    if (uploaded.code != 'OK' ||
        (uploaded.messages.single as Map)['text'] != 'first|second' ||
        uploaded.headers['echo-header'] != 'release-upload') {
      throw StateError('Release client streaming failed');
    }
    final chatMethod = discovery.schema.methods.values.firstWhere(
      (m) => m.clientStreaming && m.serverStreaming,
    );
    final firstMessage = Completer<void>();
    final echoed = Completer<void>();
    final chat = engine.startRequestStream(
      chatMethod,
      onMessage: (message) {
        if ((message as Map)['text'] == 'ready') firstMessage.complete();
        if (message['text'] == 'live') echoed.complete();
      },
    );
    await firstMessage.future.timeout(const Duration(seconds: 3));
    if (chat.inputClosed || chat.sentCount != 0) {
      throw StateError('Bidi did not receive before sending');
    }
    chat.send({'text': 'live'});
    await echoed.future.timeout(const Duration(seconds: 3));
    if (chat.inputClosed) {
      throw StateError('Bidi receive was buffered until half-close');
    }
    chat.finishSending();
    final chatted = await chat.result;
    if (chatted.code != 'OK' ||
        chatted.messages.length != 3 ||
        chatted.trailers['echo-trailer'] != 'chat-complete') {
      throw StateError('Release bidirectional streaming failed');
    }
    for (final response in [result, stream, uploaded, chatted]) {
      final trace = response.diagnostics;
      if (trace == null ||
          trace.code != 'OK' ||
          trace.sentMessages < 1 ||
          trace.receivedMessages != response.messages.length ||
          trace.firstResponseUs == null ||
          trace.events.last.kind != 'completed') {
        throw StateError('Compiled diagnostics check failed');
      }
    }
    final database = '${databaseRoot.path}/release-check.sqlite';
    var store = WorkspaceStore.open(database);
    final saved = store.save('servers', {
      'name': 'Release fixture',
      'address': endpoint,
      'metadataJson': '{}',
      'reflectionEnabled': true,
    });
    final collection = store.save('collections', {'name': 'Release examples'});
    store.save('collection_requests', {
      'name': 'Runtime request',
      'collectionId': collection['id'],
      'serverId': saved['id'],
      'fullMethod': uploadMethod.path,
      'requestJson': '{"text":"second"}',
      'requestStreamJson': '[{"text":"first"},{"text":"second"}]',
      'requestMetadataJson': '{}',
    });
    store.save('history_items', {
      'serverAddress': endpoint,
      'fullMethod': unary.path,
      'statusCode': 'OK',
      'requestJson': '{}',
      'responseJson': '{}',
    });
    DraftStore(store).save(
      saved['id'] as String,
      uploadMethod.path,
      RequestDraft(
        body: '{"text":"unsent"}',
        metadata: '{}',
        references: '',
        authority: '',
        timeoutMs: 1250,
        signature: 'compiled-fixture',
        queue: [
          {'text': 'queued'},
        ],
        lastSent: [
          {'text': 'sent'},
        ],
      ),
    );
    final page = queryHistory(
      store,
      filter: const HistoryFilter(status: 'OK'),
      limit: 1,
    );
    if (page.rows.length != 1 || page.hasNext) {
      throw StateError('Compiled history query failed');
    }
    final safe = store.exportWorkspace();
    final safeCollection = (safe['collections'] as List).single as Map;
    final safeRequest = (safeCollection['requests'] as List).single as Map;
    if (safeRequest['requestJson'] != '{}' ||
        safeRequest['requestStreamJson'] != '[]') {
      throw StateError('Compiled safe export retained request payloads');
    }
    store.importWorkspace(
      store.exportWorkspace(
        includeSensitiveLiterals: true,
        includeRequestBodies: true,
      ),
    );
    store.close();
    store = WorkspaceStore.open(database);
    try {
      final draft = DraftStore(store)
          .load(saved['id'] as String, uploadMethod.path);
      if (draft == null ||
          draft.body != '{"text":"unsent"}' ||
          draft.queue.length != 1 ||
          draft.lastSent.length != 1 ||
          draft.timeoutMs != 1250) {
        throw StateError('Compiled draft restart check failed');
      }
      if (store.list('servers').length != 2 ||
          store.list('collection_requests').length != 2 ||
          store.list('history_items').length != 1 ||
          !store.list('servers').any((s) => s['id'] == saved['id']) ||
          store
              .list('collection_requests')
              .any(
                (r) =>
                    (jsonDecode(
                      r['requestStreamJson'] as String,
                    ) as List).length !=
                    2,
              )) {
        throw StateError('Compiled persistence/transfer check failed');
      }
    } finally {
      store.close();
    }
    stdout.writeln(
      jsonEncode({
        'releaseSmoke': 'PASS',
        'discovery': discovery.source,
        'unary': result.code,
        'streamMessages': received,
        'clientStream': uploaded.code,
        'bidirectionalStream': chatted.code,
        'receivedBeforeHalfClose': true,
        'persistence': 'PASS',
        'diagnostics': 'PASS',
        'draftsAndHistoryQuery': 'PASS',
        'nativeDataPath': nativeDataPath == null ? 'not applicable' : 'PASS',
      }),
    );
  } finally {
    await engine.disconnect();
    if (databaseRoot != tools) await databaseRoot.delete(recursive: true);
    await tools.delete(recursive: true);
  }
}
