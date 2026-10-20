import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:protodesk/src/transport/engine.dart';
import 'package:protodesk/src/transport/tls_identity.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/persistence/store.dart';

import 'fixtures/server.dart';

const root = 'test/fixtures/mtls/';

class RequiredClientCredentials extends ServerTlsCredentials {
  RequiredClientCredentials()
    : super(
        certificate: File('${root}server.pem').readAsBytesSync(),
        privateKey: File('${root}server-key.pem').readAsBytesSync(),
      );
  @override
  SecurityContext get securityContext =>
      super.securityContext..setTrustedCertificates('${root}ca.pem');
}

class MetadataReflection extends ReflectionFixture {
  final seen = <Map<String, String>>[];
  MetadataReflection(super.schema);
  @override
  Stream<List<int>> reflect(
    ServiceCall call,
    Stream<List<int>> requests,
  ) async* {
    seen.add(Map.from(call.clientMetadata ?? {}));
    yield* super.reflect(call, requests);
  }
}

class CapturedFixture extends FixtureService {
  int calls = 0;
  Map<String, String> metadata = {};
  CapturedFixture(super.schema);
  @override
  Future<List<int>> unary(ServiceCall call, Future<List<int>> request) {
    calls++;
    metadata = Map.from(call.clientMetadata ?? {});
    return super.unary(call, request);
  }
}

