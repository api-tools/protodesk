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
      ]);
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
      desk.connected = true;
      desk.method = method;
      desk.body = '{"name":"Populated nested request", "enabled":true, "labels":["desktop", "compact"], "nested":{"value":"Nested text remains editable"}}';
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
      await tester.enterText(find.byType(TextField).at(1), 'Ada');
      await tester.pump();
      expect(desk.body, contains('Ada'));
      await tester.tap(find.text('JSON').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Protobuf JSON'), findsOneWidget);
      await tester.tap(find.text('Form').first);
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
      expect(
        tester.getSize(find.byType(TextField).at(1)).height,
        closeTo(DeskSpace.control, 2),
      );
      await tester.tap(find.byTooltip('Expand all'));
      await tester.pump();
      await screenshot('');
      tester.view.physicalSize = const Size(1000, 650);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
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
      await tester.tap(requestOptions);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Add header'),
        100,
        scrollable: requestScroll,
      );
      await tester.pumpAndSettle();
      expect(find.text('x-request-context'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await screenshot('request-metadata');
      final checkbox = find
          .descendant(
            of: find.byType(MetadataEditor),
            matching: find.byType(Checkbox),
          )
          .first;
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
  );
}
