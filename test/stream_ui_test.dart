import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/main.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/presentation/design.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/transport/engine.dart';

void main() {
  testWidgets(
    'client stream composer retains queue/drafts and compact controls at desktop widths',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'protodesk-stream-ui-',
      );
      final desk = DeskController(
        WorkspaceStore.open('${directory.path}/data.sqlite'),
        GrpcEngine(ProtoLoader(compiler: 'unused', standardRoot: 'unused')),
      );
      desk.schema.messages['Request'] = ProtoMessage('Request', [
        const ProtoField(name: 'text', jsonName: 'text', number: 1, type: 9),
      ]);
      const method = ProtoMethod(
        'example.StreamService',
        'Upload',
        'Request',
        'Request',
        clientStreaming: true,
      );
      desk.schema.methods[method.path] = method;
      desk.method = method;
      desk.connected = true;
      desk.body = '{"text":"first"}';
      tester.view.physicalSize = const Size(1360, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProtoDeskApp(desk: desk));
      await tester.pumpAndSettle();
      expect(find.text('Start'), findsOneWidget);
      await tester.tap(find.text('Queue message'));
      await tester.pump();
      desk.setBody('{"text":"second"}');
      await tester.pump();
      await tester.tap(find.text('Queue message'));
      await tester.pump();
      expect(desk.queuedRequests, [
        {'text': 'first'},
        {'text': 'second'},
      ]);
      final footer = find.byKey(const ValueKey('request-mode-bar'));
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('JSON')),
      );
      await tester.pumpAndSettle();
      final json = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Protobuf JSON',
      );
      await tester.enterText(json, '{');
      await tester.pump();
      await tester.tap(find.text('Queue message'));
      await tester.pump();
      expect(desk.queuedRequests.length, 2);
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('Form')),
      );
      await tester.pump();
      expect(json, findsOneWidget);
      await tester.enterText(json, '{"text":"valid draft"}');
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('Form')),
      );
      await tester.pumpAndSettle();
      expect(desk.body, contains('valid draft'));
      await tester.tap(find.byTooltip('Review send queue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1. {"text":"first"}'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove queued message 1'));
      await tester.pumpAndSettle();
      expect(desk.queuedRequests.length, 1);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1000, 650);
      desk.invoking = true;
      desk.emit();
      // Live call spinners intentionally never settle. Inspect a finite frame.
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Send message'), findsOneWidget);
      expect(find.text('Finish sending'), findsOneWidget);
      for (final label in ['Send message', 'Finish sending']) {
        final button = find
            .ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .first;
        final surface = find
            .descendant(of: button, matching: find.byType(Material))
            .first;
        expect(tester.getSize(surface).height, DeskSpace.control);
      }
      expect(tester.getSize(footer).height, DeskSpace.modeFooter);
      expect(tester.takeException(), isNull);
      desk.invoking = false;
      await tester.pumpWidget(const SizedBox());
      directory.deleteSync(recursive: true);
    },
  );
}
