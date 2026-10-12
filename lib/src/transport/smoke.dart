import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../schema/proto_loader.dart';
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
    final upload = engine.startClientStream(
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
    store.importWorkspace(store.exportWorkspace());
    store.close();
    store = WorkspaceStore.open(database);
    try {
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
        'persistence': 'PASS',
        'nativeDataPath': nativeDataPath == null ? 'not applicable' : 'PASS',
      }),
    );
  } finally {
    await engine.disconnect();
    if (databaseRoot != tools) await databaseRoot.delete(recursive: true);
    await tools.delete(recursive: true);
  }
}
