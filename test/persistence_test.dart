import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:protodesk/src/persistence/store.dart';

void main() {
  late Directory directory;
  late WorkspaceStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('protodesk-storage-test-');
    store = WorkspaceStore.open('${directory.path}/protodesk.sqlite');
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });
  test('stream column migration preserves legacy records and snapshots before altering schema', () {
    final collection = store.save('collections', {'name': 'Legacy'});
    final request = store.save('collection_requests', {
      'name': 'Legacy request',
      'collectionId': collection['id'],
      'fullMethod': '/legacy/Upload',
      'requestJson': '{"text":"preserved"}',
    });
    final history = store.save('history_items', {
      'serverAddress': 'localhost:50051',
      'fullMethod': '/legacy/Upload',
      'statusCode': 'OK',
      'requestJson': '{"text":"preserved"}',
    });
    for (final table in ['collection_requests', 'history_items']) {
      store.db.execute('ALTER TABLE $table DROP COLUMN request_stream_json');
    }
    store.close();
    store = WorkspaceStore.open('${directory.path}/protodesk.sqlite');
    expect(store.list('collection_requests').single, request);
    expect(store.list('history_items').single, history);
    final backup = Directory('${directory.path}/backups').listSync().single;
    final snapshot = sqlite3.open(backup.path);
    try {
      expect(
        snapshot
            .select('PRAGMA table_info(collection_requests)')
            .any((r) => r['name'] == 'request_stream_json'),
        false,
      );
      expect(
        snapshot.select('SELECT id FROM collection_requests').single['id'],
        request['id'],
      );
    } finally {
      snapshot.close();
    }
  });
  test('CRUD, restart, timestamps, history and collection relationships', () {
    final server = store.save('servers', {
      'name': 'Local',
      'address': 'localhost:50051',
      'tlsEnabled': true,
      'reflectionEnabled': false,
      'metadataJson': '{"x-test":"fixture"}',
      'protoFiles': ['sample.proto'],
      'protoFolders': ['protos'],
    });
    final collection = store.save('collections', {
      'name': 'Examples',
      'description': 'Fixtures',
    });
    final request = store.save('collection_requests', {
      'name': 'Echo',
      'fullMethod': '/example.Echo/Call',
      'collectionId': collection['id'],
      'serverId': server['id'],
      'requestJson': '{"value":1}',
      'requestMetadataJson': '{}',
    });
    store.save('history_items', {
      'fullMethod': '/example.Echo/Call',
      'requestJson': '{}',
      'responseJson': '{}',
      'durationMs': 14,
      'statusCode': 'OK',
      'serverAddress': 'localhost:50051',
    });
    store.close();
    store = WorkspaceStore.open('${directory.path}/protodesk.sqlite');
    expect(store.list('servers').single, server);
    expect(store.list('history_items').single['durationMs'], 14);
    expect(
      (store.list('collections').single['requests'] as List).single,
      request,
    );
    expect(Directory('${directory.path}/backups').listSync().length, 1);
    final edited = store.save('servers', {...server, 'name': 'Changed'});
    expect(edited['createdAt'], server['createdAt']);
    store.delete('collections', collection['id'] as String);
    expect(store.list('collection_requests'), isEmpty);
    store.clearHistory();
    expect(store.list('history_items'), isEmpty);
    store.delete('servers', server['id'] as String);
    expect(store.list('servers'), isEmpty);
  });
  test(
    'version 1 workspace import duplicates and remaps, export excludes history',
    () {
      final server = store.save('servers', {
        'name': 'Local',
        'address': 'localhost:50051',
        'metadataJson': '{}',
      });
      final collection = store.save('collections', {'name': 'Examples'});
      store.save('collection_requests', {
        'name': 'Request',
        'serverId': server['id'],
        'collectionId': collection['id'],
        'fullMethod': '/example.Echo/Call',
        'requestJson': '{}',
        'requestMetadataJson': '{}',
      });
      store.save('history_items', {
        'statusCode': 'OK',
        'serverAddress': 'localhost:50051',
        'fullMethod': '/example.Echo/Call',
      });
      final exported = store.exportWorkspace();
      expect(exported.containsKey('history'), false);
      final counts = store.importWorkspace(exported);
      expect(counts, {
        'serverCount': 1,
        'collectionCount': 1,
        'savedRequestCount': 1,
      });
      expect(store.list('servers').length, 2);
      final imported = store
          .list('servers')
          .firstWhere((s) => s['id'] != server['id']);
      final requests = store.list('collection_requests');
      expect(
        requests.firstWhere(
          (r) => r['collectionId'] != collection['id'],
        )['serverId'],
        imported['id'],
      );
      expect(store.list('history_items').length, 1);
      expect(
        () => store.importWorkspace({...exported, 'version': 2}),
        throwsFormatException,
      );
    },
  );
  test('failed workspace import rolls back all writes', () {
    expect(
      () => store.importWorkspace({
        'kind': 'protodesk.workspace',
        'version': 1,
        'servers': [
          {'name': 'Valid', 'address': 'localhost:50051', 'metadataJson': '{}'},
        ],
        'collections': [
          {
            'name': 'Collection',
            'requests': [
              {'name': ''},
            ],
          },
        ],
      }),
      throwsFormatException,
    );
    expect(store.list('servers'), isEmpty);
  });
  test('existing compatible database fixture keeps all IDs and records', () {
    store.close();
    File('${directory.path}/protodesk.sqlite').deleteSync();
    File('test/fixtures/workspace.sqlite')
        .copySync('${directory.path}/protodesk.sqlite');
    store = WorkspaceStore.open('${directory.path}/protodesk.sqlite');
    expect(store.list('servers').single['id'], 'fixture-server');
    expect(store.list('servers').single['protoFiles'], ['api.proto']);
    expect(store.list('history_items').single['id'], 'fixture-history');
    expect(
      (store.list('collections').single['requests'] as List).single['id'],
      'fixture-request',
    );
  });
}
