import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/presentation/design.dart';
import 'package:protodesk/src/presentation/preparation.dart';
import 'package:protodesk/src/presentation/workspace.dart';
import 'package:protodesk/src/presentation/field_editor.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/schema.dart';
import 'package:protodesk/src/transport/engine.dart';
import 'package:protodesk/src/workflow/preparation.dart';
import 'package:protodesk/src/workflow/preparation_storage.dart';

import 'fixtures/credential_vault.dart';
import 'request_preparation_test.dart' show profiles, preset;

void main() {
  late SchemaRegistry schema;
  final loader = ProtoLoader(
    compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
    standardRoot: 'assets/protoc/include',
  );
  setUpAll(() async {
    schema = await loader.load(['test/fixtures/runtime.proto'], []);
  });
  late Directory directory;
  late DeskController desk;
  late MemoryVault vault;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('desk-preparation-ui-');
    vault = MemoryVault();
    desk = DeskController(
      WorkspaceStore.open('${directory.path}/data.sqlite'),
      GrpcEngine(loader),
      credentialVault: vault,
    );
    desk.server = desk.store.save('servers', {
      'name': 'Preparation UI fixture',
      'address': 'localhost:1234',
      'requestProfilesJson': profiles(
        values: {'text': 'prepared', 'enabled': false},
        presets: [
          preset('rpc', {'x-test': r'${text}'}),
        ],
      ).encode(),
    });
    desk.schema = schema;
    desk.method = schema.methods['/runtime.fixture.Echo/Unary'];
    desk.body = r'{"text":"${text}","present":"${enabled}"}';
  });
  tearDown(() {
    desk.dispose();
    directory.deleteSync(recursive: true);
  });
  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  Future<void> host(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showRequestPreparation(context, desk),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> selectEnvironment(WidgetTester tester) async {
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is DeskDropdown<String> &&
            w.decoration.labelText == 'Environment',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Development').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(CheckboxListTile).last);
    await tester.tap(find.byType(CheckboxListTile).last);
    await tester.pumpAndSettle();
  }

  Future<void> ready(WidgetTester tester) async {
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find
          .text(
            'Preview ready. No credential was read, connection opened or RPC invoked.',
          )
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    expect(
      find.text(
        'Preview ready. No credential was read, connection opened or RPC invoked.',
      ),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .join(' | '),
    );
  }

  testWidgets(
    'typed template placeholders remain visible in Form and become typed editors after preparation',
    (tester) async {
      final current = PreparationProfiles.decode(
        desk.server!['requestProfilesJson'] as String,
      );
      final env = current.environments.single;
      final updated = PreparationProfiles({
        ...current.data,
        'environments': [
          {
            ...env,
            'variables': {
              ...(env['variables'] as Map),
              'nested': {
                'bound': true,
                'value': {'text': 'nested'},
              },
              'mode': {'bound': true, 'value': 'ACTIVE'},
              'items': {
                'bound': true,
                'value': [1, 2],
              },
            },
          },
        ],
      });
      desk.server = desk.store.save('servers', {
        ...desk.server!,
        'requestProfilesJson': updated.encode(),
      });
      desk.body = r'{"text":"${text}","present":"${enabled}","nested":"${nested}","values":"${items}","mode":"${mode}"}';
      final original = desk.body;
      tester.view.physicalSize = const Size(1000, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme,
          home: DeskWorkspace(desk: desk),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(desk.body, original);
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('request-pane')),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final key in ['mode', 'values', 'nested', 'present']) {
        final editor = find
            .byWidgetPredicate((w) => w is FieldEditor && w.field.name == key)
            .first;
        await tester.scrollUntilVisible(editor, 200, scrollable: scrollable);
        await tester.pumpAndSettle();
        final raw = tester.widget<TextField>(
          find.descendant(of: editor, matching: find.byType(TextField)).first,
        );
        expect(raw.controller!.text, contains(r'${'));
        expect(tester.takeException(), isNull);
      }

      final footer = find.byKey(const ValueKey('request-mode-bar'));
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('JSON')),
      );
      await tester.pumpAndSettle();
      expect(field('Protobuf JSON'), findsOneWidget);
      expect(desk.body, original);
      await tester.tap(find.byTooltip('Environments & metadata presets'));
      await tester.pumpAndSettle();
      await selectEnvironment(tester);
      await tester.tap(find.text('Preview preparation'));
      await ready(tester);
      await tester.tap(find.text('Apply prepared draft'));
      await tester.pumpAndSettle();
      expect(jsonDecode(desk.body), {
        'text': 'prepared',
        'present': false,
        'nested': {'text': 'nested'},
        'values': [1, 2],
        'mode': 'ACTIVE',
      });
      await tester.tap(
        find.descendant(of: footer, matching: find.byTooltip('Form')),
      );
      await tester.pumpAndSettle();
      expect(field('Raw JSON value'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'preview/apply materializes a validated draft without changing sequences, invoking or reading credentials',
    (tester) async {
      desk.queuedRequests.add({'text': r'queued ${text}'});
      desk.sentRequests = [
        {'text': 'previously sent'},
      ];
      await host(tester);
      await selectEnvironment(tester);
      await tester.tap(find.text('Preview preparation'));
      await ready(tester);
      expect(desk.body, contains(r'${text}'));
      expect(vault.reads + vault.writes, 0);
      expect(desk.invoking, false);
      await tester.tap(find.text('Apply prepared draft'));
      await tester.pumpAndSettle();
      expect(jsonDecode(desk.body), {'text': 'prepared', 'present': false});
      expect(jsonDecode(desk.metadata), {'x-test': 'prepared'});
      expect(desk.queuedRequests, [
        {'text': r'queued ${text}'},
      ]);
      expect(desk.sentRequests, [
        {'text': 'previously sent'},
      ]);
      expect(desk.store.list('history_items'), isEmpty);
      expect(desk.connected, false);
      expect(vault.reads + vault.writes, 0);
    },
  );
  testWidgets(
    'saved source prepares the original placeholders for another environment without replacing them',
    (tester) async {
      await host(tester);
      await selectEnvironment(tester);
      await tester.tap(find.text('Preview preparation'));
      await ready(tester);
      await tester.tap(find.text('Apply prepared draft'));
      await tester.pumpAndSettle();
      final templates = PreparationTemplateStore(desk.store),
          server = desk.server!;
      final original = templates.load(
        server['id'] as String,
        desk.method!.path,
      )!;
      expect(original.body, contains(r'${text}'));
      final definitions = PreparationProfiles.decode(
        server['requestProfilesJson'] as String,
      );
      final extended = PreparationProfiles({
        ...definitions.data,
        'environments': [
          ...definitions.environments,
          {
            'id': 'staging',
            'name': 'Staging',
            'variables': {
              'text': {'bound': true, 'value': 'staging'},
              'enabled': {'bound': true, 'value': false},
            },
          },
        ],
      });
      desk.server = desk.store.save('servers', {
        ...server,
        'requestProfilesJson': extended.encode(),
      });
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .first
            .value,
        false,
      );
      await tester.tap(find.byType(DeskDropdown<bool>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved reusable template').last);
      await tester.pumpAndSettle();
      final environmentField = find.byWidgetPredicate(
        (w) =>
            w is DeskDropdown<String> &&
            w.decoration.labelText == 'Environment',
      );
      await tester.ensureVisible(environmentField);
      await tester.tap(environmentField);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Staging').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile).last);
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview preparation'));
      await ready(tester);
      expect(jsonDecode(desk.body)['text'], 'prepared');
      await tester.tap(find.text('Apply prepared draft'));
      await tester.pumpAndSettle();
      expect(jsonDecode(desk.body), {'text': 'staging', 'present': false});
      expect(jsonDecode(desk.metadata), {'x-test': 'staging'});
      expect(
        templates.load(server['id'] as String, desk.method!.path)!.encode(),
        original.encode(),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DeskDropdown<bool>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved reusable template').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Load saved template into draft'));
      await tester.tap(find.text('Load saved template into draft'));
      await tester.pumpAndSettle();
      expect(desk.body, original.body);
      expect(desk.metadata, original.metadata);
      expect(desk.store.list('history_items'), isEmpty);
      expect(vault.reads, 0);
    },
  );
  testWidgets(
    'changed recipient/options invalidates a prepared result and closing a worker never updates disposed controls',
    (tester) async {
      await host(tester);
      await selectEnvironment(tester);
      await tester.tap(find.text('Preview preparation'));
      await ready(tester);
      desk.authority = 'changed.example';
      await tester.tap(find.text('Apply prepared draft'));
      await tester.pumpAndSettle();
      expect(
        find.text('Request changed. Preview again before applying.'),
        findsOneWidget,
      );
      expect(desk.body, contains(r'${text}'));
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Preview preparation'));
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await selectEnvironment(tester);
      }
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'definition add/edit/remove persists and invalid JSON survives tab switches without overwriting saved data',
    (tester) async {
      await host(tester);
      await tester.tap(find.text('Environments'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add environment'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Environment name'), 'Staging');
      await tester.enterText(
        field('Variables (JSON object)'),
        '{"empty":"","nil":null,"count":0}',
      );
      await tester.tap(find.text('Save definitions'));
      await tester.pumpAndSettle();
      var saved = PreparationProfiles.decode(
        desk.store.list('servers').single['requestProfilesJson'] as String,
      );
      expect(saved.environments.length, 2);
      expect((saved.environments.last['variables'] as Map)['nil'], {
        'bound': true,
        'value': null,
      });
      await tester.enterText(field('Variables (JSON object)'), '{invalid');
      await tester.tap(find.text('Metadata presets'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add preset'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Preset name'), 'Shared test');
      await tester.enterText(
        field('Literal RPC metadata (JSON object)'),
        '{"x-empty":""}',
      );
      await tester.tap(find.text('Save definitions'));
      await tester.pumpAndSettle();
      expect(
        PreparationProfiles.decode(
          desk.store.list('servers').single['requestProfilesJson'] as String,
        ).presets.length,
        1,
      );
      await tester.tap(find.text('Environments'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(field('Variables (JSON object)'))
            .controller!
            .text,
        '{invalid',
      );
      await tester.enterText(
        field('Variables (JSON object)'),
        '{"text":"fixed"}',
      );
      await tester.tap(find.text('Save definitions'));
      await tester.pumpAndSettle();
      saved = PreparationProfiles.decode(
        desk.store.list('servers').single['requestProfilesJson'] as String,
      );
      expect(saved.presets.length, 2);
      await tester.tap(find.byTooltip('Remove definition'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save definitions'));
      await tester.pumpAndSettle();
      expect(
        PreparationProfiles.decode(
          desk.store.list('servers').single['requestProfilesJson'] as String,
        ).environments.length,
        1,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
