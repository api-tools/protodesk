import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:protodesk/src/presentation/design.dart';
import 'package:protodesk/src/presentation/proto_sources.dart';
import 'package:protodesk/src/presentation/dialogs.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/sources/configuration.dart';
import 'package:protodesk/src/sources/manager.dart';
import 'package:protodesk/src/sources/git_provider.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/transport/engine.dart';

import 'proto_sources_test.dart' show FixtureRepository, simple, commit1;

class SourcePicker extends FileSelectorPlatform {
  List<XFile> files = [];
  String? directory;
  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => files;
  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async => directory;
}

class PendingRepository implements RepositoryProvider {
  final completer = Completer<String>();
  @override
  Future<String> resolve(String url, String ref, SourceOperation operation) =>
      completer.future;
  @override
  Future<void> fetch(
    String url,
    String commit,
    Directory destination,
    SourceOperation operation,
  ) async {
    operation.check();
  }
}

void main() {
  late Directory dir;
  late FileSelectorPlatform original;
  late SourcePicker picker;
  final loader = ProtoLoader(
    compiler: 'assets/protoc/bin/protoc',
    standardRoot: 'assets/protoc/include',
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('source-ui-test-');
    original = FileSelectorPlatform.instance;
    picker = SourcePicker();
    FileSelectorPlatform.instance = picker;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.apitools.protodesk/storage'),
          (_) async => null,
        );
  });
  tearDown(() async {
    FileSelectorPlatform.instance = original;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.apitools.protodesk/storage'),
          null,
        );
    await dir.delete(recursive: true);
  });
  Future<void> host(
    WidgetTester tester,
    Map<String, Object?> initial,
    ValueChanged<Map<String, Object?>> changed, {
    RepositoryProvider? provider,
  }) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ProtoSourcesEditor(
                initial: initial,
                manager: SourceManager(
                  loader,
                  RepositoryCache(
                    Directory(p.join(dir.path, 'cache')),
                    provider: provider ?? FixtureRepository(),
                  ),
                ),
                onChanged: changed,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await tester.pump();
  }

  Future<void> complete(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> execute(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.runAsync(() async {
      await tester.tap(find.text(text));
      final state = tester.state(find.byType(ProtoSourcesEditor)) as dynamic;
      for (var i = 0; i < 200 && state.operation != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(state.operation, isNull, reason: 'Source operation must complete');
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'append files; add/edit/remove folder and independent root; select entries; compile without connection',
    (tester) async {
      final file = File(p.join(dir.path, 'single.proto'))
        ..writeAsStringSync(simple);
      final folder = Directory(p.join(dir.path, 'folder'))..createSync();
      File(p.join(folder.path, 'one.proto'))
          .writeAsStringSync('syntax="proto3"; package first; message One {}');
      File(p.join(folder.path, 'two.proto'))
          .writeAsStringSync('syntax="proto3"; package second; message Two {}');
      var value = SourceConfiguration.legacy([], []).data;
      await host(tester, value, (v) => value = v);
      picker.files = [XFile(file.path)];
      await tap(tester, 'Add files');
      await tester.pumpAndSettle();
      await tap(tester, 'Add files');
      await tester.pumpAndSettle();
      expect((value['sources'] as List).length, 1);
      picker.directory = folder.path;
      await tap(tester, 'Add folder');
      await tester.pumpAndSettle();
      picker.directory = dir.path;
      await tap(tester, 'Add import root');
      await tester.pumpAndSettle();
      expect(value['importRoots'], [dir.path]);
      await execute(tester, 'Discover files');
      await tap(tester, '2 discovered files');
      await tester.pumpAndSettle();
      await tap(tester, 'Select none');
      expect((value['sources'] as List)[1]['entries'], isEmpty);
      await tester.ensureVisible(find.text('one.proto'));
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect((value['sources'] as List)[1]['entries'], ['one.proto']);
      await execute(tester, 'Validate');
      expect(find.textContaining('Valid ·'), findsOneWidget);
      expect((value['validation'] as Map)['services'], 1);
      await tester.ensureVisible(find.byTooltip('Remove import root'));
      await tester.tap(find.byTooltip('Remove import root'));
      await tester.pump();
      expect(value['importRoots'], isEmpty);
      await tester.ensureVisible(find.byTooltip('Remove source').last);
      await tester.tap(find.byTooltip('Remove source').last);
      await tester.pump();
      expect((value['sources'] as List).length, 1);
    },
  );
  testWidgets(
    'Git fields are editable, validation records revision, configuration survives reopen',
    (tester) async {
      var value = SourceConfiguration.legacy([], []).data;
      await host(tester, value, (v) => value = v);
      await tap(tester, 'Add Git repository');
      await tester.pumpAndSettle();
      Future<void> enter(String label, String text) async {
        final field = find.widgetWithText(TextField, label);
        await tester.ensureVisible(field);
        await tester.enterText(field, text);
        await tester.pump();
      }

      await enter(
        'Repository URL (GitHub HTTPS)',
        'https://github.com/example/protos',
      );
      await enter('Branch / tag / commit', 'v1');
      await enter('Proto directory (repository relative)', 'proto');
      await enter(
        'Repository import roots (one per line; blank = repository root)',
        'proto',
      );
      await execute(tester, 'Validate');
      expect(
        (value['sources'] as List).single['commit'],
        commit1,
        reason:
            (tester.state(find.byType(ProtoSourcesEditor)) as dynamic).message,
      );
      expect((value['validation'] as Map)['services'], 1);
      final store = WorkspaceStore.open(p.join(dir.path, 'workspace.sqlite'));
      final record = store.save('servers', {
        'name': 'Sources',
        'address': 'example.invalid:443',
        'protoSources': value,
      });
      store.close();
      final reopened = WorkspaceStore.open(
        p.join(dir.path, 'workspace.sqlite'),
      );
      expect(
        reopened.list('servers').single['protoSources'],
        record['protoSources'],
      );
      reopened.close();
      await tester.pumpWidget(const SizedBox());
      await host(
        tester,
        Map<String, Object?>.from(record['protoSources'] as Map),
        (v) => value = v,
      );
      expect(find.text('v1'), findsOneWidget);
      expect(
        (value['sources'] as List).single['commit'],
        commit1,
        reason:
            (tester.state(find.byType(ProtoSourcesEditor)) as dynamic).message,
      );
      await tester.ensureVisible(find.byTooltip('Remove source'));
      await tester.tap(find.byTooltip('Remove source'));
      await tester.pump();
      expect((value['sources'] as List), isEmpty);
    },
  );
  testWidgets(
    'cancel and dispose while repository resolution is pending do not update unmounted widgets',
    (tester) async {
      final provider = PendingRepository();
      final config = SourceConfiguration({
        'version': 1,
        'sources': [
          {
            'type': 'git',
            'url': 'https://github.com/example/protos',
            'ref': 'main',
            'directory': '',
            'roots': [''],
          },
        ],
        'importRoots': [],
      });
      await host(tester, config.data, (_) {}, provider: provider);
      await tap(tester, 'Validate');
      await tester.pump();
      await tap(tester, 'Cancel operation');
      await tester.pumpWidget(const SizedBox());
      provider.completer.complete(commit1);
      await complete(tester);
      expect(Directory(p.join(dir.path, 'cache')).existsSync(), false);
    },
  );
  testWidgets(
    'invalid saved configuration requires explicit recovery and never mutates saved record on cancel',
    (tester) async {
      final store = WorkspaceStore.open(p.join(dir.path, 'workspace.sqlite'));
      final record = store.save('servers', {
        'name': 'Broken',
        'address': 'example.invalid:443',
      });
      store.db.execute('UPDATE servers SET proto_sources_json=? WHERE id=?', [
        '{"version":99,"sources":[]}',
        record['id'],
      ]);
      final broken = store.list('servers').single,
          desk = DeskController(store, GrpcEngine(loader));
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => editRecord(context, desk, 'servers', broken),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('require repair'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        store.db
            .select('SELECT proto_sources_json FROM servers')
            .single['proto_sources_json'],
        '{"version":99,"sources":[]}',
      );
      expect(tester.takeException(), isNull);
      desk.dispose();
    },
  );
  testWidgets(
    'populated source editor retains readable controls in smaller desktop windows',
    (tester) async {
      await tester.runAsync(() async {
        await (FontLoader('Satoshi')
              ..addFont(rootBundle.load('assets/fonts/Satoshi-Regular.ttf'))
              ..addFont(rootBundle.load('assets/fonts/Satoshi-Medium.ttf'))
              ..addFont(rootBundle.load('assets/fonts/Satoshi-Bold.ttf')))
            .load();
        await (FontLoader(
          'RobotoMono',
        )..addFont(rootBundle.load('assets/fonts/RobotoMono.ttf'))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      final store = WorkspaceStore.open(p.join(dir.path, 'layout.sqlite'));
      final desk = DeskController(store, GrpcEngine(loader));
      final source = SourceConfiguration({
        'version': 1,
        'sources': [
          {
            'type': 'file',
            'path': '/project/company/application/protocols/a-long-descriptive-schema-file.proto',
          },
          {
            'type': 'directory',
            'path': '/project/company/application/protocols/services',
          },
          {
            'type': 'git',
            'url': 'https://github.com/example/protos',
            'ref': 'feature/proto-imports',
            'directory': 'proto/services',
            'roots': ['proto', 'shared'],
            'commit': commit1,
          },
        ],
        'importRoots': ['/project/company/application/protocols'],
      });
      final boundaryKey = GlobalKey();
      for (final size in [const Size(1440, 1000), const Size(900, 700)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              theme: deskTheme,
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () => editRecord(context, desk, 'servers', {
                    'name': 'Populated sources',
                    'address': 'example.invalid:443',
                    'metadataJson': '{"x-company":"example","authorization":"test-fixture"}',
                    'protoSources': source.data,
                  }),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Add Git repository'));
        await tester.pumpAndSettle();
        expect(find.text('Add files'), findsOneWidget);
        expect(find.text('Add folder'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (Platform.environment['PROTODESK_CAPTURE_SOURCE_LAYOUT'] == '1') {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(boundaryKey),
            );
            final image = await boundary.toImage(pixelRatio: 1);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            File('/tmp/protodesk-source-layout-${size.width.toInt()}.png')
                .writeAsBytesSync(png!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      desk.dispose();
    },
  );
}
