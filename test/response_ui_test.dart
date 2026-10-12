import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/main.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/transport/engine.dart';

void main() {
  testWidgets(
    'copy includes hidden JSON, metadata copy/empty states and status live in footer',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('desk-response-ui-');
      final desk = DeskController(
        WorkspaceStore.open('${dir.path}/data.sqlite'),
        GrpcEngine(ProtoLoader(compiler: 'unused', standardRoot: 'unused')),
      );
      final data = {
        'hidden': {'secret': 'disposable fixture'},
        'visible': 'needle',
      };
      desk.messages.add(data);
      desk.status = 'INTERNAL · 42 ms · Partial response';
      desk.result = const CallResult(
        [],
        'INTERNAL',
        'Partial response',
        42,
        {'x-response': 'fixture'},
        {'grpc-status': '13'},
      );
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
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
      tester.view.physicalSize = const Size(1000, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProtoDeskApp(desk: desk));
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNothing);
      expect(
        find.text('INTERNAL · 42 ms · 1 message · Partial response'),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('call-status'))).dy,
        greaterThan(600),
      );
      desk.status = 'Invalid request JSON';
      desk.emit();
      await tester.pump();
      expect(
        find.textContaining('Invalid request JSON · Last call:'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField).last, 'needle');
      await tester.pump();
      await tester.tap(find.byTooltip('Copy response JSON'));
      expect(jsonDecode(copied!), data);
      await tester.tap(find.text('Headers / trailers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy all'));
      expect(jsonDecode(copied!), {
        'headers': {'x-response': 'fixture'},
        'trailers': {'grpc-status': '13'},
      });
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      desk.result = null;
      desk.emit();
      await tester.pump();
      await tester.tap(find.byTooltip('Response headers and trailers'));
      await tester.pumpAndSettle();
      expect(find.text('No headers received.'), findsOneWidget);
      expect(find.text('No trailers received.'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      desk.method = const ProtoMethod(
        'example.Service',
        'Watch',
        'example.Request',
        'example.Response',
        serverStreaming: true,
      );
      desk.schema.messages['example.Request'] = ProtoMessage(
        'example.Request',
        [],
      );
      desk.schema.methods[desk.method!.path] = desk.method!;
      desk.invoking = true;
      desk.callClock.start();
      desk.emit();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('Live stream ·'), findsOneWidget);
      expect(find.textContaining('1 message'), findsOneWidget);
      desk.invoking = false;
      desk.method = null;
      desk.messages
        ..clear()
        ..add(null);
      expect(desk.responseJson, 'null');
      await tester.pumpWidget(const SizedBox());
      dir.deleteSync(recursive: true);
    },
  );
}