void main() {
  test(
    'default authority retains standard port normalization and IPv6 brackets',
    () {
      expect(
        const ConnectionConfig('example.com:443').defaultAuthority,
        'example.com',
      );
      expect(
        const ConnectionConfig('example.com:8443').defaultAuthority,
        'example.com:8443',
      );
      expect(const ConnectionConfig('[::1]:443').defaultAuthority, '[::1]');
      expect(
        const ConnectionConfig('[::1]:8443').defaultAuthority,
        '[::1]:8443',
      );
    },
  );
  final loader = ProtoLoader(
    compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
    standardRoot: 'assets/protoc/include',
  );
  test('client PEM validation redacts malformed, encrypted, missing and mismatched identities', () async {
    await expectLater(
      TlsIdentity.load('${root}client.pem', ''),
      throwsFormatException,
    );
    await expectLater(
      TlsIdentity.load('${root}missing.pem', '${root}client-key.pem'),
      throwsFormatException,
    );
    await expectLater(
      TlsIdentity.load('${root}client.pem', '${root}server-key.pem'),
      throwsFormatException,
    );
    final dir = await Directory.systemTemp.createTemp('identity-invalid-');
    try {
      final key = File('${dir.path}/key.pem')
        ..writeAsStringSync(
          '-----BEGIN ENCRYPTED PRIVATE KEY-----\nDO_NOT_EXPOSE',
        );
      await expectLater(
        TlsIdentity.load('${root}client.pem', key.path),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'scope', contains('Encrypted'))
              .having(
                (e) => e.toString(),
                'redacted',
                isNot(contains('DO_NOT_EXPOSE')),
              ),
        ),
      );
      key.writeAsStringSync('DO_NOT_EXPOSE');
      await expectLater(
        TlsIdentity.load('${root}client.pem', key.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.toString(),
            'redacted',
            isNot(contains('DO_NOT_EXPOSE')),
          ),
        ),
      );
      key.writeAsStringSync(
        '-----BEGIN PRIVATE KEY-----\n${base64.encode([0x30, ...List.filled(31, 0)])}\n-----END PRIVATE KEY-----',
      );
      await expectLater(
        TlsIdentity.load('${root}client.pem', key.path),
        throwsFormatException,
      );
      expect(
        await TlsIdentity.load('${root}client.pem', '${root}client-key.pem'),
        isNotNull,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('real mTLS accepts identity through probe/reflection/local schema/authority/reconnect; rejects missing and untrusted clients', () async {
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    final reflection = MetadataReflection(schema);
    final fixture = CapturedFixture(schema);
    final server = Server.create(services: [fixture, reflection]);
    await server.serve(
      address: InternetAddress.loopbackIPv4,
      port: 0,
      security: RequiredClientCredentials(),
      requireClientCertificate: true,
    );
    final engine = GrpcEngine(loader);
    final identity = await TlsIdentity.load(
      '${root}client-chain.pem',
      '${root}client-key.pem',
    );
    ConnectionConfig config({
      TlsIdentity? client,
      bool reflect = true,
      Map<String, String>? headers,
      String sni = 'localhost',
    }) => ConnectionConfig(
      '127.0.0.1:${server.port}',
      tls: true,
      identity: client,
      certificates: File('${root}ca.pem').readAsBytesSync(),
      serverName: sni,
      reflection: reflect,
      localSchema: schema,
      metadata: const {'x-test': 'rpc'},
      reflectionMetadata: headers,
    );
    final method = schema.methods['/runtime.fixture.Echo/Unary']!;
    try {
      for (final headers in <Map<String, String>?>[
        {'x-reflect': 'discovery'},
        {},
        null,
      ]) {
        reflection.seen.clear();
        final discovered = await engine.connect(
          config(client: identity, headers: headers),
        );
        expect(discovered.source, 'reflection', reason: discovered.warning);
        expect(reflection.seen, isNotEmpty);
        for (final seen in reflection.seen) {
          expect(seen['x-test'], headers == null ? 'rpc' : null);
          expect(seen['x-reflect'], headers?['x-reflect']);
        }
        final result = await engine.invoke(
          method,
          {'text': 'secure'},
          metadata: {'x-test': 'rpc'},
          authority: 'different-http-authority',
        );
        expect(result.code, 'OK', reason: result.error);
        expect(result.headers['echo-header'], 'rpc');
        expect(fixture.metadata['x-reflect'], isNull);
      }
      await expectLater(
        engine.connect(config(client: identity, sni: 'wrong.invalid')),
        throwsA(isA<HandshakeException>()),
      );
      final ec = await TlsIdentity.load(
        '${root}client-ec.pem',
        '${root}client-ec-key.pem',
      );
      final local = await engine.connect(config(client: ec, reflect: false));
      expect(local.source, 'proto');
      for (final name in ['Unary', 'Watch', 'Upload', 'Chat']) {
        final rpc = schema.methods['/runtime.fixture.Echo/$name']!;
        final result = await engine.invoke(rpc, {
          'text': 'local',
        }, authority: 'rpc.example');
        expect(result.code, 'OK', reason: '$name: ${result.error}');
      }
      for (final invalid in <TlsIdentity?>[
        null,
        await TlsIdentity.load(
          '${root}untrusted.pem',
          '${root}untrusted-key.pem',
        ),
      ]) {
        final before = fixture.calls;
        var accepted = false;
        try {
          await engine.connect(config(client: invalid, reflect: false));
          accepted =
              (await engine.invoke(method, {'text': 'must fail'})).code == 'OK';
        } catch (_) {
          /* A rejected TLS handshake is also a correct outcome. */
        }
        expect(accepted, false);
        expect(fixture.calls, before);
      }
    } finally {
      await engine.disconnect();
      await server.shutdown();
    }
  });
  test('additive migration and workspace round trip preserve identity references and metadata inheritance', () {
    final dir = Directory.systemTemp.createTempSync('identity-migration-');
    var store = WorkspaceStore.open('${dir.path}/db.sqlite');
    final collection = store.save('collections', {'name': 'Retained'});
    final original = store.save('servers', {
      'name': 'Existing',
      'address': 'localhost:8443',
      'metadataJson': '{"x-token":"preserved"}',
    });
    for (final name in [
      'tls_client_certificate_file',
      'tls_client_key_file',
      'tls_server_name',
      'reflection_metadata_json',
    ]) {
      store.db.execute('ALTER TABLE servers DROP COLUMN $name');
    }
    store.close();
    store = WorkspaceStore.open('${dir.path}/db.sqlite');
    try {
      final migrated = store.list('servers').single;
      expect(store.list('collections').single, collection);
      expect(migrated['id'], original['id']);
      expect(migrated['metadataJson'], original['metadataJson']);
      expect(migrated['reflectionMetadataJson'], '');
      expect(Directory('${dir.path}/backups').listSync(), hasLength(1));
      final saved = store.save('servers', {
        ...migrated,
        'tlsClientCertificateFile': '/selected/client.pem',
        'tlsClientKeyFile': '/selected/client-key.pem',
        'tlsServerName': 'service.example',
        'reflectionMetadataJson': '{}',
      });
      expect(
        store.save('servers', {
          ...saved,
          'reflectionMetadataJson': '   ',
        })['reflectionMetadataJson'],
        '',
      );
      store.save('servers', saved);
      final exported = store.exportWorkspace(
        includeSensitiveLiterals: true,
        includeRequestBodies: true,
      );
      store.importWorkspace(exported);
      final imported = store
          .list('servers')
          .firstWhere((s) => s['id'] != saved['id']);
      for (final key in [
        'tlsClientCertificateFile',
        'tlsClientKeyFile',
        'tlsServerName',
        'reflectionMetadataJson',
      ]) {
        expect(imported[key], saved[key]);
      }
      store.importWorkspace({
        'kind': 'protodesk.workspace',
        'version': 1,
        'servers': [
          {
            'name': 'Legacy import',
            'address': 'localhost:8443',
            'metadataJson': '{"x-legacy":"retained"}',
          },
        ],
        'collections': [],
      });
      final legacy = store
          .list('servers')
          .firstWhere((s) => s['name'] == 'Legacy import (imported)');
      expect(legacy['reflectionMetadataJson'], '');
      expect(legacy['tlsClientKeyFile'], '');
      expect(legacy['metadataJson'], '{"x-legacy":"retained"}');
      expect(
        () => store.save('servers', {
          ...saved,
          'tlsClientKeyFile': '-----BEGIN PRIVATE KEY-----',
        }),
        throwsFormatException,
      );
    } finally {
      store.close();
      dir.deleteSync(recursive: true);
    }
  });
}
