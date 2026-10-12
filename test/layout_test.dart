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

void main() {
  testWidgets(
    'connected workspace round-trips Form and JSON at desktop sizes',
    (tester) async {
      await tester.runAsync(() async {
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        for (final family in ['Satoshi', 'monospace']) {
          final loader = FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/Satoshi-Regular.ttf'));
          await loader.load();
        }
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
        'example.Greeter',
        'SayHello',
        'example.Request',
        'example.Request',
      );
      schema.methods[method.path] = method;
      desk.schema = schema;
      desk.connected = true;
      desk.method = method;
      desk.messages.add({
        'greeting': 'Hello, ProtoDesk',
        'details': {'runtimeSchema': true, 'latencyMs': 14},
      });
      desk.result = const CallResult(
        [],
        'OK',
        '',
        14,
        {'server': 'fixture'},
        {'status': 'complete'},
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
      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(output).writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      tester.view.physicalSize = const Size(1000, 700);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      dir.deleteSync(recursive: true);
    },
  );
}
