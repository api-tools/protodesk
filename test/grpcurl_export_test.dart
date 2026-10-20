import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:protodesk/src/interchange/export.dart';
import 'package:protodesk/src/interchange/grpcurl.dart';
import 'package:protodesk/src/interchange/shell.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/security/catalog.dart';
import 'package:protodesk/src/security/credentials.dart';
import 'package:protodesk/src/sources/configuration.dart';
import 'package:protodesk/src/sources/discovery.dart';
import 'package:protodesk/src/sources/git_provider.dart';

import 'fixtures/credential_vault.dart';
import 'proto_sources_test.dart' show FixtureRepository;

void main() {
  final loader = ProtoLoader(
    compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
    standardRoot: 'assets/protoc/include',
  );
  late SchemaRegistry schema;
  late Directory directory;
  late WorkspaceStore store;
  late CredentialService credentials;
  late MemoryVault vault;
  late Map<String, Object?> server;
  setUpAll(() async {
    schema = await loader.load(['test/fixtures/runtime.proto'], []);
  });
  setUp(() async {
    directory = Directory.systemTemp.createTempSync(
      'protodesk-command-export-',
    );
    store = WorkspaceStore.open('${directory.path}/data.sqlite');
    vault = MemoryVault();
    credentials = CredentialService(vault, SqliteCredentialCatalog(store));
    final id = await credentials.create(
      'RPC',
      CredentialValue(
        CredentialScope.metadata('localhost:50051', tls: false),
        'synthetic-protected',
      ),
    );
    server = {
      'address': 'localhost:50051',
      'tlsEnabled': false,
      'reflectionEnabled': true,
      'metadataJson': '{"x-test":"synthetic-literal"}',
      'metadataReferencesJson': MetadataReferences({'x-private': id}).encode(),
    };
  });
  tearDown(() {
    credentials.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });
  Future<GrpcurlPreview> preview(
    CommandShell shell, {
    bool body = false,
    bool literals = false,
    bool protected = false,
    ProtoMethod? method,
    Map<String, Object?>? profile,
    String authority = '',
    SourceManifest? sources,
  }) => exportGrpcurl(
    server: profile ?? server,
    method: method ?? schema.methods['/runtime.fixture.Echo/Unary']!,
    body: jsonEncode({'text': "sensitive-payload with 'quote' 日本語\nnext"}),
    requestMetadata: '{"x-request":"request: value"}',
    requestReferences: MetadataReferences({}),
    authority: authority,
    timeoutMs: 1250,
    shell: shell,
    credentials: credentials,
    includeBody: body,
    includeLiteralHeaders: literals,
    includeProtectedHeaders: protected,
    sources: sources,
  );
  for (final shell in CommandShell.values) {
    test(
      '$shell safe preview never reads protected values or exports literals/payloads',
      () async {
        final reads = vault.reads;
        vault.locked = true;
        final result = await preview(shell);
        expect(vault.reads, reads);
        expect(result.redacted, true);
        expect(result.sensitive, false);
        for (final secret in [
          'synthetic-protected',
          'synthetic-literal',
          'sensitive-payload',
          'request: value',
        ]) {
          expect(result.command, isNot(contains(secret)));
        }
        expect(
          () => GrpcurlCommand.parse(result.command, shell),
          throwsA(isA<CommandSyntax>()),
        );
      },
    );
    test(
      '$shell explicit full export round-trips payload, headers, authority and deadline',
      () async {
        final result = await preview(
          shell,
          body: true,
          literals: true,
          protected: true,
        );
        expect(result.redacted, false);
        expect(result.sensitive, true);
        final parsed = GrpcurlCommand.parse(result.command, shell);
        expect(jsonDecode(parsed.body), {
          'text': "sensitive-payload with 'quote' 日本語\nnext",
        });
        expect(parsed.rpcHeaders, {
          'x-test': 'synthetic-literal',
          'x-private': 'synthetic-protected',
          'x-request': 'request: value',
        });
        expect(parsed.reflectionHeaders, {
          'x-test': 'synthetic-literal',
          'x-private': 'synthetic-protected',
        });
        expect(parsed.authority, 'localhost:50051');
        expect(parsed.timeoutMs, 1250);
      },
    );
  }
  test('independent SNI and reflection authority combinations fail before credential reads', () async {
    final reads = vault.reads;
    await expectLater(
      preview(
        CommandShell.posix,
        profile: {
          ...server,
          'tlsEnabled': true,
          'tlsServerName': 'different.example',
        },
      ),
      throwsA(isA<CommandSyntax>()),
    );
    await expectLater(
      preview(CommandShell.posix, authority: 'different.example'),
      throwsA(isA<CommandSyntax>()),
    );
    expect(vault.reads, reads);
  });
  test('interactive streams are explicitly unsupported; server streaming remains exportable', () async {
    await expectLater(
      preview(
        CommandShell.posix,
        method: schema.methods['/runtime.fixture.Echo/Chat'],
      ),
      throwsA(isA<CommandSyntax>()),
    );
    final result = await preview(
      CommandShell.posix,
      method: schema.methods['/runtime.fixture.Echo/Watch'],
    );
    expect(result.command, contains('runtime.fixture.Echo/Watch'));
  });
  test('local schema resolution uses selected entries and validated Git cache without credentials/network', () async {
    final cache = RepositoryCache(
      Directory('${directory.path}/schema-cache'),
      provider: FixtureRepository(),
    );
    final source = <String, Object?>{
      'type': 'git',
      'url': 'https://github.com/example/protos',
      'ref': 'main',
      'directory': 'proto',
      'roots': ['proto'],
      'entries': ['services/user.proto'],
    };
    final (_, commit) = await cache.acquire(source, SourceOperation());
    final config = SourceConfiguration({
      'version': 1,
      'sources': [
        {
          ...source,
          'commit': commit,
          'credentialRef': MetadataReferences.decode(
            server['metadataReferencesJson'] as String,
          ).headers['x-private'],
        },
      ],
      'importRoots': <String>[],
    });
    vault.locked = true;
    final reads = vault.reads;
    final manifest = await commandSourceManifest(
      loader,
      store.path,
      config,
      SourceOperation(),
    );
    expect(manifest.entries.length, 1);
    expect(manifest.entries.single, endsWith('services/user.proto'));
    expect(manifest.roots.single, endsWith('proto'));
    expect(vault.reads, reads);
    await expectLater(
      commandSourceManifest(
        loader,
        store.path,
        SourceConfiguration({
          ...config.data,
          'sources': [
            {...source, 'ref': 'missing'},
          ],
        }),
        SourceOperation(),
      ),
      throwsA(isA<CommandSyntax>()),
    );
  });
  test('relative entry names resolve through import roots, not the application working directory; escapes and symlinks are rejected', () async {
    final root = Directory('${directory.path}/proto')..createSync();
    Directory('${root.path}/services').createSync();
    File('${root.path}/services/a.proto')
        .writeAsStringSync('syntax="proto3"; message Empty {}');
    final command = GrpcurlCommand.parse(
      'grpcurl -plaintext -proto services/a.proto -import-path ${quoteArgument(root.path, CommandShell.posix)} -d \'{}\' localhost:50051 example.Echo/Call',
      CommandShell.posix,
    );
    final record = await commandServerRecord(
      command,
      'Imported',
      SourceOperation(),
    );
    final config = SourceConfiguration.fromRecord(record);
    expect(
      config.sources.single['path'],
      File(p.join(root.path, 'services/a.proto')).resolveSymbolicLinksSync(),
    );
    final escaping = GrpcurlCommand.parse(
      'grpcurl -plaintext -proto ../a.proto -import-path ${quoteArgument(root.path, CommandShell.posix)} localhost:50051 example.Echo/Call',
      CommandShell.posix,
    );
    await expectLater(
      commandServerRecord(escaping, 'Bad', SourceOperation()),
      throwsA(isA<CommandSyntax>()),
    );
    if (!Platform.isWindows) {
      Link('${root.path}/services/link.proto')
          .createSync('${root.path}/services/a.proto');
      final linked = GrpcurlCommand.parse(
        'grpcurl -plaintext -proto services/link.proto -import-path ${quoteArgument(root.path, CommandShell.posix)} localhost:50051 example.Echo/Call',
        CommandShell.posix,
      );
      await expectLater(
        commandServerRecord(linked, 'Bad', SourceOperation()),
        throwsA(isA<CommandSyntax>()),
      );
    }
  });
  test('independent roots do not compile unselected files during command validation', () async {
    final root = Directory('${directory.path}/entry-root')..createSync();
    final entry = File('${root.path}/chosen.proto')
      ..writeAsStringSync(
        'syntax="proto3"; package chosen; message Data {} service Echo { rpc Call(Data) returns(Data); }',
      );
    File('${root.path}/not-selected.proto')
        .writeAsStringSync('invalid protobuf syntax deliberately not selected');
    final config = SourceConfiguration({
      'version': 1,
      'sources': [
        {'type': 'file', 'path': entry.path},
      ],
      'importRoots': [root.path],
    });
    final manifest = await commandSourceManifest(
      loader,
      store.path,
      config,
      SourceOperation(),
    );
    expect(manifest.entries, [entry.resolveSymbolicLinksSync()]);
  });
}
