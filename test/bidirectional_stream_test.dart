import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/transport/engine.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/persistence/store.dart';

import 'fixtures/server.dart';

void main() {
  late Server server;
  late GrpcEngine engine;
  late Directory directory;
  late DeskController desk;
  final loader = ProtoLoader(
    compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
    standardRoot: 'assets/protoc/include',
  );
  setUp(() async {
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    server = Server.create(
      services: [FixtureService(schema), ReflectionFixture(schema)],
    );
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    directory = await Directory.systemTemp.createTemp('protodesk-bidi-');
    engine = GrpcEngine(loader);
    desk = DeskController(
      WorkspaceStore.open('${directory.path}/data.sqlite'),
      engine,
    );
    desk.server = desk.store.save('servers', {
      'name': 'Bidi fixture',
      'address': '127.0.0.1:${server.port}',
      'reflectionEnabled': true,
      'metadataJson': '{"x-test":"server"}',
    });
    await desk.connect();
    desk.selectMethod(desk.schema.methods['/runtime.fixture.Echo/Chat']!);
  });
  tearDown(() async {
    await engine.disconnect();
    desk.dispose();
    await server.shutdown();
    await directory.delete(recursive: true);
  });
  Future<void> until(bool Function() condition) async {
    final limit = DateTime.now().add(const Duration(seconds: 3));
    while (!condition()) {
      if (DateTime.now().isAfter(limit)) {
        fail('Timed out waiting for live message');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('bidirectional receives before any request and between sends without half-close', () async {
    final ready = Completer<void>(), echoed = Completer<void>();
    final seen = <Object?>[];
    final call = engine.startRequestStream(
      desk.method!,
      metadata: {'x-test': 'bidi'},
      onMessage: (message) {
        seen.add(message);
        if ((message as Map)['text'] == 'ready') ready.complete();
        if (message['text'] == 'first') echoed.complete();
      },
    );
    var complete = false;
    call.result.then((_) => complete = true);
    await ready.future.timeout(const Duration(seconds: 3));
    expect(call.inputClosed, false);
    expect(call.sentCount, 0);
    call.send({
      'text': 'first',
      'nested': {'text': 'nested'},
      'mode': 'ACTIVE',
    });
    await echoed.future.timeout(const Duration(seconds: 3));
    expect(complete, false);
    expect(call.inputClosed, false);
    call.send({'text': 'second'});
    call.finishSending();
    final result = await call.result;
    expect(result.code, 'OK');
    expect(result.messages.length, 4);
    expect(result.messages.last, {'text': 'finished', 'signed': '2'});
    expect((result.messages[1] as Map)['nested'], {'text': 'nested'});
    expect(result.headers['echo-header'], 'bidi');
    expect(result.trailers['echo-trailer'], 'chat-complete');
    expect(seen, result.messages);
    expect(() => call.send({}), throwsStateError);
  });

  test('bidirectional error preserves responses already received and closes sending', () async {
    final seen = <Object?>[];
    final call = engine.startRequestStream(desk.method!, onMessage: seen.add);
    await until(() => seen.length == 1);
    call.send({'text': 'kept'});
    await until(() => seen.length == 2);
    call.send({'text': 'error'});
    final result = await call.result;
    expect(result.code, 'INTERNAL');
    expect(result.messages, [
      {'text': 'ready'},
      {'text': 'kept'},
    ]);
    expect(call.inputClosed, true);
  });

  test(
    'cancel, deadline and disconnect preserve partial bidirectional responses',
    () async {
      for (final reason in ['cancel', 'deadline', 'disconnect']) {
        if (reason == 'disconnect' && !desk.connected) await desk.connect();
        final seen = <Object?>[];
        final call = engine.startRequestStream(
          desk.method!,
          timeoutMs: reason == 'deadline' ? 500 : 5000,
          onMessage: seen.add,
        );
        await until(() => seen.isNotEmpty);
        if (reason == 'cancel') await engine.cancel();
        if (reason == 'disconnect') await engine.disconnect();
        final result = await call.result;
        expect(
          result.code,
          reason == 'deadline' ? 'DEADLINE_EXCEEDED' : 'CANCELLED',
        );
        expect(result.messages.first, {'text': 'ready'});
        expect(call.inputClosed, true);
      }
    },
  );

  test('controller receives live metadata/messages and persists the full sent sequence', () async {
    desk.metadata = '{"x-test":"live"}';
    final pending = desk.invoke();
    await until(() => desk.messages.isNotEmpty);
    expect(desk.canSend, true);
    expect(desk.result!.headers['echo-header'], 'live');
    expect(desk.result!.code, 'IN_PROGRESS');
    desk.setBody('{"text":"one"}');
    desk.sendDraft();
    await until(() => desk.messages.length == 2);
    expect(desk.invoking, true);
    expect(desk.sendingFinished, false);
    desk.setBody('{"text":"two"}');
    desk.sendDraft();
    desk.finishSending();
    await pending;
    expect(desk.result!.code, 'OK');
    expect(desk.messages.length, 4);
    expect(jsonDecode(desk.history.single['requestStreamJson'] as String), [
      {'text': 'one'},
      {'text': 'two'},
    ]);
    expect(
      jsonDecode(desk.history.single['responseJson'] as String),
      desk.messages,
    );
    desk.loadRequest(desk.history.single);
    expect(desk.queuedRequests, [
      {'text': 'one'},
      {'text': 'two'},
    ]);
  });

  test('switching methods cancels a live bidirectional call without stale responses or headers', () async {
    final pending = desk.invoke();
    await until(() => desk.messages.isNotEmpty);
    desk.selectMethod(desk.schema.methods['/runtime.fixture.Echo/Unary']!);
    await pending;
    expect(desk.method!.name, 'Unary');
    expect(desk.messages, isEmpty);
    expect(desk.result, isNull);
    expect(desk.invoking, false);
  });

  test(
    'bidirectional can half-close empty send side and still receive completion',
    () async {
      final call = engine.startRequestStream(desk.method!);
      call.finishSending();
      final result = await call.result;
      expect(result.code, 'OK');
      expect(result.messages, [
        {'text': 'ready'},
        {'text': 'finished'},
      ]);
    },
  );
}
