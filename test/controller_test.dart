import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/transport/engine.dart';

import 'fixtures/server.dart';

void main() {
  test('service-first workflow records/reuses calls, merges headers, and rejects invalid JSON', () async {
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    final service = Server.create(
      services: [FixtureService(schema), ReflectionFixture(schema)],
    );
    await service.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final directory = await Directory.systemTemp.createTemp('desk-controller-');
    final store = WorkspaceStore.open('${directory.path}/data.sqlite');
    final desk = DeskController(store, GrpcEngine(loader));
    desk.server = store.save('servers', {
      'name': 'Fixture',
      'address': '127.0.0.1:${service.port}',
      'reflectionEnabled': true,
      'metadataJson': '{"x-test":"server"}',
    });
    try {
      await desk.connect();
      expect(desk.connected, true);
      desk.selectMethod(desk.schema.methods['/runtime.fixture.Echo/Unary']!);
      desk.setBody(
        '{"text":"workflow","nested":{"text":"nested"},"values":[1,2]}',
      );
      desk.metadata = '{"x-test":"request"}';
      await desk.invoke();
      expect(desk.result!.code, 'OK');
      expect(desk.result!.headers['echo-header'], 'request');
      expect(desk.history.single['requestJson'], desk.body);
      final collection = store.save('collections', {'name': 'Examples'});
      store.save('collection_requests', {
        ...desk.requestSnapshot(),
        'name': 'Workflow',
        'collectionId': collection['id'],
      });
      desk.refresh();
      desk.setBody('{}');
      desk.loadRequest((desk.collections.single['requests'] as List).single);
      expect(desk.body, contains('workflow'));
      await desk.invoke();
      expect(desk.history.length, 2);
      desk.setBody('{');
      await desk.invoke();
      expect(desk.history.length, 2);
      expect(desk.status, contains('FormatException'));
      await desk.disconnect();
      expect(desk.method, isNull);
      expect(desk.result, isNull);
      expect(desk.schema.methods, isEmpty);
    } finally {
      await desk.engine.disconnect();
      desk.dispose();
      await service.shutdown();
      await directory.delete(recursive: true);
    }
  });
  test('switching methods cancels a stale stream without overwriting new selection', () async {
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    final service = Server.create(
      services: [FixtureService(schema), ReflectionFixture(schema)],
    );
    await service.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final directory = await Directory.systemTemp.createTemp('desk-cancel-');
    final desk = DeskController(
      WorkspaceStore.open('${directory.path}/data.sqlite'),
      GrpcEngine(loader),
    );
    desk.server = {
      'name': 'Fixture',
      'address': '127.0.0.1:${service.port}',
      'reflectionEnabled': true,
      'metadataJson': '{}',
    };
    try {
      await desk.connect();
      desk.selectMethod(desk.schema.methods['/runtime.fixture.Echo/Watch']!);
      final pending = desk.invoke();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      desk.selectMethod(desk.schema.methods['/runtime.fixture.Echo/Unary']!);
      await pending;
      expect(desk.method!.name, 'Unary');
      expect(desk.result, isNull);
      expect(desk.messages, isEmpty);
      expect(desk.invoking, false);
    } finally {
      await desk.engine.disconnect();
      desk.dispose();
      await service.shutdown();
      await directory.delete(recursive: true);
    }
  });
}
