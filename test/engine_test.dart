import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/codec.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/transport/engine.dart';

import 'fixtures/server.dart';

void main() {
  final loader = ProtoLoader(
    compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
    standardRoot: 'assets/protoc/include',
  );
  late SchemaRegistry schema;
  setUpAll(() async {
    schema = await loader.load(['test/fixtures/runtime.proto'], []);
  });
  test('runtime protobuf JSON semantics without generated API classes', () {
    final codec = ProtoCodec(schema);
    expect(
      codec.decode(
        'runtime.fixture.Payload',
        codec.encode('runtime.fixture.Payload', {'mode': 'RUNNING'}),
      ),
      {'mode': 'ACTIVE'},
    );
    final body = <String, Object?>{
      'text': 'hello',
      'signed': '-9223372036854775808',
      'unsigned': '18446744073709551615',
      'bytes': 'AAEC/w==',
      'mode': 'ACTIVE',
      'values': [-2147483648, 0, 2147483647],
      'children': {
        'child': {
          'nested': {'text': 'recursive'},
        },
      },
      'first': 'chosen',
      'present': false,
      'timestamp': '2026-10-12T12:34:56.123456789Z',
      'duration': '-0.123s',
      'structured': {
        'array': [
          null,
          true,
          2.5,
          {'key': 'value'},
        ],
      },
      'wrapped': '9223372036854775807',
      'number': 'Infinity',
      'fixed': '18446744073709551615',
      'negative': -42,
      'any': {
        '@type': 'type.googleapis.com/runtime.fixture.Payload',
        'text': 'inner',
      },
      'mask': 'nested.text,bytes',
      'items': [
        {'text': 'item'},
      ],
      'modes': ['UNKNOWN', 'ACTIVE', 'NEGATIVE'],
      'zigzag': '-9223372036854775808',
      'switches': {'true': 7, 'false': -1},
    };
    expect(
      codec.decode(
        'runtime.fixture.Payload',
        codec.encode('runtime.fixture.Payload', body),
      ),
      body,
    );
    expect(
      () =>
          codec.encode('runtime.fixture.Payload', {'first': 'a', 'second': 2}),
      throwsFormatException,
    );
    expect(
      () => codec.encode('runtime.fixture.Payload', {
        'unsigned': '18446744073709551616',
      }),
      throwsFormatException,
    );
    expect(
      () => codec.encode('runtime.fixture.Payload', {'missing': 1}),
      throwsFormatException,
    );
    expect(
      codec.decode(
        'runtime.fixture.Payload',
        codec.encode('runtime.fixture.Payload', {
          'text': '',
          'flag': false,
          'present': false,
        }),
      ),
      {'present': false},
    );
  });
  test('protobuf JSON accepts quoted floats and exact integral exponents', () {
    final codec = ProtoCodec(schema);
    expect(
      codec.decode(
        'runtime.fixture.Payload',
        codec.encode('runtime.fixture.Payload', {
          'number': '1.25',
          'decimal': '0.5',
          'signed': '9.007199254740993e15',
          'unsigned': '184467440737095516150e-1',
          'negative': -42.0,
        }),
      ),
      {
        'number': 1.25,
        'decimal': 0.5,
        'signed': '9007199254740993',
        'unsigned': '18446744073709551615',
        'negative': -42,
      },
    );
    for (final value in ['1.5', '1e999', '9223372036854775808.0']) {
      expect(
        () => codec.encode('runtime.fixture.Payload', {'signed': value}),
        throwsFormatException,
      );
    }
  });
  for (final reflection in ['v1', 'v1alpha', 'off']) {
    test('dynamic discovery and calls ($reflection)', () async {
      final fixture = FixtureService(schema);
      final server = Server.create(
        services: [
          fixture,
          ReflectionFixture(schema, available: reflection == 'v1'),
          ReflectionFixture(
            schema,
            version: 'v1alpha',
            available: reflection == 'v1alpha',
          ),
        ],
      );
      await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
      final engine = GrpcEngine(loader);
      try {
        final result = await engine.connect(
          ConnectionConfig(
            '127.0.0.1:${server.port}',
            files: ['test/fixtures/runtime.proto'],
          ),
        );
        expect(result.source, reflection == 'off' ? 'proto' : 'reflection');
        expect(result.schema.services, contains('runtime.fixture.Echo'));
        final method = result.schema.methods['/runtime.fixture.Echo/Unary']!;
        final response = await engine.invoke(
          method,
          {'text': 'dynamic'},
          metadata: {'x-test': 'verified'},
          authority: 'fixture.local',
        );
        expect(response.code, 'OK');
        expect(response.messages.single, {'text': 'dynamic'});
        expect(response.headers['echo-header'], 'verified');
        expect(response.trailers['echo-trailer'], 'complete');
        for (final body in <Map<String, Object?>>[
          {},
          {'text': null, 'nested': null, 'values': null, 'wrapped': null},
          {'nested': {}, 'present': false, 'wrapped': '0', 'first': ''},
        ]) {
          final emptyOrPresent = await engine.invoke(method, body);
          expect(emptyOrPresent.code, 'OK');
          expect(emptyOrPresent.messages, [
            body.containsKey('present')
                ? {'nested': {}, 'present': false, 'wrapped': '0', 'first': ''}
                : <String, Object?>{},
          ]);
        }

        expect(
          (await engine.invoke(method, {'text': 'error'})).code,
          'PERMISSION_DENIED',
        );
        expect(
          (await engine.invoke(method, {'text': 'slow'}, timeoutMs: 30)).code,
          'DEADLINE_EXCEEDED',
        );
        expect(
          (await engine.invoke(
            result.schema.methods['/runtime.fixture.Echo/Upload']!,
            {},
          )).code,
          'OK',
        );
      } finally {
        await fixture.waitForIdle();
        await engine.disconnect();
        await server.shutdown();
      }
    });
  }
  test(
    'incremental stream completion, partial failure, limit and cancellation',
    () async {
      final server = Server.create(
        services: [FixtureService(schema), ReflectionFixture(schema)],
      );
      await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
      final engine = GrpcEngine(loader);
      await engine.connect(ConnectionConfig('127.0.0.1:${server.port}'));
      final method = engine.schema.methods['/runtime.fixture.Echo/Watch']!;
      try {
        var incremental = 0;
        final result = await engine.invoke(
          method,
          {},
          onMessage: (m) {
            incremental++;
          },
        );
        expect(incremental, 3);
        expect(result.messages.length, 3);
        expect(result.code, 'OK');
        final failure = await engine.invoke(method, {'text': 'error'});
        expect(failure.code, 'INTERNAL');
        expect(failure.messages.length, 2);
        final limit = await engine.invoke(method, {'text': 'limit'});
        expect(limit.code, 'RESOURCE_EXHAUSTED');
        expect(limit.messages.length, 1000);
        final cancelled = await engine.invoke(
          method,
          {},
          onMessage: (m) {
            engine.cancel();
          },
        );
        expect(cancelled.code, 'CANCELLED');
        expect(cancelled.messages.length, 1);
      } finally {
        await engine.disconnect();
        await server.shutdown();
      }
    },
  );
  test(
    'TLS validates trusted certificate and rejects untrusted certificate',
    () async {
      final cert = await File('test/fixtures/test-only-cert.pem').readAsBytes();
      final root = await File('test/fixtures/test-only-ca.pem').readAsBytes();
      final key = await File('test/fixtures/test-only-key.pem').readAsBytes();
      final server = Server.create(
        services: [FixtureService(schema), ReflectionFixture(schema)],
      );
      await server.serve(
        address: InternetAddress.loopbackIPv4,
        port: 0,
        security: ServerTlsCredentials(certificate: cert, privateKey: key),
      );
      final engine = GrpcEngine(loader);
      try {
        await expectLater(
          engine.connect(
            ConnectionConfig('127.0.0.1:${server.port}', tls: true),
          ),
          throwsA(isA<HandshakeException>()),
        );
        final discovery = await engine.connect(
          ConnectionConfig(
            '127.0.0.1:${server.port}',
            tls: true,
            certificates: root,
          ),
        );
        final response = await engine.invoke(
          discovery.schema.methods['/runtime.fixture.Echo/Unary']!,
          {'text': 'secure'},
          authority: 'localhost',
        );
        expect(response.code, 'OK');
      } finally {
        await engine.disconnect();
        await server.shutdown();
      }
    },
  );
  test('wire bytes interoperate with independent protoc encoding', () async {
    final process = await Process.start(File(loader.compiler).absolute.path, [
      '--proto_path=test/fixtures',
      '--proto_path=assets/protoc/include',
      '--encode=runtime.fixture.Payload',
      'runtime.proto',
    ]);
    process.stdin.write(
      'signed: -9223372036854775808 unsigned: 18446744073709551615 bytes: "abc" values: -42 mode: ACTIVE fixed: 18446744073709551615 negative: -7 zigzag: -9223372036854775808',
    );
    await process.stdin.close();
    final output = await process.stdout.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    await process.stderr.drain<void>();
    expect(await process.exitCode, 0);
    expect(ProtoCodec(schema).decode('runtime.fixture.Payload', output), {
      'signed': '-9223372036854775808',
      'unsigned': '18446744073709551615',
      'bytes': 'YWJj',
      'values': [-42],
      'mode': 'ACTIVE',
      'fixed': '18446744073709551615',
      'negative': -7,
      'zigzag': '-9223372036854775808',
    });
  });
  test('proto2 required fields, groups and nested wire merge', () async {
    final registry = await loader.load(['test/fixtures/proto2.proto'], []);
    final codec = ProtoCodec(registry);
    final value = {
      'id': 0,
      'group': {'value': '-42'},
    };
    expect(
      codec.decode(
        'runtime.proto2.Required',
        codec.encode('runtime.proto2.Required', value),
      ),
      value,
    );
    expect(
      () => codec.encode('runtime.proto2.Required', {}),
      throwsFormatException,
    );
    expect(
      () => codec.decode('runtime.proto2.Required', []),
      throwsFormatException,
    );
    final dynamicCodec = ProtoCodec(schema);
    final one = dynamicCodec.encode('runtime.fixture.Payload', {
      'nested': {'text': 'first'},
    });
    final two = dynamicCodec.encode('runtime.fixture.Payload', {
      'nested': {'signed': '42'},
    });
    expect(dynamicCodec.decode('runtime.fixture.Payload', [...one, ...two]), {
      'nested': {'text': 'first', 'signed': '42'},
    });
  });
  test('proto compiler rejects traversal and symlink imports', () async {
    final dir = await Directory.systemTemp.createTemp('proto-test-');
    try {
      final target = File('${dir.path}/bad.proto');
      await target.writeAsString('syntax="proto3"; import "../escape.proto";');
      await expectLater(loader.load([target.path], []), throwsFormatException);
      await target.writeAsString('syntax="proto3"; import "escape.proto";');
      await Link('${dir.path}/escape.proto')
          .create(File('test/fixtures/runtime.proto').absolute.path);
      await expectLater(loader.load([target.path], []), throwsFormatException);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
