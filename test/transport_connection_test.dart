import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/transport/engine.dart';

import 'fixtures/server.dart';

void main() {
  test(
    'peer closure during HTTP/2 setup fails without waiting for timeout',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((socket) {
        socket.listen((_) => socket.destroy());
      });
      final engine = GrpcEngine(
        ProtoLoader(compiler: 'unused', standardRoot: 'unused'),
      );
      try {
        await expectLater(
          engine
              .connect(
                ConnectionConfig('127.0.0.1:${server.port}', reflection: false),
              )
              .timeout(const Duration(seconds: 2)),
          throwsA(
            isA<GrpcError>().having(
              (e) => e.message,
              'message',
              contains('before sending HTTP/2 settings'),
            ),
          ),
        );
      } finally {
        await engine.disconnect();
        await subscription.cancel();
        await server.close();
      }
    },
  );

  test(
    'disconnect cancels an HTTP/2 handshake without waiting for timeout',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final preface = Completer<void>();
      final subscription = server.listen((socket) {
        sockets.add(socket);
        socket.listen((_) {
          if (!preface.isCompleted) preface.complete();
        });
      });
      final engine = GrpcEngine(
        ProtoLoader(compiler: 'unused', standardRoot: 'unused'),
      );
      try {
        final connecting = engine.connect(
          ConnectionConfig('127.0.0.1:${server.port}', reflection: false),
        );
        final cancelled = expectLater(
          connecting,
          throwsA(
            isA<GrpcError>().having(
              (e) => e.code,
              'code',
              StatusCode.cancelled,
            ),
          ),
        );
        await preface.future.timeout(const Duration(seconds: 2));
        await engine.disconnect();
        await cancelled.timeout(const Duration(seconds: 2));
      } finally {
        await engine.disconnect();
        await subscription.cancel();
        await server.close();
        for (final socket in sockets) {
          socket.destroy();
        }
      }
    },
  );

  test(
    'slow HTTP/2 readiness reuses one connection for reflection and RPC',
    () async {
      final loader = ProtoLoader(
        compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
        standardRoot: 'assets/protoc/include',
      );
      final schema = await loader.load(['test/fixtures/runtime.proto'], []);
      final server = Server.create(
        services: [FixtureService(schema), ReflectionFixture(schema)],
      );
      await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      var connections = 0;
      final tasks = <Future<void>>[];
      Future<void> forward(Socket client) async {
        connections++;
        sockets.add(client);
        final upstream = await Socket.connect('127.0.0.1', server.port!);
        sockets.add(upstream);
        // Forward the client preface immediately, but delay the server's first
        // SETTINGS beyond the former five-second disposable-probe deadline.
        final outgoing = upstream.addStream(client).catchError((Object _) {});
        await Future<void>.delayed(const Duration(seconds: 6));
        final incoming = client.addStream(upstream).catchError((Object _) {});
        await Future.wait([outgoing, incoming]);
      }

      final subscription = proxy.listen((client) {
        tasks.add(forward(client));
      });
      final engine = GrpcEngine(loader);
      try {
        final result = await engine.connect(
          ConnectionConfig('127.0.0.1:${proxy.port}'),
        );
        expect(result.source, 'reflection', reason: result.warning);
        final call = await engine.invoke(
          schema.methods['/runtime.fixture.Echo/Unary']!,
          {'text': 'same connection'},
        );
        expect(call.code, 'OK', reason: call.error);
        expect(connections, 1);
      } finally {
        await engine.disconnect();
        await subscription.cancel();
        await proxy.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await Future.wait(tasks);
        await server.shutdown();
      }
    },
  );
}
