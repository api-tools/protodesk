import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/codec.dart';
import 'package:protodesk/src/security/catalog.dart';
import 'package:protodesk/src/security/credentials.dart';
import 'package:protodesk/src/security/metadata.dart';
import 'package:protodesk/src/transport/engine.dart';
import 'package:protodesk/src/workflow/preparation.dart';
import 'package:protodesk/src/workflow/preparation_storage.dart';

import 'fixtures/credential_vault.dart';
import 'fixtures/server.dart';
import 'request_preparation_test.dart' show profiles, preset, prepare;

void main() {
  late Directory directory;
  late WorkspaceStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('desk-preparation-');
    store = WorkspaceStore.open('${directory.path}/data.sqlite');
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });
  test('typed preparation preserves optional/wrapper empty presence and explicit Value null in the real codec', () async {
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final codec = ProtoCodec(
      await loader.load(['test/fixtures/presence.proto'], []),
    );
    final definitions = profiles(
      values: {
        'empty': '',
        'nil': null,
        'zero': 0,
        'disabled': false,
        'child': {},
      },
    );
    final result = prepare(
      definitions,
      r'{"text":"${empty}","child":"${child}","stringWrapper":"${empty}","intWrapper":"${zero}","boolWrapper":"${disabled}"}',
    );
    final body = jsonDecode(result.body);
    expect(codec.encode('presence.fixture.Request', body), [
      10,
      0,
      18,
      0,
      26,
      0,
      34,
      0,
      42,
      0,
    ]);
    expect(
      codec.decode(
        'presence.fixture.Request',
        codec.encode('presence.fixture.Request', body),
      ),
      body,
    );
    final nil = jsonDecode(prepare(definitions, r'"${nil}"').body);
    expect(
      codec.decode(
        'google.protobuf.Value',
        codec.encode('google.protobuf.Value', nil),
      ),
      isNull,
    );
  });
  test('reusable templates survive restart and remain excluded from every workspace export', () {
    final templates = PreparationTemplateStore(store);
    expect(store.db.select('SELECT * FROM request_templates'), isEmpty);
    const source = PreparationTemplate(
      r'{"text":"${name}"}',
      r'{"x-test":"${name}","authorization":"synthetic-template-literal"}',
      '',
    );
    templates.save('server', '/fixture.Service/Call', source);
    expect(
      jsonEncode(
        store.exportWorkspace(
          includeSensitiveLiterals: true,
          includeRequestBodies: true,
        ),
      ),
      isNot(contains('synthetic-template-literal')),
    );
    store.close();
    store = WorkspaceStore.open('${directory.path}/data.sqlite');
    expect(
      PreparationTemplateStore(store)
          .load('server', '/fixture.Service/Call')!
          .encode(),
      source.encode(),
    );
    expect(
      PreparationTemplateStore(store).load('other', '/fixture.Service/Call'),
      isNull,
    );
  });
  test('deleting a server removes only its local drafts and templates transactionally', () {
    final ids = <String, String>{};
    for (final name in ['deleted', 'retained']) {
      final server = store.save('servers', {
        'name': name,
        'address': 'localhost:50051',
      });
      final id = ids[name] = server['id'] as String;
      for (final table in ['request_drafts', 'request_templates']) {
        for (final workspace in ['local', 'another-workspace']) {
          store.db.execute('INSERT INTO $table VALUES(?,?,?,?,?)', [
            workspace,
            id,
            '/fixture.Service/Call',
            '{"version":900,"literal":"retained-until-deletion"}',
            '2026-10-21',
          ]);
        }
      }
    }
    store.delete('servers', ids['deleted']!);
    expect(store.list('servers').single['id'], ids['retained']);
    for (final table in ['request_drafts', 'request_templates']) {
      expect(
        store.db.select(
          'SELECT * FROM $table WHERE workspace_id=? AND server_id=?',
          ['local', ids['deleted']],
        ),
        isEmpty,
      );
      expect(store.db.select('SELECT * FROM $table').length, 3);
    }
  });
  test('future reusable template is preserved rather than replaced', () {
    const raw = '{"version":900,"future":"preserve-original"}';
    store.db.execute('INSERT INTO request_templates VALUES(?,?,?,?,?)', [
      'local',
      'server',
      '/fixture.Service/Call',
      raw,
      '2026-10-21',
    ]);
    expect(
      () => PreparationTemplateStore(store).save(
        'server',
        '/fixture.Service/Call',
        const PreparationTemplate('{}', '{}', ''),
      ),
      throwsA(isA<PreparationFailure>()),
    );
    store.close();
    store = WorkspaceStore.open('${directory.path}/data.sqlite');
    expect(
      PreparationTemplateStore(store).raw('server', '/fixture.Service/Call'),
      raw,
    );
  });
  test('profile definitions persist and safe/full workspace transfer preserves bindings and explicit null', () {
    final definitions = profiles(
      values: {'empty': '', 'nil': null, 'secret': 'synthetic-local-secret'},
      presets: [
        preset('headers', {'authorization': 'synthetic-header-secret'}),
      ],
    );
    final saved = store.save('servers', {
      'name': 'Preparation fixture',
      'address': 'localhost:1234',
      'requestProfilesJson': definitions.encode(),
    });
    final safe = store.exportWorkspace();
    expect(jsonEncode(safe), isNot(contains('synthetic-local-secret')));
    expect(jsonEncode(safe), isNot(contains('synthetic-header-secret')));
    store.importWorkspace(safe);
    final restored = store
        .list('servers')
        .firstWhere((s) => s['id'] != saved['id']);
    final imported = PreparationProfiles.decode(
      restored['requestProfilesJson'] as String,
    );
    expect((imported.environments.single['variables'] as Map)['nil'], {
      'bound': false,
    });
    final full = store.exportWorkspace(
      includeSensitiveLiterals: true,
      includeRequestBodies: true,
    );
    expect(jsonEncode(full), contains('synthetic-local-secret'));
    store.importWorkspace(full);
    expect(
      store
          .list('servers')
          .any((s) => s['requestProfilesJson'] == definitions.encode()),
      true,
    );
  });
  test('malformed/future definitions do not block startup or unrelated profile updates and are never discarded', () {
    final saved = store.save('servers', {
      'name': 'Future fixture',
      'address': 'localhost:1234',
    });
    const future = '{"version":900,"future":"preserve"}';
    store.db.execute('UPDATE servers SET request_profiles_json=? WHERE id=?', [
      future,
      saved['id'],
    ]);
    store.close();
    store = WorkspaceStore.open('${directory.path}/data.sqlite');
    final record = store.list('servers').single;
    final edited = store.save('servers', {...record, 'name': 'Renamed safely'});
    expect(edited['requestProfilesJson'], future);
    expect(() => store.exportWorkspace(), throwsA(isA<PreparationFailure>()));
    expect(
      jsonEncode(store.exportWorkspace(includeSensitiveLiterals: true)),
      contains('preserve'),
    );
    expect(
      () => store.importWorkspace(
        store.exportWorkspace(includeSensitiveLiterals: true),
      ),
      throwsA(isA<PreparationFailure>()),
    );
    expect(store.list('servers').length, 1);
    expect(store.list('servers').single['requestProfilesJson'], future);
  });
  test('preparation carries protected references without reading or weakening recipient binding', () async {
    final vault = MemoryVault();
    final credentials = CredentialService(
      vault,
      SqliteCredentialCatalog(store),
    );
    final scope = CredentialScope.metadata('first.example:443', tls: true);
    final id = await credentials.create(
      'Synthetic preset',
      CredentialValue(scope, 'synthetic-protected-secret'),
    );
    vault.reads = 0;
    final result = prepare(
      profiles(
        presets: [
          preset('protected', {}, {'authorization': id}),
        ],
      ),
      '{}',
      selected: ['protected'],
    );
    expect(vault.reads, 0);
    expect(
      jsonEncode(result.metadata),
      isNot(contains('synthetic-protected-secret')),
    );
    final other = {
      'address': 'other.example:443',
      'tlsEnabled': true,
      'metadataJson': '{}',
    };
    final plan = MetadataPlan.rpc(
      other,
      jsonEncode(result.metadata),
      result.references,
    );
    await expectLater(
      plan.resolve(
        credentials,
        CredentialScope.metadata('other.example:443', tls: true),
      ),
      throwsA(isA<CredentialFailure>()),
    );
    // Resolution checks the protected payload's authoritative scope before
    // returning a value; preparation itself performed zero vault reads.
    expect(vault.reads, 1);
    credentials.dispose();
  });
  test('explicitly prepared nested and false values reach a real local RPC without changing reflection metadata', () async {
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    final server = Server.create(
      services: [FixtureService(schema), ReflectionFixture(schema)],
    );
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final engine = GrpcEngine(loader);
    try {
      final definitions = profiles(
        values: {
          'text': 'prepared runtime',
          'enabled': false,
          'nested': {'text': 'nested'},
        },
        presets: [
          preset('rpc', {'x-test': r'${text}'}),
        ],
      );
      final profile = store.save('servers', {
        'name': 'Runtime preparation',
        'address': '127.0.0.1:${server.port}',
        'metadataJson': '{"x-base":"base"}',
        'reflectionMetadataJson': '{"x-discovery":"unchanged"}',
        'requestProfilesJson': definitions.encode(),
      });
      final result = prepare(
        definitions,
        r'{"text":"${text}","present":"${enabled}","nested":"${nested}"}',
        selected: ['rpc'],
      );
      expect(MetadataPlan.reflection(profile).literals, {
        'x-discovery': 'unchanged',
      });
      await engine.connect(
        ConnectionConfig(
          profile['address'] as String,
          reflectionMetadata: MetadataPlan.reflection(profile).literals,
        ),
      );
      final response = await engine.invoke(
        engine.schema.methods['/runtime.fixture.Echo/Unary']!,
        jsonDecode(result.body),
        metadata: MetadataPlan.rpc(
          profile,
          jsonEncode(result.metadata),
          result.references,
        ).literals,
      );
      expect(response.code, 'OK');
      expect(response.messages.single, {
        'text': 'prepared runtime',
        'present': false,
        'nested': {'text': 'nested'},
      });
      expect(response.headers['echo-header'], 'prepared runtime');
    } finally {
      await engine.disconnect();
      await server.shutdown();
    }
  });
}
