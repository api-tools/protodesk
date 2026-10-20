import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/presentation/design.dart';
import 'package:protodesk/src/presentation/grpcurl.dart';
import 'package:protodesk/src/request_options.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/transport/engine.dart';

import 'fixtures/credential_vault.dart';
import 'dialog_lifecycle_test.dart' show PendingPicker;

void main() {
  late Directory directory;
  late DeskController desk;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('protodesk-command-ui-');
    desk = DeskController(
      WorkspaceStore.open('${directory.path}/data.sqlite'),
      GrpcEngine(
        ProtoLoader(
          compiler:
              Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
          standardRoot: 'assets/protoc/include',
        ),
      ),
      credentialVault: MemoryVault(),
    );
  });
  tearDown(() {
    desk.dispose();
    directory.deleteSync(recursive: true);
  });
  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  Future<void> host(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showGrpcurl(context, desk),
              child: const Text('Open commands'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open commands'));
    await tester.pumpAndSettle();
  }

  Future<void> parsed(WidgetTester tester) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (field('New server profile name').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    expect(field('New server profile name'), findsOneWidget);
  }

  testWidgets(
    'narrow import reviews and persists a request without connecting, and repeated dialogs dispose controllers',
    (tester) async {
      await host(tester);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.enterText(
        field('grpcurl command'),
        "grpcurl -plaintext -max-time 1.25 -H 'x-test: request: value' -d '{\"text\":\"kept\"}' localhost:50051 example.Service/Call",
      );
      await tester.tap(find.text('Parse and review'));
      await parsed(tester);
      expect(desk.store.list('servers'), isEmpty);
      await tester.tap(find.text('Import server and saved request'));
      await tester.pumpAndSettle();
      expect(find.text('grpcurl interchange'), findsNothing);
      expect(desk.store.list('servers').length, 1);
      expect(desk.store.list('collections').length, 1);
      final saved = desk.store.list('collection_requests').single;
      expect(saved['requestJson'], '{"text":"kept"}');
      expect(
        RequestOptions.decode(saved['requestOptionsJson'] as String)!.timeoutMs,
        1250,
      );
      expect(desk.body, '{"text":"kept"}');
      expect(desk.connected, false);
      expect(desk.invoking, false);
      expect(desk.store.list('history_items'), isEmpty);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Open commands'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();
        final controller = tester
            .widget<TextField>(field('grpcurl command'))
            .controller!;
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(() => controller.addListener(() {}), throwsFlutterError);
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'closing during isolated parsing never changes records or rebuilds disposed fields',
    (tester) async {
      await host(tester);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.enterText(
        field('grpcurl command'),
        "grpcurl -plaintext -d '{}' localhost:50051 example.Service/Call",
      );
      await tester.tap(find.text('Parse and review'));
      await tester.pump();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(desk.store.list('servers'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'safe export is secondary, copy contains placeholders and defaults exclude request/header values',
    (tester) async {
      final schema = (await tester.runAsync(
        () => desk.engine.loader.load(['test/fixtures/runtime.proto'], []),
      ))!;
      desk.server = desk.store.save('servers', {
        'name': 'Fixture',
        'address': 'localhost:50051',
        'reflectionEnabled': true,
        'metadataJson': '{"authorization":"synthetic-literal"}',
      });
      desk.schema = schema;
      desk.selectMethod(schema.methods['/runtime.fixture.Echo/Unary']!);
      desk.setBody('{"text":"synthetic-payload"}');
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await host(tester);
      await tester.tap(find.text('Generate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy redacted preview'));
      await tester.pumpAndSettle();
      expect(clipboard, contains('__PROTODESK_REDACTED_BODY__'));
      expect(clipboard, isNot(contains('synthetic-literal')));
      expect(clipboard, isNot(contains('synthetic-payload')));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'late working-directory picker completion never bookmarks or updates an unmounted dialog',
    (tester) async {
      final previous = FileSelectorPlatform.instance;
      final picker = PendingPicker();
      FileSelectorPlatform.instance = picker;
      addTearDown(() => FileSelectorPlatform.instance = previous);
      var bookmarks = 0;
      const storage = MethodChannel('dev.apitools.protodesk/storage');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, (
        call,
      ) async {
        bookmarks++;
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          storage,
          null,
        ),
      );
      await host(tester);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.enterText(
        field('grpcurl command'),
        "grpcurl -plaintext -proto api.proto -import-path . -d '{}' localhost:50051 example.Service/Call",
      );
      await tester.tap(find.text('Parse and review'));
      await parsed(tester);
      await tester.ensureVisible(find.text('Choose command working directory'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose command working directory'));
      await tester.pump();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      picker.folder.complete(directory.path);
      await tester.pumpAndSettle();
      expect(bookmarks, 0);
      expect(desk.store.list('servers'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
