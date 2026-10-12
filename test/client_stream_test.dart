import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    engine = GrpcEngine(loader);
    directory = await Directory.systemTemp.createTemp(
      'protodesk-client-stream-',
    );
    desk = DeskController(
      WorkspaceStore.open('${directory.path}/data.sqlite'),
      engine,
    );
    desk.server = desk.store.save('servers', {
      'name': 'Fixture',
      'address': '127.0.0.1:${server.port}',
      'reflectionEnabled': true,
      'metadataJson': '{"x-test":"server"}',
    });
    await desk.connect();
    desk.selectMethod(desk.schema.methods['/runtime.fixture.Echo/Upload']!);
  });
  tearDown(() async {
    await engine.disconnect();
    desk.dispose();
    await server.shutdown();
    await directory.delete(recursive: true);
  });
  test('client stream stays open until half-close, snapshots messages and retains metadata', () async {
    final call = engine.startClientStream(
      desk.method!,
      metadata: {'x-test': 'client'},
    );
    final value = <String, Object?>{'text': 'first'};
    call.send(value);
    value['text'] = 'mutated';
    call.send({'text': 'second'});
    var done = false;
    call.result.then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(done, false);
    call.finishSending();
    final result = await call.result;
    expect(result.code, 'OK');
    expect(result.messages.single, {'text': 'first|second', 'signed': '2'});
    expect(result.headers['echo-header'], 'client');
    expect(result.trailers['echo-trailer'], 'upload-complete');
    expect(() => call.send({}), throwsStateError);
  });
  test('empty half-close completes a valid client stream', () async {
    final call = engine.startClientStream(desk.method!);
    call.finishSending();
    expect((await call.result).messages.single, {'text': 'upload 0'});
  });
  test(
    'server error closes a client stream without needing half-close',
    () async {
      final call = engine.startClientStream(desk.method!);
      call.send({'text': 'error'});
      expect((await call.result).code, 'PERMISSION_DENIED');
      expect(call.inputClosed, true);
    },
  );
  test(
    'cancellation, deadlines and disconnect terminate an open request stream',
    () async {
      var call = engine.startClientStream(desk.method!);
      call.send({'text': 'cancel'});
      await engine.cancel();
      expect((await call.result).code, 'CANCELLED');
      call = engine.startClientStream(desk.method!, timeoutMs: 30);
      call.send({'text': 'slow'});
      expect((await call.result).code, 'DEADLINE_EXCEEDED');
      call = engine.startClientStream(desk.method!);
      call.send({'text': 'disconnect'});
      await engine.disconnect();
      expect((await call.result).code, 'CANCELLED');
      expect(() => call.send({}), throwsStateError);
    },
  );
  test('pending sends and invalid messages are bounded without corrupting the stream', () async {
    final call = engine.startClientStream(desk.method!);
    expect(() => call.send({'unknown': true}), throwsFormatException);
    expect(call.sentCount, 0);
    for (var i = 0; i < RequestStreamLimits.queuedMessages; i++) {
      call.send({'text': '$i'});
    }
    expect(
      () => call.send({'text': 'overflow'}),
      throwsA(
        isA<GrpcError>().having(
          (e) => e.code,
          'code',
          StatusCode.resourceExhausted,
        ),
      ),
    );
    expect(call.sentCount, 64);
    call.finishSending();
    final result = await call.result;
    expect(result.code, 'OK');
    expect((result.messages.single as Map)['signed'], '64');
  });
  test(
    'pending wire bytes are bounded independently of message count',
    () async {
      const size = 17 * 1024 * 1024;
      final text = String.fromCharCodes(
        Uint8List(size)..fillRange(0, size, 120),
      );
      final call = engine.startClientStream(desk.method!);
      call.send({'text': text});
      expect(
        () => call.send({'text': text}),
        throwsA(
          isA<GrpcError>().having(
            (e) => e.code,
            'code',
            StatusCode.resourceExhausted,
          ),
        ),
      );
      expect(call.sentCount, 1);
      await engine.cancel();
      expect((await call.result).code, 'CANCELLED');
    },
  );
  test('composer queue survives examples/history and records half-close completion', () async {
    desk.setBody('{"text":"first"}');
    desk.queueDraft();
    desk.setBody('{"text":"second"}');
    desk.queueDraft();
    final collection = desk.store.save('collections', {'name': 'Streams'});
    final saved = desk.store.save('collection_requests', {
      ...desk.requestSnapshot(),
      'name': 'Upload',
      'collectionId': collection['id'],
    });
    desk.loadRequest(saved);
    expect(desk.queuedRequests, [
      {'text': 'first'},
      {'text': 'second'},
    ]);
    desk.metadata = '{"x-test":"request"}';
    final pending = desk.invoke();
    expect(desk.invoking, true);
    expect(desk.canSend, true);
    desk.setBody('{"text":"third"}');
    desk.sendDraft();
    desk.setBody('{');
    desk.sendDraft();
    expect(desk.sentRequests.length, 3);
    desk.finishSending();
    await pending;
    expect(desk.result!.code, 'OK');
    expect(desk.canSend, false);
    final history = desk.history.single;
    expect(jsonDecode(history['requestStreamJson'] as String), [
      {'text': 'first'},
      {'text': 'second'},
      {'text': 'third'},
    ]);
    expect(desk.result!.headers['echo-header'], 'request');
    desk.loadRequest(history);
    expect(desk.queuedRequests.length, 3);
    desk.store.importWorkspace(desk.store.exportWorkspace());
    expect(
      desk.store
          .list('collection_requests')
          .every(
            (r) => jsonDecode(r['requestStreamJson'] as String).length == 2,
          ),
      true,
    );
  });
  test(
    'queue rejects invalid JSON and overload while preserving the composer',
    () {
      desk.setBody('{');
      desk.queueDraft();
      expect(desk.queuedRequests, isEmpty);
      expect(desk.body, '{');
      desk.setBody('{"text":"queued"}');
      for (var i = 0; i < 64; i++) {
        desk.queueDraft();
      }
      desk.queueDraft();
      expect(desk.queuedRequests.length, 64);
      expect(desk.status, contains('64 messages'));
      desk.removeQueuedRequest(0);
      expect(desk.queuedRequests.length, 63);
    },
  );
}
