import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protodesk/src/presentation/design.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/main.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/presentation/field_editor.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/transport/engine.dart';

void main() {
  testWidgets(
    'desktop navigation, management controls, resize semantics and empty states',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('desk-widget-');
      final store = WorkspaceStore.open('${dir.path}/data.sqlite');
      final desk = DeskController(
        store,
        GrpcEngine(ProtoLoader(compiler: 'unused', standardRoot: 'unused')),
      );
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProtoDeskApp(desk: desk));
      expect(find.text('ProtoDesk'), findsOneWidget);
      expect(find.text('Browse proto sources'), findsNothing);
      expect(
        find.text('Add a server in Servers to discover its APIs.'),
        findsOneWidget,
      );
      for (final label in [
        'Servers',
        'Collections',
        'History',
        'Workspace',
        'Connect',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(
        find.bySemanticsLabel('Resize service navigation'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Resize request and response panes'),
        findsOneWidget,
      );
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('Invocation history'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      dir.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'dropdown border is clickable and preserves keyboard focus and selection',
    (tester) async {
      String? value = 'one';
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                child: StatefulBuilder(
                  builder: (context, setState) => DeskDropdown<String>(
                    value: value,
                    items: const [
                      DropdownMenuItem(value: 'one', child: Text('One')),
                      DropdownMenuItem(value: 'two', child: Text('Two')),
                    ],
                    onChanged: (selected) => setState(() => value = selected),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final dropdown = find.byType(DeskDropdown<String>);
      expect(tester.getSize(dropdown).height, DeskSpace.control);
      await tester.tapAt(tester.getTopLeft(dropdown) + const Offset(3, 3));
      await tester.pumpAndSettle();
      expect(find.text('Two'), findsOneWidget);
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(value, 'two');
      final decoration = find.descendant(
        of: dropdown,
        matching: find.byType(InputDecorator),
      );
      expect(tester.widget<InputDecorator>(decoration).isFocused, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('One'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(value, 'two');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('repeated fields keep individual values and remove items', (
    tester,
  ) async {
    final schema = SchemaRegistry();
    Object? value = <Object?>[];
    late StateSetter set;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, s) {
              set = s;
              return FieldEditor(
                field: const ProtoField(
                  name: 'values',
                  jsonName: 'values',
                  number: 1,
                  type: 5,
                  label: 3,
                ),
                schema: schema,
                value: value,
                onChanged: (v) => set(() => value = v),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add item'));
    await tester.pump();
    expect(value, [0]);
    await tester.enterText(find.byType(TextField), '42');
    await tester.pump();
    expect(value, [42]);
    await tester.tap(find.byTooltip('Remove item 1'));
    await tester.pump();
    expect(value, []);
  });
  testWidgets(
    'recursive message fields fall back to JSON and reject invalid drafts',
    (tester) async {
      final schema = SchemaRegistry()
        ..messages['Node'] = ProtoMessage('Node', [
          const ProtoField(
            name: 'child',
            jsonName: 'child',
            number: 1,
            type: 11,
            typeName: 'Node',
          ),
        ]);
      Object? value = {'child': {}};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FieldEditor(
              field: const ProtoField(
                name: 'child',
                jsonName: 'child',
                number: 1,
                type: 11,
                typeName: 'Node',
              ),
              schema: schema,
              value: value,
              ancestors: const {'Node'},
              onChanged: (v) => value = v,
            ),
          ),
        ),
      );
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '{');
      await tester.pump();
      expect(value, {'child': {}});
      await tester.enterText(find.byType(TextField), '{}');
      await tester.pump();
      expect(value, {});
    },
  );
}
