import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:path/path.dart' as p;
import 'package:protodesk/src/interchange/export.dart';
import 'package:protodesk/src/interchange/grpcurl.dart';
import 'package:protodesk/src/interchange/shell.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/request_options.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/sources/configuration.dart';
import 'package:protodesk/src/transport/engine.dart';

import 'fixtures/credential_vault.dart';
import 'mtls_test.dart'
    show RequiredClientCredentials, MetadataReflection, CapturedFixture;

void main() {
  test('imported mTLS command retains separate metadata, shared reflection/RPC authority and persisted call options without auto invocation', () async {
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    final reflection = MetadataReflection(schema),
        fixture = CapturedFixture(schema);
    final service = Server.create(services: [reflection, fixture]);
    await service.serve(
      address: InternetAddress.loopbackIPv4,
      port: 0,
      security: RequiredClientCredentials(),
      requireClientCertificate: true,
    );
    final directory = Directory.systemTemp.createTempSync(
      'protodesk-command-mtls-',
    );
    final store = WorkspaceStore.open('${directory.path}/data.sqlite');
    final desk = DeskController(
      store,
      GrpcEngine(loader),
      credentialVault: MemoryVault(),
    );
    try {
      String q(String path) => quoteArgument(
        p.absolute('test/fixtures/mtls/$path'),
        CommandShell.posix,
      );
      const body = '{"text":"imported","nested":{}}';
      final parsed = GrpcurlCommand.parse(
        "grpcurl -cacert ${q('ca.pem')} -cert ${q('client-chain.pem')} -key ${q('client-key.pem')} -authority localhost -rpc-header 'x-test: rpc-value' -reflect-header 'x-reflect: discovery-value' -max-time 1.234 -d ${quoteArgument(body, CommandShell.posix)} 127.0.0.1:${service.port} runtime.fixture.Echo/Unary",
        CommandShell.posix,
      );
      final profile = store.save(
        'servers',
        await commandServerRecord(parsed, 'Imported mTLS', SourceOperation()),
      );
      final collection = store.save('collections', {'name': 'Imported'});
      final options = RequestOptions(parsed.timeoutMs!, parsed.authority);
      final request = store.save('collection_requests', {
        'name': 'Imported',
        'collectionId': collection['id'],
        'serverId': profile['id'],
        'fullMethod': parsed.fullMethod,
        'requestJson': parsed.body,
        'requestOptionsJson': options.encode(),
      });
      await desk.loadImportedRequest(profile, request, options);
      expect(fixture.calls, 0);
      expect(reflection.seen, isEmpty);
      expect(desk.connected, false);
      await desk.connect();
      expect(desk.connected, true, reason: desk.status);
      expect(desk.method!.path, parsed.fullMethod);
      expect(desk.body, body);
      expect(reflection.seen, isNotEmpty);
      for (final metadata in reflection.seen) {
        expect(metadata[':authority'], 'localhost');
        expect(metadata['x-reflect'], 'discovery-value');
        expect(metadata.containsKey('x-test'), false);
      }
      await desk.invoke();
      expect(desk.result!.code, 'OK');
      expect(fixture.metadata[':authority'], 'localhost');
      expect(fixture.metadata['x-test'], 'rpc-value');
      expect(fixture.metadata.containsKey('x-reflect'), false);
      expect((desk.result!.messages.single as Map)['text'], 'imported');
      expect(
        RequestOptions.decode(
          desk.history.single['requestOptionsJson'] as String,
        )!.timeoutMs,
        1234,
      );
      desk.timeoutMs = 9;
      desk.authority = 'other';
      desk.loadRequest(request);
      expect(desk.timeoutMs, 1234);
      expect(desk.authority, 'localhost');
      final exported = store.exportWorkspace(
        includeRequestBodies: true,
        includeSensitiveLiterals: true,
      );
      store.importWorkspace(exported);
      expect(
        store.list('servers').every((r) => r['httpAuthority'] == 'localhost'),
        true,
      );
      expect(
        store
            .list('collection_requests')
            .every(
              (r) =>
                  jsonDecode(r['requestOptionsJson'] as String)['authority'] ==
                  'localhost',
            ),
        true,
      );
    } finally {
      desk.dispose();
      await service.shutdown();
      directory.deleteSync(recursive: true);
    }
  });
  test('options/authority additive migration retains legacy rows and backs up before changes', () {
    final directory = Directory.systemTemp.createTempSync(
      'protodesk-command-migration-',
    );
    var store = WorkspaceStore.open('${directory.path}/data.sqlite');
    try {
      final server = store.save('servers', {
        'name': 'Legacy',
        'address': 'localhost:80',
      });
      final collection = store.save('collections', {'name': 'Legacy'});
      final request = store.save('collection_requests', {
        'name': 'Legacy',
        'collectionId': collection['id'],
        'fullMethod': '/example.Service/Call',
      });
      final history = store.save('history_items', {
        'serverAddress': 'localhost:80',
        'fullMethod': '/example.Service/Call',
        'statusCode': 'OK',
      });
      store.db.execute('ALTER TABLE servers DROP COLUMN http_authority');
      for (final table in ['collection_requests', 'history_items']) {
        store.db.execute('ALTER TABLE $table DROP COLUMN request_options_json');
      }
      store.close();
      store = WorkspaceStore.open('${directory.path}/data.sqlite');
      expect(store.list('servers').single, server);
      expect(store.list('collection_requests').single, request);
      expect(store.list('history_items').single, history);
      expect(Directory('${directory.path}/backups').listSync().length, 1);
    } finally {
      store.close();
      directory.deleteSync(recursive: true);
    }
  });
}
