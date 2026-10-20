import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/transport/engine.dart';
import 'package:protodesk/src/workflow/storage.dart';

void main() {
  late Directory directory;
  late WorkspaceStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('desk-workflow-');
    store = WorkspaceStore.open('${directory.path}/data.sqlite');
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });
  test('fresh auxiliary storage is empty; draft versions round-trip without replacing unknown fields', () {
    expect(store.db.select('SELECT * FROM request_drafts'), isEmpty);
    final drafts = DraftStore(store);
    final draft = RequestDraft(
      body: '{invalid draft',
      metadata: '{}',
      references: '',
      authority: 'example.local',
      timeoutMs: 1234,
      signature: 'schema',
      queue: [
        {'text': ''},
      ],
      lastSent: [
        null,
        {'nested': {}},
      ],
    );
    drafts.save('server', '/test.Service/Call', draft);
    expect(
      drafts.load('server', '/test.Service/Call')!.toJson(),
      draft.toJson(),
    );
    expect(drafts.load('other', '/test.Service/Call'), isNull);
    const future = '{"version":999,"future":"preserve"}';
    store.db.execute('UPDATE request_drafts SET state_json=?', [future]);
    expect(
      () => drafts.save('server', '/test.Service/Call', draft),
      throwsFormatException,
    );
    expect(drafts.raw('server', '/test.Service/Call'), future);
  });
  test(
    'SQL pagination is deterministic, bounded and parameterized with filters',
    () {
      for (var i = 0; i < 125; i++) {
        final saved = store.save('history_items', {
          'serverId': i.isEven ? 'a' : 'b',
          'serverName': i == 20 ? 'literal % _ quote\'' : 'fixture',
          'serverAddress': 'localhost:1234',
          'fullMethod': i.isEven ? '/test.Service/Even' : '/test.Service/Odd',
          'statusCode': i % 3 == 0 ? 'OK' : 'INTERNAL',
          'createdAt': '2026-10-20T12:00:00.000Z',
        });
        store.db.execute('UPDATE history_items SET id=? WHERE id=?', [
          i.toString().padLeft(3, '0'),
          saved['id'],
        ]);
      }
      final a = queryHistory(store),
          b = queryHistory(store, offset: 50),
          c = queryHistory(store, offset: 100);
      expect(a.rows.length, 50);
      expect((a.rows.first as HistoryRecord).payloadLoaded, false);
      expect(a.rows.first['requestJson'], '{}');
      expect((a.rows.first as HistoryRecord).payloadLoaded, true);
      expect(b.rows.length, 50);
      expect(c.rows.length, 25);
      expect(a.hasNext, true);
      expect(c.hasNext, false);
      expect(
        {
          ...a.rows.map((r) => r['id']),
          ...b.rows.map((r) => r['id']),
          ...c.rows.map((r) => r['id']),
        }.length,
        125,
      );
      expect(a.rows.first['id'], '124');
      expect(
        queryHistory(
          store,
          filter: const HistoryFilter(text: 'literal % _ quote\''),
        ).rows.length,
        1,
      );
      expect(
        queryHistory(
          store,
          filter: const HistoryFilter(text: "' OR 1=1 --"),
        ).rows,
        isEmpty,
      );
      final filtered = queryHistory(
        store,
        filter: HistoryFilter(
          serverId: 'b',
          status: 'OK',
          text: 'odd',
          from: DateTime.utc(2026, 10, 20),
          until: DateTime.utc(2026, 10, 21),
        ),
      );
      expect(filtered.rows, isNotEmpty);
      for (final row in filtered.rows) {
        expect(row['serverId'], 'b');
        expect(row['statusCode'], 'OK');
        expect(row['fullMethod'], endsWith('/Odd'));
      }
      expect(
        queryHistory(
          store,
          filter: HistoryFilter(from: DateTime.utc(2026, 10, 21)),
        ).rows,
        isEmpty,
      );
      expect(() => queryHistory(store, limit: 100000), throwsArgumentError);
    },
  );
  test('schema changes retain incompatible JSON and unsupported drafts survive editing', () async {
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    final desk = DeskController(store, GrpcEngine(loader));
    final server = store.save('servers', {
      'name': 'schema fixture',
      'address': 'localhost:1234',
    });
    desk.server = server;
    desk.schema = schema;
    final method = schema.methods['/runtime.fixture.Echo/Unary']!;
    DraftStore(store).save(
      server['id'] as String,
      method.path,
      RequestDraft(
        body: '{"removedField":"keep"}',
        metadata: '{}',
        references: '',
        authority: '',
        timeoutMs: 5000,
        signature: 'old-schema',
        queue: [],
        lastSent: [],
      ),
    );
    desk.selectMethod(method);
    expect(desk.warning, contains('Schema changed'));
    expect(desk.body, '{"removedField":"keep"}');
    expect(desk.validateBody(desk.body), isNotNull);
    desk.persistDraft();
    const future = '{"version":42,"privateFutureField":"preserve"}';
    store.db.execute('UPDATE request_drafts SET state_json=?', [future]);
    desk.method = null;
    desk.selectMethod(method);
    expect(desk.warning, contains('unsupported'));
    desk.setBody('{"text":"new editing"}');
    desk.persistDraft();
    expect(DraftStore(store).raw(server['id'] as String, method.path), future);
    desk.method = null;
    desk.dispose();
    store = WorkspaceStore.open('${directory.path}/data.sqlite');
    expect(DraftStore(store).raw(server['id'] as String, method.path), future);
  });
  test('last sent load validates before replacing a draft or stream queue and never invokes', () async {
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    final desk = DeskController(store, GrpcEngine(loader));
    desk.server = store.save('servers', {
      'name': 'last sent fixture',
      'address': 'localhost:1234',
    });
    desk.schema = schema;
    desk.selectMethod(schema.methods['/runtime.fixture.Echo/Chat']!);
    desk.body = '{"text":"keep draft"}';
    desk.sentRequests = [
      {'text': 'first'},
      {'text': 'last'},
    ];
    desk.loadLastSent();
    expect(jsonDecode(desk.body), {'text': 'last'});
    expect(desk.queuedRequests, [
      {'text': 'first'},
      {'text': 'last'},
    ]);
    expect(desk.invoking, false);
    final before = desk.body, queue = List.of(desk.queuedRequests);
    desk.sentRequests = [
      {'removedField': 'incompatible'},
    ];
    desk.loadLastSent();
    expect(desk.body, before);
    expect(desk.queuedRequests, queue);
    expect(desk.status, contains('incompatible'));
    expect(store.list('history_items'), isEmpty);
    desk.method = null;
    desk.dispose();
    store = WorkspaceStore.open('${directory.path}/data.sqlite');
  });
  test('method switching and restart preserve invalid drafts, queues and sent snapshots independently', () async {
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final schema = await loader.load(['test/fixtures/runtime.proto'], []);
    final desk = DeskController(store, GrpcEngine(loader));
    final server = store.save('servers', {
      'name': 'draft fixture',
      'address': 'localhost:1234',
    });
    desk.server = server;
    desk.schema = schema;
    final unary = schema.methods['/runtime.fixture.Echo/Unary']!,
        chat = schema.methods['/runtime.fixture.Echo/Chat']!;
    desk.selectMethod(chat);
    desk.setBody('{"text":"queued"}');
    desk.queueDraft();
    desk.sentRequests = [
      {'text': 'already sent'},
    ];
    desk.setBody('{invalid unsent');
    desk.metadata = '{"x-test":"literal"}';
    desk.timeoutMs = 1234;
    desk.authority = 'draft.local';
    desk.selectMethod(unary);
    desk.setBody('{"text":"different method"}');
    desk.selectMethod(chat);
    expect(desk.body, '{invalid unsent');
    expect(desk.queuedRequests, [
      {'text': 'queued'},
    ]);
    expect(desk.sentRequests, [
      {'text': 'already sent'},
    ]);
    expect(desk.timeoutMs, 1234);
    expect(desk.authority, 'draft.local');
    desk.persistDraft();
    final raw = DraftStore(store).raw(server['id'] as String, chat.path)!;
    expect(jsonDecode(raw)['body'], '{invalid unsent');
    // Explicitly flush before closing the controller-owned store and reopening.
    desk.method = null;
    desk.dispose();
    store = WorkspaceStore.open('${directory.path}/data.sqlite');
    expect(
      DraftStore(store).load(server['id'] as String, chat.path)!.body,
      '{invalid unsent',
    );
  });
}
