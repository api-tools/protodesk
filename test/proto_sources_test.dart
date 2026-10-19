import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:protodesk/src/sources/configuration.dart';
import 'package:protodesk/src/sources/discovery.dart';
import 'package:protodesk/src/sources/git_provider.dart';
import 'package:protodesk/src/sources/manager.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/transport/engine.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:grpc/grpc.dart';

import 'fixtures/server.dart';

const commit1 = '1111111111111111111111111111111111111111';
const commit2 = '2222222222222222222222222222222222222222';
const simple =
    'syntax="proto3"; package example; message Empty {} service Echo { rpc Call(Empty) returns (Empty); }';

class FixtureRepository implements RepositoryProvider {
  int resolves = 0, fetches = 0;
  String revision = commit1;
  bool offline = false, invalid = false;
  @override
  Future<String> resolve(
    String url,
    String reference,
    SourceOperation operation,
  ) async {
    resolves++;
    if (offline || reference == 'missing') {
      throw const FormatException('Repository fetch failed');
    }
    return RegExp(r'^[0-9a-f]{40}$').hasMatch(reference) ? reference : revision;
  }

  @override
  Future<void> fetch(
    String url,
    String commit,
    Directory destination,
    SourceOperation operation,
  ) async {
    fetches++;
    if (offline) throw const FormatException('Offline');
    await File(p.join(destination.path, 'proto/services/user.proto')).parent
        .create(recursive: true);
    await File(p.join(destination.path, 'proto/services/user.proto'))
        .writeAsString(
          invalid ? 'invalid' : 'syntax="proto3"; import "common/types.proto"; package example; service Echo { rpc Call(Empty) returns (Empty); }',
        );
    await File(p.join(destination.path, 'proto/common/types.proto')).parent
        .create(recursive: true);
    await File(p.join(destination.path, 'proto/common/types.proto'))
        .writeAsString('syntax="proto3"; package example; message Empty {}');
  }
}

class InterruptedRepository extends FixtureRepository {
  bool interrupt = false;
  @override
  Future<void> fetch(
    String url,
    String commit,
    Directory destination,
    SourceOperation operation,
  ) async {
    if (interrupt) {
      await File(p.join(destination.path, 'partial.proto'))
          .writeAsString(simple);
      throw const FormatException('Interrupted repository download');
    }
    await super.fetch(url, commit, destination, operation);
  }
}

class PendingCompiler extends ProtoLoader {
  final pending = Completer<SchemaValidation>();
  PendingCompiler() : super(compiler: 'unused', standardRoot: 'unused');
  @override
  Future<SchemaValidation> validate(
    List<String> files,
    List<String> roots, {
    required SourceOperation operation,
    List<String> discoverFolders = const [],
  }) => pending.future;
}

class LargeDiscovery extends FileDiscovery {
  @override
  Future<List<String>> discover(String root, SourceOperation operation) async =>
      List.generate(1025, (i) => '$i.proto');
}

