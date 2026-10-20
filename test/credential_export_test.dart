import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/security/credentials.dart';
import 'package:protodesk/src/security/redaction.dart';

void main() {
  test('safe workspace export omits literals and bodies, preserves unbound header intent; explicit full export retains data', () {
    final directory = Directory.systemTemp.createTempSync(
      'protodesk-safe-export-',
    );
    final store = WorkspaceStore.open('${directory.path}/workspace.sqlite');
    try {
      final server = store.save('servers', {
        'name': 'Existing',
        'address': 'example.com:443',
        'metadataJson': '{"authorization":"Bearer synthetic-secret"}',
        'reflectionMetadataJson': '{"custom-token":"synthetic-reflection"}',
      });
      final collection = store.save('collections', {'name': 'Existing'});
      store.save('collection_requests', {
        'collectionId': collection['id'],
        'name': 'Example',
        'fullMethod': '/example/Call',
        'requestMetadataJson': '{"x-custom-auth":"synthetic-request-token"}',
        'requestJson': '{"password":"synthetic-body"}',
        'requestStreamJson': '[{"password":"synthetic-sequence"}]',
      });
      final safe = store.exportWorkspace();
      expect(jsonEncode(safe), isNot(contains('synthetic-')));
      final exported = (safe['servers'] as List).single as Map;
      expect(
        MetadataReferences.decode(exported['metadataReferencesJson'] as String)
            .headers,
        {'authorization': null},
      );
      store.importWorkspace(safe);
      final imported = store
          .list('servers')
          .firstWhere((r) => r['id'] != server['id']);
      expect(imported['metadataJson'], '{}');
      expect(
        MetadataReferences.decode(imported['metadataReferencesJson'] as String)
            .headers,
        {'authorization': null},
      );
      // Export did not mutate the source records or wipe working credentials.
      expect(
        store
            .list('servers')
            .firstWhere((r) => r['id'] == server['id'])['metadataJson'],
        contains('synthetic-secret'),
      );
      final full = store.exportWorkspace(
        includeSensitiveLiterals: true,
        includeRequestBodies: true,
      );
      for (final value in [
        'synthetic-secret',
        'synthetic-reflection',
        'synthetic-request-token',
        'synthetic-body',
        'synthetic-sequence',
      ]) {
        expect(jsonEncode(full), contains(value));
      }
    } finally {
      store.close();
      directory.deleteSync(recursive: true);
    }
  });
  test('diagnostic redaction includes custom header names and escaped known values', () {
    expect(redactedMetadata({'custom-auth': 'synthetic-secret'}), {
      'custom-auth': '[redacted]',
    });
    expect(
      redactKnownSecrets('plain abc"def escaped abc\\"def', ['abc"def']),
      'plain [redacted] escaped [redacted]',
    );
  });
}
