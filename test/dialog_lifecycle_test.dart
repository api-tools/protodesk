import 'dart:async';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/presentation/design.dart';
import 'package:protodesk/src/presentation/dialogs.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/sources/configuration.dart';
import 'package:protodesk/src/transport/engine.dart';

class PendingLoader extends ProtoLoader {
  final completion = Completer<SchemaRegistry>();
  PendingLoader() : super(compiler: 'unused', standardRoot: 'unused');
  @override
  Future<SchemaRegistry> load(List<String> files, List<String> folders) =>
      completion.future;
  @override
  Future<SchemaValidation> validate(
    List<String> files,
    List<String> roots, {
    required SourceOperation operation,
    List<String> discoverFolders = const [],
  }) async => SchemaValidation(await completion.future, {}, [], '');
}

class PendingPicker extends FileSelectorPlatform {
  final file = Completer<XFile?>();
  final files = Completer<List<XFile>>();
  final folder = Completer<String?>();
  final save = Completer<FileSaveLocation?>();
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) => file.future;
  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) => files.future;
  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) =>
      folder.future;
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) => save.future;
}

Finder input(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
Future<void> closeDialog(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label).last);
  await tester.tap(find.text(label).last);
  // Observe individual reverse-transition frames, rather than hiding the
  // controller lifetime gap behind one pumpAndSettle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  late Directory dir;
  late DeskController desk;
  late FileSelectorPlatform previousPicker;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('desk-dialog-lifecycle-');
    desk = DeskController(
      WorkspaceStore.open('${dir.path}/db.sqlite'),
      GrpcEngine(ProtoLoader(compiler: 'unused', standardRoot: 'unused')),
    );
    previousPicker = FileSelectorPlatform.instance;
  });
  tearDown(() {
    FileSelectorPlatform.instance = previousPicker;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.apitools.protodesk/storage'),
          null,
        );
    desk.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> host(
    WidgetTester tester,
    Future<void> Function(BuildContext) open,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => open(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('create/edit/cancel records across repeated route transitions', (
    tester,
  ) async {
    for (final table in ['servers', 'collections', 'collection_requests']) {
      Record? returned;
      final original = <String, Object?>{
        'name': 'Original',
        if (table == 'servers') ...{
          'address': 'example.invalid:443',
          'tlsEnabled': true,
          'tlsCaFile': '/chosen/ca.pem',
          'protoFiles': ['a.proto'],
          'protoFolders': ['protos'],
          'reflectionEnabled': false,
          'metadataJson': '{"x-test":"yes"}',
        },
        if (table == 'collections') 'description': 'preserved',
        if (table == 'collection_requests') ...{
          'requestJson': '{"x":1}',
          'requestStreamJson': '[{"x":1}]',
          'requestMetadataJson': '{"x-test":"yes"}',
        },
      };
      for (final save in [true, false, true, false]) {
        await host(tester, (context) async {
          returned = await editRecord(
            context,
            desk,
            table,
            save ? null : original,
          );
        });
        await tester.enterText(input('name'), 'Changed');
        if (table == 'servers') {
          await tester.enterText(input('address'), 'example.invalid:443');
        }
        final controller = tester.widget<TextField>(input('name')).controller!;
        await closeDialog(tester, save ? 'Save' : 'Cancel');
        expect(returned, save ? isNotNull : isNull);
        if (save) expect(returned!['name'], 'Changed');
        expect(() => controller.addListener(() {}), throwsFlutterError);
      }
      await host(tester, (context) async {
        returned = await editRecord(context, desk, table, original);
      });
      await tester.enterText(input('name'), 'Edited');
      await closeDialog(tester, 'Save');
      expect({...returned!}..remove('protoSources'), {
        ...original,
        'name': 'Edited',
      });
    }
  });

  testWidgets(
    'nested server manager creates, edits and cancels without premature disposal',
    (tester) async {
      await host(tester, (context) => showServers(context, desk));
      await tester.tap(find.text('New server'));
      await tester.pumpAndSettle();
      await tester.enterText(input('name'), 'Created');
      await tester.enterText(input('address'), 'example.invalid:443');
      await closeDialog(tester, 'Save');
      expect(desk.servers.single['name'], 'Created');
      final id = desk.servers.single['id'];
      await tester.tap(find.byTooltip('Edit server'));
      await tester.pumpAndSettle();
      await tester.enterText(input('name'), 'Edited');
      await closeDialog(tester, 'Save');
      expect(desk.servers.single['id'], id);
      expect(desk.servers.single['name'], 'Edited');
      await tester.tap(find.byTooltip('Edit server'));
      await tester.pumpAndSettle();
      await tester.enterText(input('name'), 'Discarded');
      await closeDialog(tester, 'Cancel');
      expect(desk.servers.single['name'], 'Edited');
      await closeDialog(tester, 'Close');
    },
  );

  testWidgets(
    'nested collection/request save and edit retain metadata and streams',
    (tester) async {
      final c = desk.store.save('collections', {'name': 'Collection'});
      final r = desk.store.save('collection_requests', {
        'collectionId': c['id'],
        'name': 'Example',
        'fullMethod': '/fixture/Upload',
        'requestJson': '{"x":1}',
        'requestStreamJson': '[{"x":1},{"x":2}]',
        'requestMetadataJson': '{"x-test":"yes"}',
      });
      desk.refresh();
      await host(tester, (context) => showCollections(context, desk));
      await tester.tap(find.byTooltip('Edit collection'));
      await tester.pumpAndSettle();
      await tester.enterText(input('name'), 'Renamed');
      await closeDialog(tester, 'Save');
      await tester.tap(find.byTooltip('Edit example'));
      await tester.pumpAndSettle();
      await tester.enterText(input('name'), 'Edited example');
      await closeDialog(tester, 'Save');
      final saved = desk.store.list('collection_requests').single;
      expect(saved['id'], r['id']);
      expect(saved['requestStreamJson'], r['requestStreamJson']);
      expect(saved['requestMetadataJson'], r['requestMetadataJson']);
      await closeDialog(tester, 'Close');
      for (final save in [true, false, true, false]) {
        final before = desk.store.list('collection_requests').length;
        await host(tester, (context) => saveExample(context, desk, r));
        await tester.enterText(input('Name'), 'Saved snapshot');
        final controller = tester.widget<TextField>(input('Name')).controller!;
        await closeDialog(tester, save ? 'Save' : 'Cancel');
        expect(
          desk.store.list('collection_requests').length,
          before + (save ? 1 : 0),
        );
        expect(() => controller.addListener(() {}), throwsFlutterError);
      }
    },
  );

  testWidgets('save-example lifecycle is safe inside the history dialog', (
    tester,
  ) async {
    final record = desk.store.save('history_items', {
      'serverAddress': 'example.invalid:443',
      'methodName': 'Upload',
      'fullMethod': '/fixture/Upload',
      'requestJson': '{"x":2}',
      'requestStreamJson': '[{"x":1},{"x":2}]',
      'requestMetadataJson': '{"x-test":"history"}',
      'statusCode': 'OK',
    });
    desk.refresh();
    await host(tester, (context) => showHistory(context, desk));
    for (final save in [true, false, true]) {
      final count = desk.store.list('collection_requests').length;
      await tester.tap(find.byTooltip('Save to collection'));
      await tester.pumpAndSettle();
      await tester.enterText(input('Name'), 'Nested snapshot');
      await closeDialog(tester, save ? 'Save' : 'Cancel');
      expect(find.text('Invocation history'), findsOneWidget);
      expect(
        desk.store.list('collection_requests').length,
        count + (save ? 1 : 0),
      );
      if (save) {
        final saved = desk.store.list('collection_requests').first;
        expect(saved['requestStreamJson'], record['requestStreamJson']);
        expect(saved['requestMetadataJson'], record['requestMetadataJson']);
      }
    }
    await closeDialog(tester, 'Close');
  });

  for (final fails in [false, true]) {
    testWidgets('validation completion after unmount is safe (error=$fails)', (
      tester,
    ) async {
      desk.dispose();
      final loader = PendingLoader();
      desk = DeskController(
        WorkspaceStore.open('${dir.path}/pending.sqlite'),
        GrpcEngine(loader),
      );
      await host(tester, (context) async {
        await editRecord(context, desk, 'servers');
      });
      await tester.ensureVisible(find.text('Validate'));
      await tester.tap(find.text('Validate'));
      await tester.pump();
      await closeDialog(tester, 'Cancel');
      if (fails) {
        loader.completion.completeError(StateError('late validation'));
      } else {
        loader.completion.complete(SchemaRegistry());
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final kind in ['ca', 'files', 'folder', 'import', 'export']) {
    testWidgets(
      'late $kind picker completion does not update an unmounted dialog',
      (tester) async {
        final picker = PendingPicker();
        FileSelectorPlatform.instance = picker;
        final workspace = kind == 'import' || kind == 'export';
        await host(tester, (context) async {
          if (workspace) {
            await showWorkspace(context, desk);
          } else {
            await editRecord(context, desk, 'servers', {
              'name': 'Fixture',
              'address': 'example.invalid:443',
              'tlsEnabled': true,
            });
          }
        });
        final action = {
          'ca': 'Choose CA certificate',
          'files': 'Add files',
          'folder': 'Add folder',
          'import': 'Import',
          'export': 'Export',
        }[kind]!;
        await tester.ensureVisible(find.text(action));
        await tester.tap(find.text(action));
        await tester.pump();
        await closeDialog(tester, workspace ? 'Close' : 'Cancel');
        switch (kind) {
          case 'ca':
          case 'import':
            picker.file.complete(XFile('/does/not/exist'));
            break;
          case 'files':
            picker.files.complete([XFile('/does/not/exist.proto')]);
            break;
          case 'folder':
            picker.folder.complete('/does/not/exist');
            break;
          case 'export':
            picker.save.complete(
              FileSaveLocation('${dir.path}/should-not-export.json'),
            );
            break;
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(File('${dir.path}/should-not-export.json').existsSync(), false);
        expect(desk.servers, isEmpty);
      },
    );
  }
  for (final kind in ['ca', 'files', 'folder']) {
    testWidgets('late $kind bookmark completion cannot update disposed state', (
      tester,
    ) async {
      final picker = PendingPicker();
      FileSelectorPlatform.instance = picker;
      final bookmark = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dev.apitools.protodesk/storage'),
            (_) => bookmark.future,
          );
      await host(tester, (context) async {
        await editRecord(context, desk, 'servers', {
          'name': 'Fixture',
          'address': 'example.invalid:443',
          'tlsEnabled': true,
        });
      });
      final action = {
        'ca': 'Choose CA certificate',
        'files': 'Add files',
        'folder': 'Add folder',
      }[kind]!;
      await tester.ensureVisible(find.text(action));
      await tester.tap(find.text(action));
      switch (kind) {
        case 'ca':
          picker.file.complete(XFile('/selected/ca.pem'));
          break;
        case 'files':
          picker.files.complete([XFile('/selected/a.proto')]);
          break;
        case 'folder':
          picker.folder.complete('/selected/protos');
          break;
      }
      await tester.pump();
      await closeDialog(tester, 'Cancel');
      bookmark.complete(null);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, skip: !Platform.isMacOS);
  }
}
