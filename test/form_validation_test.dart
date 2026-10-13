import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/main.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/presentation/field_editor.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/transport/engine.dart';

class CountingEngine extends GrpcEngine {
  int calls = 0;
  CountingEngine()
    : super(ProtoLoader(compiler: 'unused', standardRoot: 'unused'));
  @override
  Future<CallResult> invoke(
    ProtoMethod method,
    Object? body, {
    Map<String, String> metadata = const {},
    int timeoutMs = 5000,
    String authority = '',
    void Function(Object?)? onMessage,
    void Function(Map<String, String>)? onHeaders,
  }) async {
    calls++;
    onMessage?.call(body);
    return CallResult([body], 'OK', '', 0, {}, {});
  }
}

void main() {
  late SchemaRegistry schema;
  setUpAll(() async {
    schema = await ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    ).load(['test/fixtures/editor_types.proto'], []);
  });
  testWidgets(
    'invalid nested draft blocks Invoke and JSON mode; repair restores sending',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync(
        'protodesk-form-validation-',
      );
      final engine = CountingEngine();
      final desk = DeskController(
        WorkspaceStore.open('${dir.path}/db.sqlite'),
        engine,
      );
      desk.server = desk.store.save('servers', {
        'name': 'Fixture',
        'address': 'example.invalid:443',
      });
      desk.schema = schema;
      desk.connected = true;
      desk.method = schema.methods['/editor.fixture.Echo/Unary'];
      desk.setBody('{"child":{"name":"accepted","count":2}}');
      tester.view.physicalSize = const Size(1360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProtoDeskApp(desk: desk));
      await tester.pumpAndSettle();
      final count = find.descendant(
        of: find
            .byWidgetPredicate(
              (w) => w is FieldEditor && w.field.name == 'count',
            )
            .first,
        matching: find.byType(TextField),
      );
      await tester.ensureVisible(count);
      await tester.enterText(count, 'bad');
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('request-pane')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Invoke'));
      await tester.pumpAndSettle();
      expect(engine.calls, 0);
      expect(desk.status, contains('Fix invalid form'));
      final footer = find.byKey(const ValueKey('request-mode-bar'));
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('JSON')),
      );
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Protobuf JSON',
        ),
        findsNothing,
      );
      await tester.drag(
        find.byKey(const ValueKey('request-pane')),
        const Offset(0, 600),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(count).controller!.text, 'bad');
      await tester.ensureVisible(count);
      await tester.enterText(count, '3');
      await tester.pump();
      await tester.tap(find.text('Invoke'));
      await tester.pumpAndSettle();
      expect(engine.calls, 1);
      expect((desk.messages.single as Map)['child'], {
        'name': 'accepted',
        'count': 3,
      });
      await tester.pumpWidget(const SizedBox());
      dir.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'Value null has explicit presence in the real request form and JSON switch',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('protodesk-value-form-');
      final desk = DeskController(
        WorkspaceStore.open('${dir.path}/db.sqlite'),
        CountingEngine(),
      );
      desk.server = desk.store.save('servers', {
        'name': 'Fixture',
        'address': 'example.invalid:443',
      });
      desk.schema = schema;
      desk.connected = true;
      desk.method = schema.methods['/editor.fixture.Echo/Unary'];
      tester.view.physicalSize = const Size(1360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProtoDeskApp(desk: desk));
      await tester.pumpAndSettle();
      final editor = find.byWidgetPredicate(
        (w) => w is FieldEditor && w.field.name == 'value',
      );
      final input = find.descendant(
        of: editor,
        matching: find.byType(TextField),
      );
      await tester.scrollUntilVisible(
        editor,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('request-pane')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(input);
      await tester.enterText(input, 'null');
      await tester.pump();
      final body = jsonDecode(desk.body) as Map;
      expect(body.containsKey('value'), true);
      expect(body['value'], null);
      final footer = find.byKey(const ValueKey('request-mode-bar'));
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('JSON')),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('request-pane')),
        const Offset(0, 5000),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Protobuf JSON',
        ),
        findsOneWidget,
      );
      expect(jsonDecode(desk.body), {'value': null});
      await tester.pumpWidget(const SizedBox());
      dir.deleteSync(recursive: true);
    },
  );
}
