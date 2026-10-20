import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:protodesk/src/presentation/diagnostics.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/presentation/design.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:grpc/grpc.dart';
import 'package:protodesk/src/schema/codec.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/schema/wire.dart';
import 'package:protodesk/src/transport/engine.dart';
import 'package:protodesk/src/transport/diagnostics.dart';

import 'fixtures/server.dart';

void main() {
  final loader = ProtoLoader(
    compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
    standardRoot: 'assets/protoc/include',
  );
  late GrpcEngine engine;
  late Server server;
  setUp(() async {
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    server = Server.create(
      services: [FixtureService(schema), ReflectionFixture(schema)],
    );
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    engine = GrpcEngine(loader);
    await engine.connect(ConnectionConfig('127.0.0.1:${server.port}'));
  });
  tearDown(() async {
    await engine.disconnect();
    await server.shutdown();
  });
  testWidgets(
    'compact diagnostics retains reachable actions and resets detail inclusion for a new call',
    (tester) async {
      // Unit host deliberately uses an empty isolated store; no native credentials.
      final directory = Directory.systemTemp.createTempSync('desk-diag-ui-');
      final desk = DeskController(
        WorkspaceStore.open('${directory.path}/data.sqlite'),
        engine,
      );
      addTearDown(() {
        desk.dispose();
        directory.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(1000, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      desk.diagnostics = CallDiagnostics()
        ..event('sent', 10)
        ..complete('OK');
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCallDiagnostics(context, desk),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final include = find.byType(CheckboxListTile);
      await tester.ensureVisible(include);
      await tester.tap(include);
      await tester.pumpAndSettle();
      expect(find.text('Copy including details'), findsOneWidget);
      desk.diagnostics = CallDiagnostics();
      desk.emit();
      await tester.pump();
      expect(find.text('Copy payload-free diagnostics'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  test('all four modes report protobuf sizes, first response, order and explicit half-close', () async {
    for (final name in ['Unary', 'Watch', 'Upload', 'Chat']) {
      final method = engine.schema.methods['/runtime.fixture.Echo/$name']!;
      final body = {'text': 'payload-secret'};
      late CallResult result;
      if (method.clientStreaming) {
        final stream = engine.startRequestStream(method);
        stream.send(body);
        stream.finishSending();
        result = await stream.result;
      } else {
        result = await engine.invoke(
          method,
          body,
          metadata: {'authorization': 'header-secret'},
        );
      }
      final trace = result.diagnostics!;
      expect(trace.code, 'OK');
      expect(trace.sentMessages, 1);
      expect(trace.receivedMessages, result.messages.length);
      expect(
        trace.sentBytes,
        ProtoCodec(engine.schema).encode(method.input, body).length,
      );
      expect(
        trace.receivedBytes,
        result.messages.fold<int>(
          0,
          (n, m) =>
              n + ProtoCodec(engine.schema).encode(method.output, m).length,
        ),
      );
      expect(trace.firstResponseUs, isNotNull);
      expect(trace.events.first.kind, 'started');
      expect(trace.events.last.kind, 'completed');
      expect(
        trace.events.where((e) => e.kind == 'half_close_requested').length,
        1,
      );
      expect(
        trace.events.map((e) => e.elapsedUs).toList(),
        orderedEquals(trace.events.map((e) => e.elapsedUs).toList()..sort()),
      );
      expect(jsonEncode(trace.toJson()), isNot(contains('secret')));
    }
  });
  test('partial errors, cancellation, deadlines and invalid encoding keep truthful observations', () async {
    final watch = engine.schema.methods['/runtime.fixture.Echo/Watch']!;
    final partial = await engine.invoke(watch, {'text': 'error'});
    expect(partial.diagnostics!.receivedMessages, 2);
    expect(partial.diagnostics!.code, 'INTERNAL');
    final cancelled = await engine.invoke(
      watch,
      {},
      onMessage: (_) => engine.cancel(),
    );
    expect(cancelled.diagnostics!.receivedMessages, 1);
    expect(
      cancelled.diagnostics!.events.any((e) => e.kind == 'cancel_requested'),
      true,
    );
    expect(cancelled.diagnostics!.code, 'CANCELLED');
    final deadline = await engine.invoke(watch, {}, timeoutMs: 70);
    expect(deadline.diagnostics!.code, 'DEADLINE_EXCEEDED');
    expect(deadline.diagnostics!.receivedMessages, greaterThanOrEqualTo(1));
    final invalid = await engine.invoke(watch, {'unknown': true});
    expect(invalid.diagnostics!.code, 'INVALID_ARGUMENT');
    expect(invalid.diagnostics!.sentMessages, 0);
    expect(invalid.diagnostics!.firstResponseUs, isNull);
  });
  test('request-stream errors and cancellation never invent user half-close events', () async {
    for (final name in ['Upload', 'Chat']) {
      final method = engine.schema.methods['/runtime.fixture.Echo/$name']!;
      final stream = engine.startRequestStream(method);
      stream.send({'text': 'error'});
      final failed = await stream.result;
      expect(
        failed.diagnostics!.code,
        name == 'Upload' ? 'PERMISSION_DENIED' : 'INTERNAL',
      );
      expect(
        failed.diagnostics!.events.any((e) => e.kind == 'half_close_requested'),
        false,
      );
      final live = engine.startRequestStream(method);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await engine.cancel();
      final cancelled = await live.result;
      expect(cancelled.diagnostics!.code, 'CANCELLED');
      expect(
        cancelled.diagnostics!.events
            .where((e) => e.kind == 'cancel_requested')
            .length,
        1,
      );
      expect(
        cancelled.diagnostics!.events.any(
          (e) => e.kind == 'half_close_requested',
        ),
        false,
      );
    }
  });
  test(
    'bounded event retention keeps complete counters and terminal event',
    () {
      final trace = CallDiagnostics();
      for (var i = 0; i < 5000; i++) {
        trace.event('received', 7);
      }
      trace.complete('OK');
      trace.event('received', 100);
      expect(trace.events.length, CallDiagnostics.eventLimit);
      expect(trace.events.last.kind, 'completed');
      expect(trace.droppedEvents, greaterThan(0));
      expect(trace.receivedMessages, 5000);
      expect(trace.receivedBytes, 35000);
    },
  );
  test('structured status decodes only known descriptors and retains every raw Any', () {
    final schema = engine.schema;
    schema.messages['google.rpc.Status'] = ProtoMessage(
      'google.rpc.Status',
      [],
    );
    final payload = ProtoCodec(schema)
        .encode('runtime.fixture.Payload', {'text': 'known'});
    final known = WireWriter()
      ..text(1, 'type.googleapis.com/runtime.fixture.Payload')
      ..data(2, payload);
    final unknown = WireWriter()
      ..text(1, 'type.googleapis.com/unknown.Type')
      ..data(2, [8, 1]);
    final status = WireWriter()
      ..integer(1, 7)
      ..text(2, 'denied')
      ..data(3, known.finish())
      ..data(3, unknown.finish());
    final raw = base64.encode(status.finish());
    final result = structuredStatus({'grpc-status-details-bin': raw}, schema);
    expect(result['rawBase64'], raw);
    final details = result['details'] as List;
    expect(details[0]['decoded'], {'text': 'known'});
    expect(details[1]['rawBase64'], 'CAE=');
    final missing = structuredStatus({
      'grpc-status-details-bin': raw,
    }, SchemaRegistry());
    expect(missing['rawBase64'], raw);
    expect(missing.containsKey('details'), false);
    expect(
      structuredStatus({'grpc-status-details-bin': '!'}, schema)['state'],
      contains('Malformed'),
    );
  });
}