void main() {
  final loader = ProtoLoader(
    compiler: 'assets/protoc/bin/protoc',
    standardRoot: 'assets/protoc/include',
  );
  late Directory dir;
  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('proto-sources-test-');
    dir = Directory(await temp.resolveSymbolicLinks());
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  Future<String> write(String name, String text) async {
    final file = File(p.join(dir.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
    return file.path;
  }

  SourceConfiguration local(
    List<Map<String, Object?>> sources, [
    List<String>? roots,
  ]) => SourceConfiguration({
    'version': 1,
    'sources': sources,
    'importRoots': roots ?? [],
  });
  SourceConfiguration git({
    String ref = 'main',
    String directory = 'proto',
    List<String> roots = const ['proto'],
    List<String>? entries,
  }) => local([
    {
      'type': 'git',
      'url': 'https://github.com/example/protos',
      'ref': ref,
      'directory': directory,
      'roots': roots,
      'entries': ?entries,
    },
  ]);
  SourceManager manager({FixtureRepository? provider}) => SourceManager(
    loader,
    RepositoryCache(
      Directory(p.join(dir.path, 'cache')),
      provider: provider ?? FixtureRepository(),
    ),
  );

  test('single file, multiple files, and folder discovery select entry points independently', () async {
    final a = await write('proto/services/a.proto', simple);
    await write('proto/unused.proto', 'this is malformed and must not compile');
    final m = manager();
    final (result, manifest) = await m.validate(
      local([
        {
          'type': 'directory',
          'path': p.join(dir.path, 'proto'),
          'entries': ['services/a.proto'],
        },
      ]),
      SourceOperation(),
    );
    expect(result.schema.services, ['example.Echo']);
    expect(manifest.discovered[0], ['services/a.proto', 'unused.proto']);
    expect(result.entryPoints, ['services/a.proto']);
    final (one, _) = await m.validate(
      local([
        {'type': 'file', 'path': a},
      ]),
      SourceOperation(),
    );
    expect(one.schema.methods.length, 1);
    final b = await write(
      'other/b.proto',
      'syntax="proto3"; package second; message B {}',
    );
    final (multiple, _) = await m.validate(
      local([
        {'type': 'file', 'path': a},
        {'type': 'file', 'path': b},
      ]),
      SourceOperation(),
    );
    expect(multiple.schema.messages, contains('second.B'));
  });
  for (final quote in ['"', "'"]) {
    for (final modifier in ['', 'public ', 'weak ']) {
      test('$quote imports with $modifier support nested/shared dependencies', () async {
        await write(
          'proto/common/base.proto',
          'syntax="proto2"; package sample; message Base { optional string name=1; }',
        );
        await write(
          'proto/common/types.proto',
          'syntax="proto3"; import public "common/base.proto"; package sample; message Type { Base base=1; }',
        );
        final a = await write(
          'proto/services/user.proto',
          'syntax="proto3"; import $modifier${quote}common/types.proto$quote; package sample; message User { Type type=1; }',
        );
        final b = await write(
          'proto/services/shared.proto',
          'syntax="proto3"; import "common/types.proto"; package sample; message Shared { Type type=1; }',
        );
        final result = await loader.validate(
          [a, b],
          [p.join(dir.path, 'proto')],
          operation: SourceOperation(),
        );
        expect(result.schema.files.length, 4);
        expect(result.dependencies, 2);
        expect(
          result.resolved['common/types.proto'],
          p.join(dir.path, 'proto'),
        );
      });
    }
  }
  test(
    'missing import includes compiler location and configured roots',
    () async {
      final file = await write(
        'user.proto',
        'syntax="proto3";\nimport "common/types.proto";',
      );
      try {
        await loader.validate([file], [dir.path], operation: SourceOperation());
        fail('must reject');
      } on SchemaDiagnostic catch (e) {
        expect(e.category, 'Missing import');
        expect(e.output, contains('user.proto:2'));
        expect(e.message, contains('common/types.proto'));
        expect(e.roots, [dir.path]);
      }
    },
  );
  test('malformed syntax, duplicate definitions and editions have distinct diagnostics', () async {
    var file = await write(
      'bad.proto',
      'syntax="proto3"; message Bad { invalid }',
    );
    await expectLater(
      loader.load([file], []),
      throwsA(
        isA<SchemaDiagnostic>().having(
          (e) => e.category,
          'category',
          'Invalid Protobuf syntax',
        ),
      ),
    );
    file = await write('bad.proto', 'edition="2023"; message Bad {}');
    await expectLater(
      loader.load([file], []),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('editions'),
        ),
      ),
    );
    final a = await write('a.proto', 'syntax="proto3"; message Duplicate {}');
    final b = await write('b.proto', 'syntax="proto3"; message Duplicate {}');
    await expectLater(
      loader.load([a, b], []),
      throwsA(
        isA<SchemaDiagnostic>().having(
          (e) => e.category,
          'category',
          'Conflicting definitions',
        ),
      ),
    );
  });
  test('conflicting import names are rejected deterministically', () async {
    final a = await write('one/types.proto', simple);
    await write('two/types.proto', simple);
    await expectLater(
      loader.validate(
        [a],
        [p.join(dir.path, 'one'), p.join(dir.path, 'two')],
        operation: SourceOperation(),
      ),
      throwsA(
        isA<SchemaDiagnostic>().having(
          (e) => e.category,
          'category',
          'Conflicting import path',
        ),
      ),
    );
  });
  test('discovery rejects links, traversal, oversized files, empty selections and missing files', () async {
    final file = await write('source.proto', simple);
    await Link(p.join(dir.path, 'link.proto')).create(file);
    await expectLater(
      FileDiscovery().discover(dir.path, SourceOperation()),
      throwsFormatException,
    );
    await Link(p.join(dir.path, 'link.proto')).delete();
    await write('bad.proto', 'syntax="proto3"; import "../escape.proto";');
    await expectLater(
      loader.load([p.join(dir.path, 'bad.proto')], []),
      throwsFormatException,
    );
    await expectLater(
      loader.load([p.join(dir.path, 'missing.proto')], []),
      throwsFormatException,
    );
    await expectLater(
      loader.validate([], [dir.path], operation: SourceOperation()),
      throwsFormatException,
    );
    await write('huge.proto', 'x' * (SourceLimits.fileBytes + 1));
    await expectLater(
      FileDiscovery().discover(dir.path, SourceOperation()),
      throwsFormatException,
    );
  });
  test('Git subdirectory, nested roots, selected entry points, cached reuse and offline validation', () async {
    final provider = FixtureRepository(),
        m = manager(provider: FixtureRepository());
    final actual = SourceManager(
      loader,
      RepositoryCache(
        Directory(p.join(dir.path, 'git-cache')),
        provider: provider,
      ),
    );
    final (first, manifest) = await actual.validate(
      git(entries: ['services/user.proto']),
      SourceOperation(),
    );
    expect(first.schema.services, ['example.Echo']);
    expect(manifest.configuration.sources.single['commit'], commit1);
    expect(provider.fetches, 1);
    expect(provider.resolves, 1);
    provider.offline = true;
    final (offline, _) = await actual.validate(
      manifest.configuration,
      SourceOperation(),
    );
    expect(offline.schema.methods.length, 1);
    expect(provider.fetches, 1);
    expect(provider.resolves, 1);
    expect(m.loader, loader);
  });
  test(
    'Git explicit commit, missing reference and paths escaping repository',
    () async {
      final m = manager();
      final (_, manifest) = await m.validate(
        git(ref: commit2),
        SourceOperation(),
      );
      expect(manifest.configuration.sources.single['commit'], commit2);
      await expectLater(
        m.validate(git(ref: 'missing'), SourceOperation()),
        throwsFormatException,
      );
      expect(() => git(directory: '../escape'), throwsFormatException);
      expect(() => git(roots: ['/absolute']), throwsFormatException);
      expect(() => git(entries: ['../escape.proto']), throwsFormatException);
    },
  );
  test('refresh to new commit and failed fetch/compilation preserve last valid schema', () async {
    final provider = FixtureRepository(),
        m = manager(provider: FixtureRepository());
    final actual = SourceManager(
      loader,
      RepositoryCache(
        Directory(p.join(dir.path, 'git-cache')),
        provider: provider,
      ),
    );
    final (_, first) = await actual.validate(
      git(entries: ['services/user.proto']),
      SourceOperation(),
    );
    provider.revision = commit2;
    final (_, second) = await actual.validate(
      first.configuration,
      SourceOperation(),
      refresh: true,
    );
    expect(second.configuration.sources.single['commit'], commit2);
    provider.offline = true;
    await expectLater(
      actual.validate(second.configuration, SourceOperation(), refresh: true),
      throwsFormatException,
    );
    final (old, _) = await actual.validate(
      first.configuration,
      SourceOperation(),
    );
    expect(old.schema.services, ['example.Echo']);
    provider.offline = false;
    provider.revision = '3333333333333333333333333333333333333333';
    provider.invalid = true;
    await expectLater(
      actual.validate(first.configuration, SourceOperation(), refresh: true),
      throwsFormatException,
    );
    expect(first.configuration.sources.single['commit'], commit1);
    await actual.validate(first.configuration, SourceOperation());
    expect(m.loader, loader);
    expect(
      Directory(p.join(dir.path, 'git-cache'))
          .listSync(recursive: true)
          .any((e) => p.basename(e.path).startsWith('.fetch-')),
      false,
    );
  });
  test('URL validation rejects credentials, private hosts, redirects, insecure URLs and escape encodings', () {
    for (final url in [
      'http://github.com/a/b',
      'https://token@github.com/a/b',
      'https://127.0.0.1/a/b',
      'https://localhost/a/b',
      'https://github.com.evil/a/b',
      'https://github.com/a/b?token=secret',
      'https://github.com/a/%2e%2e',
      'https://github.com:443/a/b',
    ]) {
      expect(() => repository(url), throwsFormatException);
    }
    for (final address in [
      '127.0.0.1',
      '10.0.0.1',
      '169.254.1.1',
      '172.16.0.1',
      '192.168.0.1',
      '::1',
    ]) {
      expect(GitHubProvider.publicAddress(InternetAddress(address)), false);
    }
    expect(repository('https://github.com/example/protos.git'), (
      'example',
      'protos',
    ));
  });
  test('GitHub provider resolves actual SHA and extracts only safe proto archive content', () async {
    final archive = Archive()
      ..add(ArchiveFile.string('repo-$commit1/proto/a.proto', simple))
      ..add(
        ArchiveFile.string('repo-$commit1/install.sh', 'must never execute'),
      );
    final provider = GitHubProvider(
      request: (path, operation) async {
        expect(path.last, 'main');
        return {'sha': commit1};
      },
      download: (uri, operation) async {
        expect(uri.host, 'codeload.github.com');
        expect(uri.path, contains(commit1));
        return ZipEncoder().encode(archive);
      },
    );
    expect(
      await provider.resolve(
        'https://github.com/example/protos',
        'main',
        SourceOperation(),
      ),
      commit1,
    );
    await provider.fetch(
      'https://github.com/example/protos',
      commit1,
      dir,
      SourceOperation(),
    );
    expect(File(p.join(dir.path, 'proto/a.proto')).existsSync(), true);
    expect(File(p.join(dir.path, 'install.sh')).existsSync(), false);
  });
  test('malicious archives reject traversal, symlinks, duplicate case paths and oversized proto', () {
    for (final files in [
      [ArchiveFile.string('repo/../escape.proto', simple)],
      [ArchiveFile.string('repo/link.proto', '/etc/passwd')..mode = 0xa1ff],
      [
        ArchiveFile.string('repo/a.proto', simple),
        ArchiveFile.string('repo/A.proto', simple),
      ],
      [
        ArchiveFile.string(
          'repo/huge.proto',
          'x' * (SourceLimits.fileBytes + 1),
        ),
      ],
    ]) {
      final archive = Archive();
      for (final file in files) {
        archive.add(file);
      }
      expect(
        () => GitHubProvider.extractArchive(
          ZipEncoder().encode(archive),
          dir.path,
        ),
        throwsFormatException,
      );
    }
  });
  test('cancellation does not publish a partial revision', () async {
    final operation = SourceOperation()..cancel();
    await expectLater(
      manager().validate(git(), operation),
      throwsFormatException,
    );
    expect(Directory(p.join(dir.path, 'cache')).existsSync(), false);
  });
  test('migration backs up old source columns, preserves identifiers and isolates corrupted records', () async {
    final path = p.join(dir.path, 'workspace.sqlite');
    var store = WorkspaceStore.open(path);
    final old = store.save('servers', {
      'name': 'Legacy',
      'address': 'example.invalid:443',
      'protoFiles': ['old.proto'],
      'protoFolders': ['old-root'],
    });
    final bad = store.save('servers', {
      'name': 'Broken',
      'address': 'example.invalid:443',
    });
    store.db.execute('ALTER TABLE servers DROP COLUMN proto_sources_json');
    store.db.execute('UPDATE servers SET proto_files_json=? WHERE id=?', [
      'not JSON',
      bad['id'],
    ]);
    store.close();
    store = WorkspaceStore.open(path);
    final records = store.list('servers');
    expect(records.length, 2);
    final valid = records.singleWhere((r) => r['id'] == old['id']);
    expect(valid['protoFiles'], ['old.proto']);
    expect(SourceConfiguration.fromRecord(valid).sources.length, 2);
    final broken = records.singleWhere((r) => r['id'] == bad['id']);
    expect(broken['sourceError'], isNotNull);
    expect(broken['protoFilesJson'], 'not JSON');
    final desk = DeskController(store, GrpcEngine(loader));
    expect(desk.servers.length, 2);
    final backup = sqlite3.open(
      Directory(p.join(dir.path, 'backups')).listSync().single.path,
    );
    expect(
      backup
          .select('PRAGMA table_info(servers)')
          .any((r) => r['name'] == 'proto_sources_json'),
      false,
    );
    backup.close();
    desk.dispose();
  });
  test('workspace v2 roundtrip preserves config extensions; version 1 remains accepted; caches excluded', () async {
    final store = WorkspaceStore.open(p.join(dir.path, 'workspace.sqlite'));
    final config = {
      ...git().data,
      'vendorExtension': {'preserved': true},
    };
    store.save('servers', {
      'name': 'Git',
      'address': 'example.invalid:443',
      'protoSources': config,
    });
    final export = store.exportWorkspace();
    expect(export['version'], 2);
    expect(jsonEncode(export), isNot(contains('schema-cache')));
    store.importWorkspace(export);
    expect(store.list('servers').last['protoSources'], config);
    store.importWorkspace({
      'kind': 'protodesk.workspace',
      'version': 1,
      'servers': [
        {
          'name': 'Legacy',
          'address': 'example.invalid:443',
          'protoFiles': ['x.proto'],
          'protoFolders': [],
        },
      ],
      'collections': [],
    });
    expect(store.list('servers').length, 3);
    store.close();
  });
  test('schema browsing is independent from offline transport and preserves execution guard', () async {
    final file = await write('api.proto', simple);
    final store = WorkspaceStore.open(p.join(dir.path, 'workspace.sqlite'));
    store.save('servers', {
      'name': 'Offline',
      'address': '127.0.0.1:1',
      'reflectionEnabled': true,
      'protoFiles': [file],
    });
    final desk = DeskController(store, GrpcEngine(loader));
    await desk.browseSources();
    expect(desk.schema.services, ['example.Echo']);
    expect(desk.connected, false);
    desk.selectMethod(desk.schema.methods.values.first);
    await desk.invoke();
    expect(desk.invoking, false);
    await desk.connect();
    expect(desk.connected, false);
    expect(desk.schema.services, ['example.Echo']);
    expect(desk.status, contains('transport'));
    desk.dispose();
  });
  test('missing nested import suggests the matching project root', () async {
    await write(
      'proto/common/types.proto',
      'syntax="proto3"; message Empty {}',
    );
    final file = await write(
      'proto/services/user.proto',
      'syntax="proto3"; import "common/types.proto";',
    );
    try {
      await loader.load([file], []);
      fail('must fail without project root');
    } on SchemaDiagnostic catch (e) {
      expect(e.suggestions, contains(p.join(dir.path, 'proto')));
    }
  });
  test('local, directory and Git sources can compile together', () async {
    final file = await write(
      'local.proto',
      'syntax="proto3"; package local; message Local {}',
    );
    final folder = p.join(dir.path, 'directory');
    await write(
      'directory/folder.proto',
      'syntax="proto3"; package folder; message Folder {}',
    );
    final combined = local([
      {'type': 'file', 'path': file},
      {'type': 'directory', 'path': folder},
      ...git(entries: ['services/user.proto']).sources,
    ]);
    final (result, _) = await manager().validate(combined, SourceOperation());
    expect(
      result.schema.messages.keys,
      containsAll(['local.Local', 'folder.Folder', 'example.Empty']),
    );
  });
  test('cross-platform local import-name collisions are rejected', () async {
    final file = await write('one/a.proto', simple);
    await write('two/A.proto', simple);
    await expectLater(
      loader.validate(
        [file],
        [p.join(dir.path, 'one'), p.join(dir.path, 'two')],
        operation: SourceOperation(),
      ),
      throwsFormatException,
    );
  });
  test(
    'unknown workspace record fields and source types never silently disappear',
    () {
      final store = WorkspaceStore.open(p.join(dir.path, 'workspace.sqlite'));
      final server = store.save('servers', {
        'name': 'Original',
        'address': 'example.invalid:443',
      });
      final export = store.exportWorkspace();
      (export['servers'] as List).single['futureField'] = 'preserve';
      expect(() => store.importWorkspace(export), throwsFormatException);
      expect(store.list('servers').single['id'], server['id']);
      expect(
        () => local([
          {'type': 'future', 'path': 'x'},
        ]),
        throwsFormatException,
      );
      expect(
        () => SourceConfiguration({
          'version': 2,
          'sources': [],
          'importRoots': [],
        }),
        throwsFormatException,
      );
      store.close();
    },
  );
  test('GitHub rejects invalid revision responses and never echoes URL credentials', () async {
    final provider = GitHubProvider(
      request: (path, operation) async => {'sha': 'invalid'},
    );
    await expectLater(
      provider.resolve(
        'https://github.com/example/protos',
        'main',
        SourceOperation(),
      ),
      throwsFormatException,
    );
    try {
      repository('https://SUPER_SECRET@github.com/example/protos');
      fail('must reject');
    } on FormatException catch (e) {
      expect(e.message, isNot(contains('SUPER_SECRET')));
    }
  });
  for (final reflected in [true, false]) {
    test(
      'reflection-first discovery and unified source fallback preserve RPCs ($reflected)',
      () async {
        final registry = await loader.load(['test/fixtures/runtime.proto'], []);
        final fixture = FixtureService(registry);
        final server = Server.create(
          services: [
            fixture,
            ReflectionFixture(registry, available: reflected),
          ],
        );
        await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
        final engine = GrpcEngine(loader);
        var sourceCalls = 0;
        try {
          final result = await engine.connect(
            ConnectionConfig(
              '127.0.0.1:${server.port}',
              schemaProvider: () async {
                sourceCalls++;
                return registry;
              },
            ),
          );
          expect(result.source, reflected ? 'reflection' : 'proto');
          expect(sourceCalls, reflected ? 0 : 1);
          expect(
            result.schema.methods.keys,
            containsAll(registry.methods.keys),
          );
        } finally {
          await engine.disconnect();
          await server.shutdown();
        }
      },
    );
  }
  test(
    'cached revision tampering and managed-root symlinks are rejected',
    () async {
      final m = manager();
      final (_, first) = await m.validate(
        git(entries: ['services/user.proto']),
        SourceOperation(),
      );
      final cached = File(
        p.join(
          dir.path,
          'cache/example--protos',
          commit1,
          'proto/common/types.proto',
        ),
      );
      await cached.writeAsString(
        'syntax="proto3"; package changed; message Empty {}',
      );
      await expectLater(
        m.validate(first.configuration, SourceOperation()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Cached repository content changed'),
          ),
        ),
      );
      final outside = Directory(p.join(dir.path, 'outside'))..createSync();
      final linked = p.join(dir.path, 'linked-cache');
      await Link(linked).create(outside.path);
      final unsafe = SourceManager(
        loader,
        RepositoryCache(Directory(linked), provider: FixtureRepository()),
      );
      await expectLater(
        unsafe.validate(git(), SourceOperation()),
        throwsFormatException,
      );
      expect(outside.listSync(), isEmpty);
    },
  );
  test(
    'legacy workspace raw source JSON is migrated without silent discard',
    () {
      final store = WorkspaceStore.open(
        p.join(dir.path, 'raw-workspace.sqlite'),
      );
      store.importWorkspace({
        'kind': 'protodesk.workspace',
        'version': 1,
        'servers': [
          {
            'name': 'Raw legacy',
            'address': 'example.invalid:443',
            'protoFilesJson': '["old.proto"]',
            'protoFoldersJson': '["include"]',
          },
        ],
        'collections': [],
      });
      expect(store.list('servers').single['protoFiles'], ['old.proto']);
      expect(
        SourceConfiguration.fromRecord(store.list('servers').single)
            .sources
            .length,
        2,
      );
      expect(
        () => store.importWorkspace({
          'kind': 'protodesk.workspace',
          'version': 2,
          'servers': [
            {
              'name': 'Unsupported',
              'address': 'example.invalid:443',
              'protoSourcesJson':
                  '{"version":99,"sources":[],"importRoots":[]}',
            },
          ],
          'collections': [],
        }),
        throwsFormatException,
      );
      expect(store.list('servers').length, 1);
      store.close();
    },
  );
  test(
    'interrupted downloads cannot replace a previously validated revision',
    () async {
      final provider = InterruptedRepository();
      final m = SourceManager(
        loader,
        RepositoryCache(
          Directory(p.join(dir.path, 'cache')),
          provider: provider,
        ),
      );
      final (_, first) = await m.validate(
        git(entries: ['services/user.proto']),
        SourceOperation(),
      );
      provider.revision = commit2;
      provider.interrupt = true;
      await expectLater(
        m.validate(first.configuration, SourceOperation(), refresh: true),
        throwsFormatException,
      );
      expect(
        Directory(p.join(dir.path, 'cache/example--protos', commit2))
            .existsSync(),
        false,
      );
      expect(
        Directory(p.join(dir.path, 'cache'))
            .listSync(recursive: true)
            .any((entry) => p.basename(entry.path).startsWith('.fetch-')),
        false,
      );
      final (preserved, _) = await m.validate(
        first.configuration,
        SourceOperation(),
      );
      expect(preserved.schema.services, ['example.Echo']);
    },
  );
  test(
    'vendored well-known types resolve before bundled fallback definitions',
    () async {
      await write(
        'proto/google/protobuf/empty.proto',
        await File('assets/protoc/include/google/protobuf/empty.proto')
            .readAsString(),
      );
      final file = await write(
        'proto/services/api.proto',
        'syntax="proto3"; import "google/protobuf/empty.proto"; service Echo { rpc Call(google.protobuf.Empty) returns (google.protobuf.Empty); }',
      );
      final result = await loader.validate(
        [file],
        [p.join(dir.path, 'proto')],
        operation: SourceOperation(),
      );
      expect(result.schema.services, ['Echo']);
      expect(result.dependencies, 1);
      expect(
        result.resolved['google/protobuf/empty.proto'],
        p.join(dir.path, 'proto'),
      );
      expect(result.metadata['warnings'], 0);
    },
  );
  test(
    'method selection during offline discovery cannot strand connecting state',
    () async {
      final file = await write('select.proto', simple);
      final registry = await loader.load([file], []);
      final compiler = PendingCompiler();
      final store = WorkspaceStore.open(p.join(dir.path, 'select.sqlite'));
      store.save('servers', {
        'name': 'Browse',
        'address': '127.0.0.1:1',
        'protoFiles': [file],
      });
      final desk = DeskController(store, GrpcEngine(compiler));
      desk.schema = registry;
      final browsing = desk.browseSources();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(desk.connecting, true);
      desk.selectMethod(registry.methods.values.first);
      compiler.pending.complete(
        SchemaValidation(registry, {}, ['select.proto'], ''),
      );
      await browsing;
      expect(desk.connecting, false);
      expect(desk.method!.path, registry.methods.values.first.path);
      expect(desk.connected, false);
      desk.dispose();
    },
  );
  test(
    'combined directories cannot bypass the aggregate discovery limit',
    () async {
      final first = Directory(p.join(dir.path, 'first'))..createSync();
      final second = Directory(p.join(dir.path, 'second'))..createSync();
      final m = SourceManager(
        loader,
        RepositoryCache(Directory(p.join(dir.path, 'cache'))),
        discovery: LargeDiscovery(),
      );
      await expectLater(
        m.discover(
          local([
            {'type': 'directory', 'path': first.path},
            {'type': 'directory', 'path': second.path},
          ]),
          SourceOperation(),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'overlapping file and folder selections reuse a single compilation entry',
    () async {
      final file = await write('overlap.proto', simple);
      final manifest = await manager().discover(
        local([
          {'type': 'file', 'path': file},
          {'type': 'directory', 'path': dir.path},
        ]),
        SourceOperation(),
      );
      expect(manifest.entries, [file]);
    },
  );
}
