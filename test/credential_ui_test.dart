import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/presentation/controller.dart';
import 'package:protodesk/src/presentation/credentials.dart';
import 'package:protodesk/src/presentation/design.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/security/credentials.dart';
import 'package:protodesk/src/transport/engine.dart';

import 'fixtures/credential_vault.dart';

void main() {
  late Directory directory;
  late DeskController desk;
  late MemoryVault vault;
  final scope = CredentialScope.metadata('example.com:443', tls: true);
  setUp(() {
    directory = Directory.systemTemp.createTempSync('protodesk-credential-ui-');
    vault = MemoryVault();
    desk = DeskController(
      WorkspaceStore.open('${directory.path}/data.sqlite'),
      GrpcEngine(ProtoLoader(compiler: 'unused', standardRoot: 'unused')),
      credentialVault: vault,
    );
  });
  tearDown(() {
    desk.dispose();
    directory.deleteSync(recursive: true);
  });
  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  testWidgets(
    'explicit literal migration is verified before changing form data, with narrow layout and repeated dialogs',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var refs = MetadataReferences({});
      var literals = {'x-auth': 'synthetic-literal'};
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 280,
                child: StatefulBuilder(
                  builder: (context, setState) => MetadataCredentialEditor(
                    desk: desk,
                    scope: () => scope,
                    references: refs,
                    title: 'Protected headers',
                    onChanged: (v) => setState(() => refs = v),
                    literals: () => literals,
                    onLiteralsChanged: (v) => setState(() => literals = v),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(field('Header to protect / migrate'), 'x-auth');
      await tester.tap(find.text('Store securely'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field('Secret value')).obscureText, true);
      expect(
        tester.widget<TextField>(field('Secret value')).controller!.text,
        'synthetic-literal',
      );
      await tester.enterText(field('Label'), 'Header');
      vault.locked = true;
      await tester.tap(find.text('Store'));
      await tester.pumpAndSettle();
      expect(refs.headers, isEmpty);
      expect(literals['x-auth'], 'synthetic-literal');
      expect(find.textContaining('locked or unavailable'), findsOneWidget);
      vault.locked = false;
      await tester.tap(find.text('Store'));
      await tester.pumpAndSettle();
      expect(literals, isEmpty);
      final id = refs.headers['x-auth'];
      expect(id, isNotNull);
      expect(await desk.credentials.resolve(id, scope), 'synthetic-literal');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Remove protected header'));
      await tester.pumpAndSettle();
      expect(refs.headers, isEmpty);
      for (var i = 0; i < 3; i++) {
        await tester.enterText(field('Header to protect / migrate'), 'x-other');
        await tester.tap(find.text('Store securely'));
        await tester.pumpAndSettle();
        final controller = tester
            .widget<TextField>(field('Secret value'))
            .controller!;
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(() => controller.addListener(() {}), throwsFlutterError);
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'late protected write after dialog unmount never calls setState or pops another route',
    (tester) async {
      vault.pending = Completer<void>();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: deskTheme,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => createCredential(context, desk, scope),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Label'), 'Pending');
      await tester.enterText(field('Secret value'), 'synthetic-secret');
      await tester.tap(find.text('Store'));
      await tester.pump();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      vault.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
