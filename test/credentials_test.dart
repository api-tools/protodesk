import 'dart:async';

import 'fixtures/credential_vault.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/security/catalog.dart';
import 'package:protodesk/src/security/credentials.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late WorkspaceStore store;
  late SqliteCredentialCatalog catalog;
  late MemoryVault vault;
  late CredentialService service;
  final scope = CredentialScope.metadata('example.com:443', tls: true);
  setUp(() {
    directory = Directory.systemTemp.createTempSync('protodesk-vault-test-');
    store = WorkspaceStore.open('${directory.path}/workspace.sqlite');
    catalog = SqliteCredentialCatalog(store);
    vault = MemoryVault();
    service = CredentialService(vault, catalog);
  });
  tearDown(() {
    service.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'startup is lazy; SQLite and workspace contain only opaque references',
    () async {
      expect(vault.reads + vault.writes, 0);
      final id = await service.create(
        'API key',
        CredentialValue(scope, 'synthetic-secret'),
      );
      expect(catalog.entry(id)['state'], 'ready');
      expect(await service.resolve(id, scope), 'synthetic-secret');
      final server = store.save('servers', {
        'name': 'Production',
        'address': 'example.com:443',
        'metadataReferencesJson': MetadataReferences({'authorization': id})
            .encode(),
      });
      expect(
        jsonEncode(store.exportWorkspace()),
        isNot(contains('synthetic-secret')),
      );
      for (final table in WorkspaceStore.columns.keys) {
        expect(
          jsonEncode(store.list(table)),
          isNot(contains('synthetic-secret')),
        );
      }
      expect(server['metadataReferencesJson'], contains(id));
      expect(jsonEncode(catalog.entries), isNot(contains('"value"')));
      expect(
        () => jsonEncode(CredentialValue(scope, 'synthetic-secret')),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(
        CredentialValue(scope, 'synthetic-secret').toString(),
        isNot(contains('synthetic-secret')),
      );
    },
  );

  test('recipient binding includes endpoint, TLS, SNI and authority', () async {
    final id = await service.create(
      'Bound',
      CredentialValue(scope, 'synthetic-secret'),
    );
    for (final other in [
      CredentialScope.metadata('elsewhere.com:443', tls: true),
      CredentialScope.metadata('example.com:443', tls: false),
      CredentialScope.metadata(
        'example.com:443',
        tls: true,
        serverName: 'alternate',
      ),
      CredentialScope.metadata(
        'example.com:443',
        tls: true,
        authority: 'alternate',
      ),
      CredentialScope.metadata(
        'example.com:443',
        tls: true,
        caFileReference: '/different/trust.pem',
      ),
      CredentialScope.github('example', 'repository'),
    ]) {
      await expectLater(
        service.resolve(id, other),
        throwsA(same(CredentialFailure.wrongScope)),
      );
    }
    expect(
      scope.matches(CredentialScope.metadata('EXAMPLE.COM:443', tls: true)),
      true,
    );
  });

  test(
    'backend errors never leak; failed deletion preserves catalog for retry',
    () async {
      final id = await service.create(
        'Bound',
        CredentialValue(scope, 'synthetic-secret'),
      );
      vault.locked = true;
      await expectLater(
        service.resolve(id, scope),
        throwsA(same(CredentialFailure.unavailable)),
      );
      await expectLater(
        service.delete(id),
        throwsA(same(CredentialFailure.unavailable)),
      );
      expect(catalog.contains(id), true);
      vault.locked = false;
      await service.delete(id);
      expect(catalog.contains(id), false);
      expect(vault.values, isEmpty);
      await expectLater(
        service.resolve(id, scope),
        throwsA(same(CredentialFailure.missing)),
      );
    },
  );

  test('failed writes are journaled, never selectable as ready', () async {
    vault.discardWrites = true;
    await expectLater(
      service.create('Lost write', CredentialValue(scope, 'synthetic-secret')),
      throwsA(isA<CredentialFailure>()),
    );
    expect(catalog.entries.single['state'], 'unavailable');
    expect(catalog.matching(scope), isEmpty);
  });

  test(
    'late OS completion after disposal leaves a recoverable pending entry',
    () async {
      vault.pending = Completer<void>();
      final creation = service.create(
        'Pending',
        CredentialValue(scope, 'synthetic-secret'),
      );
      final expectation = expectLater(
        creation,
        throwsA(same(CredentialFailure.unavailable)),
      );
      service.dispose();
      vault.pending!.complete();
      await expectation;
      expect(catalog.entries.single['state'], 'pending');
    },
  );

  test('invalid IDs never access the OS; malformed protected payloads are redacted', () async {
    await expectLater(
      service.resolve('../different-app', scope),
      throwsA(same(CredentialFailure.invalid)),
    );
    expect(vault.reads, 0);
    final id = catalog.create('Broken', scope);
    vault.values[id] = '{synthetic-secret';
    await expectLater(
      service.resolve(id, scope),
      throwsA(same(CredentialFailure.invalid)),
    );
    expect(
      () => parseLiteralMetadata('{"authorization":"synthetic-secret'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.toString(),
          'redacted',
          isNot(contains('synthetic-secret')),
        ),
      ),
    );
  });

  test(
    'references resolve without mutating literals; null refs cannot be sent',
    () async {
      final id = await service.create(
        'Header',
        CredentialValue(scope, 'synthetic-secret'),
      );
      final literals = {'Authorization': 'legacy', 'x-test': 'preserved'};
      final refs = MetadataReferences.decode(
        MetadataReferences({'authorization': id}).encode(),
      );
      expect(await refs.resolve(literals, service, scope), {
        'authorization': 'synthetic-secret',
        'x-test': 'preserved',
      });
      expect(literals['Authorization'], 'legacy');
      await expectLater(
        MetadataReferences({'authorization': null}).resolve({}, service, scope),
        throwsA(same(CredentialFailure.missing)),
      );
      for (final bad in [
        '{}',
        '{"version":2,"headers":{}}',
        '{"version":1,"headers":{"Authorization":null}}',
      ]) {
        expect(
          () => MetadataReferences.decode(bad),
          throwsA(same(CredentialFailure.invalid)),
        );
      }
    },
  );

  test('additive reference migration backs up and preserves old records', () {
    final server = store.save('servers', {
      'name': 'Existing',
      'address': 'localhost:1234',
      'metadataJson': '{"x-legacy":"kept"}',
    });
    final collection = store.save('collections', {'name': 'Existing'});
    final request = store.save('collection_requests', {
      'collectionId': collection['id'],
      'name': 'Existing',
      'fullMethod': '/test/Call',
    });
    final history = store.save('history_items', {
      'serverAddress': 'localhost:1234',
      'fullMethod': '/test/Call',
      'statusCode': 'OK',
    });
    for (final table in ['servers', 'collection_requests', 'history_items']) {
      for (final name
          in table == 'servers'
              ? [
                  'metadata_references_json',
                  'reflection_metadata_references_json',
                ]
              : ['request_credential_references_json']) {
        store.db.execute('ALTER TABLE $table DROP COLUMN $name');
      }
    }
    store.close();
    store = WorkspaceStore.open('${directory.path}/workspace.sqlite');
    expect(store.list('servers').single, server);
    expect(store.list('collections').single, {
      ...collection,
      'requests': [request],
    });
    expect(store.list('collection_requests').single, request);
    expect(store.list('history_items').single, history);
    final snapshot = sqlite3.open(
      Directory('${directory.path}/backups').listSync().single.path,
    );
    try {
      expect(
        snapshot
            .select('PRAGMA table_info(servers)')
            .any((r) => r['name'] == 'metadata_references_json'),
        false,
      );
    } finally {
      snapshot.close();
    }
  });
}
