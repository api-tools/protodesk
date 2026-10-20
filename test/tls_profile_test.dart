import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:protodesk/main.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/presentation/dialogs.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/transport/engine.dart';

import 'fixtures/server.dart';

void main() {
  test(
    'legacy server migration retains IDs/options and defaults to system trust',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'protodesk-tls-migration-',
      );
      var store = WorkspaceStore.open('${directory.path}/db.sqlite');
      final before = store.save('servers', {
        'name': 'Existing',
        'address': 'localhost:50051',
        'tlsEnabled': true,
        'metadataJson': '{"x-preserved":"yes"}',
      });
      store.db.execute('ALTER TABLE servers DROP COLUMN tls_ca_file');
      store.close();
      store = WorkspaceStore.open('${directory.path}/db.sqlite');
      try {
        expect(store.list('servers').single, before);
        expect(store.list('servers').single['tlsCaFile'], '');
        expect(Directory('${directory.path}/backups').listSync(), hasLength(1));
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('saved TLS trust survives reopen/import and validates a real call; missing trust is rejected', () async {
    final directory = await Directory.systemTemp.createTemp(
      'protodesk-tls-profile-',
    );
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    final server = Server.create(
      services: [FixtureService(schema), ReflectionFixture(schema)],
    );
    await server.serve(
      address: InternetAddress.loopbackIPv4,
      port: 0,
      security: ServerTlsCredentials(
        certificate: await File('test/fixtures/test-only-cert.pem')
            .readAsBytes(),
        privateKey: await File('test/fixtures/test-only-key.pem').readAsBytes(),
      ),
    );
    var store = WorkspaceStore.open('${directory.path}/workspace.sqlite');
    final profile = store.save('servers', {
      'name': 'Test TLS',
      'address': '127.0.0.1:${server.port}',
      'tlsEnabled': true,
      'reflectionEnabled': true,
    });
    var desk = DeskController(store, GrpcEngine(loader));
    try {
      desk.server = profile;
      await desk.connect();
      expect(desk.connected, false);
      expect(desk.status, contains('CERTIFICATE_VERIFY_FAILED'));
      desk.server = store.save('servers', {
        ...profile,
        'tlsCaFile': File('test/fixtures/test-only-ca.pem').absolute.path,
      });
      final exported = store.exportWorkspace();
      desk.dispose();
      store = WorkspaceStore.open('${directory.path}/workspace.sqlite');
      store.importWorkspace(exported);
      desk = DeskController(store, GrpcEngine(loader));
      desk.server = desk.servers.firstWhere((s) => s['id'] != profile['id']);
      expect(
        desk.server!['tlsCaFile'],
        File('test/fixtures/test-only-ca.pem').absolute.path,
      );
      await desk.connect();
      expect(desk.connected, true, reason: desk.status);
      desk.selectMethod(desk.schema.methods['/runtime.fixture.Echo/Unary']!);
      desk.setBody('{"text":"secure"}');
      await desk.invoke();
      expect(desk.result!.code, 'OK');
      expect((desk.messages.single as Map)['text'], 'secure');
      await desk.disconnect();
      final invalid = File('${directory.path}/empty.pem')
        ..writeAsStringSync('');
      desk.server = {...desk.server!, 'tlsCaFile': invalid.path};
      await desk.connect();
      expect(desk.connected, false);
      expect(desk.status, contains('TLS CA file must contain a certificate'));
    } finally {
      await desk.engine.disconnect();
      desk.dispose();
      await server.shutdown();
      await directory.delete(recursive: true);
    }
  });

  testWidgets(
    'server editor exposes profile trust and can return to system roots',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'protodesk-tls-ui-',
      );
      final desk = DeskController(
        WorkspaceStore.open('${directory.path}/db.sqlite'),
        GrpcEngine(ProtoLoader(compiler: 'unused', standardRoot: 'unused')),
      );
      Record? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await editRecord(context, desk, 'servers', {
                    'name': 'TLS',
                    'address': 'localhost:50051',
                    'tlsEnabled': true,
                    'tlsCaFile': '/selected/test-ca.pem',
                    'tlsClientCertificateFile': '/selected/client.pem',
                    'tlsClientKeyFile': '/selected/client-key.pem',
                    'tlsServerName': 'service.example',
                    'reflectionMetadataJson': '{}',
                  });
                },
                child: const Text('Edit profile'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit profile'));
      await tester.pumpAndSettle();
      expect(find.text('Choose CA certificate'), findsOneWidget);
      expect(find.text('/selected/test-ca.pem'), findsOneWidget);
      await tester.ensureVisible(find.text('Use system roots'));
      await tester.tap(find.text('Use system roots'));
      await tester.pumpAndSettle();
      expect(find.text('System trust roots'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result!['tlsCaFile'], '');
      expect(result!['tlsEnabled'], true);
      expect(result!['tlsClientCertificateFile'], '/selected/client.pem');
      expect(result!['tlsClientKeyFile'], '/selected/client-key.pem');
      expect(result!['tlsServerName'], 'service.example');
      expect(result!['reflectionMetadataJson'], '{}');
      await tester.pumpWidget(const SizedBox());
      desk.dispose();
      directory.deleteSync(recursive: true);
    },
  );
}
