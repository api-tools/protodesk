import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/main.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/presentation/dialogs.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/schema.dart';

import 'form_validation_test.dart' show CountingEngine;

void main() {
  late SchemaRegistry schema;
  setUpAll(() async {
    schema = await ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    ).load(['test/fixtures/editor_types.proto'], []);
  });
  Future<void> shortcut(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool alt = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(key);
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'app shortcuts invoke, focus search and toggle mode but never invoke behind a modal',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'desk-workflow-keys-',
      );
      final engine = CountingEngine();
      final desk = DeskController(
        WorkspaceStore.open('${directory.path}/data.sqlite'),
        engine,
      );
      desk.server = desk.store.save('servers', {
        'name': 'keys fixture',
        'address': 'localhost:1234',
      });
      desk.schema = schema;
      desk.connected = true;
      desk.method = schema.methods['/editor.fixture.Echo/Unary'];
      tester.view.physicalSize = const Size(1000, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(ProtoDeskApp(desk: desk));
      await tester.pumpAndSettle();
      expect(tester.getSemantics(find.text('SERVICES')).label, 'SERVICES');
      await shortcut(tester, LogicalKeyboardKey.keyF, alt: true);
      final search = tester.widget<TextField>(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.hintText == 'Filter services or methods',
        ),
      );
      expect(search.focusNode!.hasFocus, true);
      await shortcut(tester, LogicalKeyboardKey.keyJ, alt: true);
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Protobuf JSON',
        ),
        findsOneWidget,
      );
      await shortcut(tester, LogicalKeyboardKey.enter);
      expect(engine.calls, 1);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      await shortcut(tester, LogicalKeyboardKey.enter);
      expect(engine.calls, 1);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
      directory.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'narrow history paginates, filters and closes repeatedly without controller errors',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'desk-workflow-history-',
      );
      final desk = DeskController(
        WorkspaceStore.open('${directory.path}/data.sqlite'),
        CountingEngine(),
      );
      for (var i = 0; i < 102; i++) {
        desk.store.save('history_items', {
          'fullMethod': '/long.Service/Method$i',
          'methodName': 'Method$i',
          'serverAddress': 'localhost:1234',
          'statusCode': 'OK',
        });
      }
      tester.view.physicalSize = const Size(650, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHistory(context, desk),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Page 1 · 50 calls'), findsOneWidget);
      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(find.text('Page 2 · 50 calls'), findsOneWidget);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.labelText == 'Search server or method',
        ),
        'Method101',
      );
      await tester.pumpAndSettle();
      expect(find.text('Page 1 · 1 calls'), findsOneWidget);
      desk.store.db.execute('DELETE FROM history_items WHERE full_method=?', [
        '/long.Service/Method101',
      ]);
      await tester.tap(find.text('Method101 · OK · 0 ms'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'History item is no longer available. Refresh filters and retry.',
        ),
        findsOneWidget,
      );

      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      desk.dispose();
      directory.deleteSync(recursive: true);
    },
  );
}
