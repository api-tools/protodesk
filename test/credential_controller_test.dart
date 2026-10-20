import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/security/credentials.dart';
import 'package:protodesk/src/transport/engine.dart';

import 'fixtures/credential_vault.dart';
import 'fixtures/server.dart';

class PendingVault extends MemoryVault {
  Completer<String?>? pendingRead;
  @override
  Future<String?> read(String id) => pendingRead?.future ?? super.read(id);
}

class ProtectedFixture extends FixtureService {
  ProtectedFixture(super.schema);
  @override
  Stream<List<int>> watch(ServiceCall call, Future<List<int>> request) async* {
    if (call.clientMetadata?['x-test'] != 'synthetic-private-header') {
      throw const GrpcError.unauthenticated('Missing protected header');
    }
    yield* super.watch(call, request);
  }
}

class ObservedEngine extends GrpcEngine {
  String? lastAuthority;
  int? lastTimeout;
  ObservedEngine(super.loader);
  @override
  Future<CallResult> invoke(
    ProtoMethod method,
    Object? body, {
    Map<String, String> metadata = const {},
    int timeoutMs = 5000,
    String authority = '',
    void Function(Object?)? onMessage,
    void Function(Map<String, String>)? onHeaders,
  }) {
    lastAuthority = authority;
    lastTimeout = timeoutMs;
    return super.invoke(
      method,
      body,
      metadata: metadata,
      timeoutMs: timeoutMs,
      authority: authority,
      onMessage: onMessage,
      onHeaders: onHeaders,
    );
  }
}

void main() {
  test('protected RPC headers are sent but only references enter history and replay; literal overrides remain explicit', () async {
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    final service = Server.create(
      services: [ProtectedFixture(schema), ReflectionFixture(schema)],
    );
    await service.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final directory = Directory.systemTemp.createTempSync(
      'protodesk-credential-rpc-',
    );
    final store = WorkspaceStore.open('${directory.path}/data.sqlite');
    final vault = PendingVault();
    final engine = ObservedEngine(loader);
    final desk = DeskController(store, engine, credentialVault: vault);
    try {
      final server = store.save('servers', {
        'name': 'Fixture',
        'address': '127.0.0.1:${service.port}',
        'reflectionEnabled': true,
        'reflectionMetadataJson': '{}',
      });
      final scope = DeskController.credentialScope(server);
      final id = await desk.credentials.create(
        'RPC header',
        CredentialValue(scope, 'synthetic-private-header'),
      );
      desk.server = store.save('servers', {
        ...server,
        'metadataReferencesJson': MetadataReferences({'x-test': id}).encode(),
      });
      await desk.connect();
      expect(desk.connected, true);
      desk.selectMethod(desk.schema.methods['/runtime.fixture.Echo/Unary']!);
      await desk.invoke();
      expect(desk.result!.headers['echo-header'], 'synthetic-private-header');
      final record = desk.history.single;
      expect(record['requestMetadataJson'], '{}');
      expect(record['requestCredentialReferencesJson'], contains(id));
      // Response metadata is deliberately not persisted by the history model.
      expect(
        jsonEncode(store.list('history_items')),
        isNot(contains('synthetic-private-header')),
      );
      desk.loadRequest(record);
      await desk.invoke();
      expect(desk.result!.headers['echo-header'], 'synthetic-private-header');
      desk.requestCredentials = MetadataReferences({});
      desk.metadata = '{"x-test":"request-override"}';
      vault.locked = true;
      await desk.invoke();
      expect(desk.result!.code, 'OK');
      expect(desk.result!.headers['echo-header'], 'request-override');
      desk.metadata = '{}';
      vault.locked = false;
      for (final name in ['Watch', 'Upload', 'Chat']) {
        desk.selectMethod(desk.schema.methods['/runtime.fixture.Echo/$name']!);
        desk.setBody('{"text":"protected streaming"}');
        final call = desk.invoke();
        if (desk.method!.clientStreaming) {
          for (var i = 0; i < 100 && !desk.canSend; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(desk.canSend, true);
          desk.sendDraft();
          desk.finishSending();
        }
        await call;
        expect(desk.result!.code, 'OK', reason: name);
        if (name != 'Watch') {
          expect(
            desk.result!.headers['echo-header'],
            'synthetic-private-header',
          );
        }
        expect(
          jsonEncode(store.list('history_items')),
          isNot(contains('synthetic-private-header')),
        );
      }
      desk.selectMethod(desk.schema.methods['/runtime.fixture.Echo/Unary']!);
      vault.pendingRead = Completer<String?>();
      final delayedCall = desk.invoke();
      await Future<void>.delayed(Duration.zero);
      desk.authority = 'different-virtual-host.example';
      desk.timeoutMs = 1;
      vault.pendingRead!.complete(vault.values[id]);
      await delayedCall;
      expect(desk.result!.code, 'OK');
      expect(engine.lastAuthority, '');
      expect(engine.lastTimeout, 5000);
      desk.authority = '';
      desk.timeoutMs = 5000;
      vault.pendingRead = Completer<String?>();
      final pendingCall = desk.invoke();
      await Future<void>.delayed(Duration.zero);
      await desk.cancel();
      vault.pendingRead!.complete(vault.values[id]);
      await pendingCall;
      expect(desk.invoking, false);
      expect(desk.history.length, 7);
      expect(desk.status, contains('Cancelled before credentials resolved'));
    } finally {
      desk.dispose();
      await service.shutdown();
      directory.deleteSync(recursive: true);
    }
  });
}
