import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/main.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/transport/engine.dart';
import 'package:protodesk/src/presentation/design.dart';
import 'package:protodesk/src/presentation/workspace.dart';
import 'package:protodesk/src/presentation/field_editor.dart';

void main() {
  testWidgets(
    'connected workspace round-trips Form and JSON at desktop sizes',
    (tester) async {
      await tester.runAsync(() async {
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        final satoshi = FontLoader('Satoshi');
        for (final weight in ['Regular', 'Medium', 'Bold']) {
          satoshi.addFont(rootBundle.load('assets/fonts/Satoshi-$weight.ttf'));
        }
        await satoshi.load();
        await (FontLoader(
          'RobotoMono',
        )..addFont(rootBundle.load('assets/fonts/RobotoMono.ttf'))).load();
      });
      final dir = Directory.systemTemp.createTempSync('desk-layout-');
      final store = WorkspaceStore.open('${dir.path}/data.sqlite');
      final desk = DeskController(
        store,
        GrpcEngine(ProtoLoader(compiler: 'unused', standardRoot: 'unused')),
      );
      final schema = SchemaRegistry();
      schema.messages['example.Request'] = ProtoMessage('example.Request', [
        const ProtoField(name: 'name', jsonName: 'name', number: 1, type: 9),
        const ProtoField(name: 'count', jsonName: 'count', number: 7, type: 5),
        const ProtoField(
          name: 'enabled',
          jsonName: 'enabled',
          number: 2,
          type: 8,
        ),
        const ProtoField(
          name: 'labels',
          jsonName: 'labels',
          number: 3,
          type: 9,
          label: 3,
        ),
        const ProtoField(
          name: 'nested',
          jsonName: 'nested',
          number: 4,
          type: 11,
          typeName: 'example.Nested',
        ),
        const ProtoField(
          name: 'mode',
          jsonName: 'mode',
          number: 5,
          type: 14,
          typeName: 'example.Mode',
        ),
        const ProtoField(
          name: 'children',
          jsonName: 'children',
          number: 6,
          type: 11,
          typeName: 'example.Nested',
          label: 3,
        ),
      ]);
      schema.enumNumbers['example.Mode'] = {'MODE_UNSET': 0, 'MODE_ACTIVE': 1};
      schema.enums['example.Mode'] = {0: 'MODE_UNSET', 1: 'MODE_ACTIVE'};
      schema.messages['example.Nested'] = ProtoMessage('example.Nested', [
        const ProtoField(name: 'value', jsonName: 'value', number: 1, type: 9),
      ]);
      const method = ProtoMethod(
        'example.workspace.v1.WorkspaceAdministrationService',
        'GenerateDetailedWorkspaceCoverageReportForSelectedTenant',
        'example.Request',
        'example.Request',
      );
      schema.methods[method.path] = method;
      desk.schema = schema;
      desk.servers = [
        {
          'id': 'fixture',
          'name': 'Local fixture',
          'address': '127.0.0.1:50051',
        },
      ];
      desk.server = desk.servers.first;
      desk.connected = true;
      desk.method = method;
      desk.body = '{"name":"Populated nested request", "count":42, "enabled":true, "labels":["desktop", "compact"], "nested":{"value":"Nested text remains editable"}, "mode":"MODE_ACTIVE", "children":[{"value":"Repeated child"}]}';
      desk.metadata = '{"x-request-context":"desktop-review", "authorization":"Bearer test-only-token"}';
      desk.messages.add({
        'greeting': 'Hello, ProtoDesk',
        'details': {
          'runtimeSchema': true,
          'latencyMs': 14,
          'nested': {
            'tenant': 'Ada Lovelace',
            'tags': ['desktop', 'needle'],
          },
        },
        'longKeyWithReadableQuotedStringValue': 'A long response value wraps while retaining its complete JSON contents.',
      });
      desk.result = const CallResult(
        [],
        'OK',
        '',
        14,
        {
          'server': 'fixture',
          'x-long-response-header':
              'A readable metadata value across a narrow window',
        },
        {'status': 'complete', 'grpc-message': 'finished'},
      );
      desk.status = 'OK · 14 ms';
      tester.view.physicalSize = const Size(1360, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: ProtoDeskApp(desk: desk),
        ),
      );
      await tester.pumpAndSettle();
      final widths = [
        'services-pane',
        'request-pane',
        'response-pane',
      ].map((id) => tester.getSize(find.byKey(ValueKey(id))).width).toList();
      expect(widths[0], closeTo(widths[1], .01));
      expect(widths[1], closeTo(widths[2], .01));
      final footer = find.byKey(const ValueKey('request-mode-bar'));
      expect(tester.getBottomRight(footer).dy, lessThan(860));
      await tester.enterText(find.byType(TextField).at(1), 'Ada');
      await tester.pump();
      expect(desk.body, contains('Ada'));
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('JSON')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Protobuf JSON'), findsOneWidget);
      final jsonEditor = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Protobuf JSON',
      );
      await tester.enterText(jsonEditor, '{invalid');
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('Form')),
      );
      await tester.pump();
      expect(jsonEditor, findsOneWidget);
      expect(desk.body, '{invalid');
      await tester.enterText(
        jsonEditor,
        '{"name":"Ada","count":42,"mode":"MODE_ACTIVE","nested":{"value":"Nested text remains editable"},"children":[{"value":"Repeated child"}],"labels":["desktop","compact"]}',
      );
      await tester.pump();
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('Form')),
      );
      await tester.pumpAndSettle();
      expect(desk.body, contains('Ada'));
      expect(tester.takeException(), isNull);
      final output = Platform.environment['PROTODESK_LAYOUT_PNG'];
      Future<void> screenshot(String suffix) async {
        if (output == null) return;
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final path = suffix.isEmpty
              ? output
              : output.replaceAll('.png', '-$suffix.png');
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        });
      }

      expect(find.byIcon(Icons.waves), findsNothing);
      expect(find.byIcon(Icons.arrow_forward), findsNothing);
      final navRow = find
          .ancestor(of: find.text(method.name), matching: find.byType(SizedBox))
          .first;
      expect(tester.getSize(navRow).height, DeskSpace.row);
      Rect inputBounds(Finder input) {
        final child = find
            .descendant(
              of: input,
              matching: find.byWidgetPredicate(
                (w) => w is EditableText || w is DropdownButton<String>,
              ),
            )
            .first;
        final box = InputDecorator.containerOf(tester.element(child))!;
        return box.localToGlobal(Offset.zero) & box.size;
      }

      Rect buttonBounds(String label) {
        final button = find
            .ancestor(
              of: find.text(label).last,
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .first;
        return tester.getRect(
          find.descendant(of: button, matching: find.byType(Material)).first,
        );
      }

      void checkDimensions() {
        final filter = inputBounds(find.byType(TextField).first);
        final server = inputBounds(find.byType(DeskDropdown<String>).first);
        final jsonSearch = inputBounds(find.byType(TextField).last);
        final scalar = inputBounds(find.byType(TextField).at(1));
        final enumInput = inputBounds(find.byType(DeskDropdown<String>).last);
        for (final box in [filter, server, jsonSearch, scalar, enumInput]) {
          expect(box.height, closeTo(DeskSpace.control, .01));
        }
        for (final label in ['Invoke', 'Disconnect']) {
          expect(
            buttonBounds(label).height,
            closeTo(DeskSpace.control, .01),
            reason: label,
          );
        }
        final modes = ['Form', 'JSON']
            .map(
              (label) =>
                  find.descendant(of: footer, matching: find.byTooltip(label)),
            )
            .toList();
        for (final mode in modes) {
          expect(tester.getSize(mode), const Size.square(DeskSpace.control));
        }
        expect(tester.getSize(footer).height, DeskSpace.modeFooter);
        expect(
          tester.getBottomRight(modes.last).dx,
          closeTo(tester.getBottomRight(footer).dx - DeskSpace.gap, .01),
        );
        expect(server.top, closeTo(buttonBounds('Disconnect').top, .01));
        expect(
          server.center.dy,
          closeTo(buttonBounds('Disconnect').center.dy, .01),
        );
        for (final field in find.byType(FieldEditor).evaluate()) {
          final inputs = find.descendant(
            of: find.byWidget(field.widget),
            matching: find.byType(TextField),
          );
          for (final element in inputs.evaluate()) {
            if ((element.widget as TextField).maxLines == 1) {
              expect(
                inputBounds(find.byWidget(element.widget)).height,
                closeTo(filter.height, .01),
              );
            }
          }
        }
      }

      checkDimensions();
      await tester.tap(find.byTooltip('Expand all'));
      await tester.pump();
      await screenshot('');
      final numberInput = find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is FieldEditor && w.field.name == 'count',
        ),
        matching: find.byType(TextField),
      );
      await tester.enterText(numberInput, 'invalid integer');
      await tester.pumpAndSettle();
      expect(inputBounds(numberInput).height, closeTo(DeskSpace.control, .01));
      expect(
        tester.getSize(numberInput).height,
        greaterThan(DeskSpace.control),
      );
      expect(tester.takeException(), isNull);
      await screenshot('validation');
      await tester.enterText(numberInput, '42');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('JSON')),
      );
      await tester.pumpAndSettle();
      await screenshot('json');
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('Form')),
      );
      await tester.pumpAndSettle();
      final requestViewport = find
          .descendant(
            of: find.byType(ListView).at(1),
            matching: find.byType(Scrollable),
          )
          .first;
      final fixedFooterY = tester.getTopLeft(footer).dy;
      await tester.drag(requestViewport, const Offset(0, -370));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(footer).dy, fixedFooterY);
      await screenshot('nested-repeated');
      await tester.drag(requestViewport, const Offset(0, 600));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1000, 650);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      checkDimensions();
      await screenshot('small');
      await tester.enterText(find.byType(TextField).last, 'needle');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('json-row:/details/nested/tags/1')),
        findsOneWidget,
      );
      await screenshot('search');
      await tester.tap(find.byTooltip('Clear JSON search'));
      await tester.pump();
      await tester.tap(find.text('Headers / trailers'));
      await tester.pumpAndSettle();
      expect(find.text('Response metadata'), findsOneWidget);
      expect(find.text('Headers'), findsOneWidget);
      expect(find.text('Trailers'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot('metadata');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      final requestOptions = find.text('Metadata & call options');
      final requestScroll = find
          .descendant(
            of: find.byType(ListView).at(1),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        requestOptions,
        150,
        scrollable: requestScroll,
      );
      await tester.drag(requestScroll, const Offset(0, -100));
      await tester.pumpAndSettle();
      await tester.tap(requestOptions);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Add header'),
        100,
        scrollable: requestScroll,
      );
      await tester.pumpAndSettle();
      expect(find.text('x-request-context'), findsOneWidget);
      for (final element in find.byType(TextField).evaluate()) {
        final field = element.widget as TextField;
        if (field.maxLines == 1) {
          expect(
            inputBounds(find.byWidget(field)).height,
            closeTo(DeskSpace.control, .01),
            reason: field.decoration?.labelText ?? field.decoration?.hintText,
          );
        }
      }
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(footer).dy, greaterThan(0));
      expect(tester.getTopLeft(footer).dy, lessThan(650));
      await screenshot('request-metadata');
      final checkbox = find
          .descendant(
            of: find.byType(MetadataEditor),
            matching: find.byType(Checkbox),
          )
          .first;
      await tester.ensureVisible(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(checkbox);
      await tester.pump();
      expect(desk.metadata, isNot(contains('x-request-context')));
      desk.emit();
      await tester.pump();
      expect(find.text('x-request-context'), findsOneWidget);
      // Resizing into narrow panes must keep search/clear and call controls usable.
      await tester.drag(
        find.bySemanticsLabel('Resize request and response panes'),
        const Offset(200, 0),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'needle');
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Clear JSON search'));
      await tester.pump();
      await tester.drag(
        find.bySemanticsLabel('Resize request and response panes'),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      dir.deleteSync(recursive: true);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );
}
