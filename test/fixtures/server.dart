import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:protodesk/src/schema/wire.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/schema/codec.dart';

class FixtureService extends Service {
  final ProtoCodec codec;
  Future<void>? pendingUnary;
  Future<void> waitForIdle() async => await pendingUnary;
  FixtureService(SchemaRegistry registry) : codec = ProtoCodec(registry) {
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'Unary',
        unary,
        false,
        false,
        (v) => v,
        (v) => v,
      ),
    );
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'Watch',
        watch,
        false,
        true,
        (v) => v,
        (v) => v,
      ),
    );
  }
  @override
  String get $name => 'runtime.fixture.Echo';
  Future<List<int>> unary(ServiceCall call, Future<List<int>> request) async {
    final bytes = await request;
    final body = codec.decode('runtime.fixture.Payload', bytes) as Map;
    if (body['text'] == 'error') {
      throw const GrpcError.permissionDenied('Fixture refused request');
    }
    if (body['text'] == 'slow') {
      pendingUnary = Future<void>.delayed(const Duration(milliseconds: 250));
      await pendingUnary;
      if (call.isCanceled) return bytes;
    }
    call.headers!.addAll({
      'echo-header': call.clientMetadata?['x-test'] ?? 'none',
    });
    call.trailers!.addAll({'echo-trailer': 'complete'});
    return bytes;
  }

  Stream<List<int>> watch(ServiceCall call, Future<List<int>> request) async* {
    final body = codec.decode('runtime.fixture.Payload', await request) as Map;
    final count = body['text'] == 'limit' ? 1001 : 3;
    call.headers!.addAll({'echo-header': 'stream'});
    for (var i = 0; i < count; i++) {
      if (count == 3) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      if (call.isCanceled) return;
      yield codec.encode('runtime.fixture.Payload', {
        'text': 'message $i',
        'signed': '$i',
      });
      if (body['text'] == 'error' && i == 1) {
        throw const GrpcError.internal('Stream failed');
      }
    }
    call.trailers!.addAll({'echo-trailer': 'complete'});
  }
}

class ReflectionFixture extends Service {
  final SchemaRegistry schema;
  final String version;
  final bool available;
  ReflectionFixture(this.schema, {this.version = 'v1', this.available = true}) {
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'ServerReflectionInfo',
        reflect,
        true,
        true,
        (v) => v,
        (v) => v,
      ),
    );
  }
  @override
  String get $name => 'grpc.reflection.$version.ServerReflection';
  Stream<List<int>> reflect(
    ServiceCall call,
    Stream<List<int>> requests,
  ) async* {
    await for (final bytes in requests) {
      // Drain the request before refusing reflection. grpc's missing-route path
      // leaves its request subscription paused (dart-lang/http issue #2021).
      if (!available) {
        throw const GrpcError.unimplemented('Reflection unavailable');
      }
      final request = WireReader(bytes).fields();
      final response = WireWriter();
      if (request.containsKey(7)) {
        final entry = WireWriter()..text(1, 'runtime.fixture.Echo');
        final list = WireWriter()..data(1, entry.finish());
        response.data(6, list.finish());
      } else {
        final descriptors = WireWriter();
        for (final file in schema.files.values) {
          descriptors.data(1, file);
        }
        response.data(4, descriptors.finish());
      }
      yield response.finish();
    }
  }
}
