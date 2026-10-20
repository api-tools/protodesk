import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/main.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/transport/engine.dart';

DeskController openDesk(String path) => DeskController(
  WorkspaceStore.open(path),
  GrpcEngine(ProtoLoader(compiler: 'unused', standardRoot: 'unused')),
);

void expectEmpty(DeskController desk) {
  for (final table in WorkspaceStore.columns.keys) {
    expect(desk.store.list(table), isEmpty, reason: table);
  }
  expect(desk.store.db.select('SELECT * FROM request_drafts'), isEmpty);
  expect(desk.server, isNull);
  expect(desk.connected, isFalse);
  expect(desk.connecting, isFalse);
  expect(desk.invoking, isFalse);
  expect(desk.schema.methods, isEmpty);
}

void main() {
  test('fresh database and empty restart never seed data or connect', () async {
    final dir = Directory.systemTemp.createTempSync('desk-fresh-');
    final path = '${dir.path}/workspace.sqlite';
    var desk = openDesk(path);
    try {
      expectEmpty(desk);
      await desk.connect();
      expect(desk.status, 'Create a server profile first');
      expectEmpty(desk);
      desk.dispose();
      desk = openDesk(path);
      expectEmpty(desk);
      final added = desk.store.save('servers', {
        'name': 'User endpoint',
        'address': 'example.invalid:443',
      });
      desk.store.delete('servers', added['id'] as String);
      desk.dispose();
      desk = openDesk(path);
      expectEmpty(desk);
    } finally {
      desk.dispose();
      dir.deleteSync(recursive: true);
    }
  });

  test(
    'normal startup preserves all existing records including legacy Localhost',
    () {
      final dir = Directory.systemTemp.createTempSync('desk-upgrade-');
      final path = '${dir.path}/workspace.sqlite';
      File('test/fixtures/workspace.sqlite').copySync(path);
      final before = WorkspaceStore.open(path);
      final legacy = before.list('servers').single;
      before.save('servers', {...legacy, 'name': 'Localhost'});
      final saved = {
        for (final table in WorkspaceStore.columns.keys)
          table: before.list(table),
      };
      before.close();
      final desk = openDesk(path);
      try {
        for (final table in saved.keys) {
          expect(desk.store.list(table), saved[table], reason: table);
        }
        expect(desk.servers, hasLength(1));
        expect(desk.connected, isFalse);
      } finally {
        desk.dispose();
        dir.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('fresh workspace has empty states and blank new-server address', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('desk-empty-ui-');
    final desk = openDesk('${dir.path}/workspace.sqlite');
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProtoDeskApp(desk: desk));
    expect(
      find.text('Add a server in Servers to discover its APIs.'),
      findsOneWidget,
    );
    expect(find.textContaining('localhost:50051'), findsNothing);
    await tester.tap(find.text('Servers'));
    await tester.pumpAndSettle();
    expect(
      find.text('No saved servers. Choose New server to add your endpoint.'),
      findsOneWidget,
    );
    await tester.tap(find.text('New server'));
    await tester.pumpAndSettle();
    final address = tester
        .widgetList<TextField>(find.byType(TextField))
        .firstWhere((field) => field.decoration?.labelText == 'address');
    expect(address.controller!.text, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Collections'));
    await tester.pumpAndSettle();
    expect(
      find.text('Create a collection to keep reusable request examples.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(
      find.text('Completed calls appear here. History stays on this computer.'),
      findsOneWidget,
    );
    expectEmpty(desk);
    await tester.pumpWidget(const SizedBox());
    dir.deleteSync(recursive: true);
  });
}
