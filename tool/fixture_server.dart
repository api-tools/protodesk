import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:protodesk/src/schema/proto_loader.dart';

import '../test/fixtures/server.dart';

Future<void> main() async {
  final schema = await ProtoLoader(
    compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
    standardRoot: 'assets/protoc/include',
  ).load(['test/fixtures/runtime.proto'], []);
  final server = Server.create(
    services: [FixtureService(schema), ReflectionFixture(schema)],
  );
  await server.serve(address: InternetAddress.loopbackIPv4, port: 50079);
  stdout.writeln('Fixture ready: 127.0.0.1:50079');
}
