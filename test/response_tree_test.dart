import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/presentation/design.dart';
import 'package:protodesk/src/presentation/response_tree.dart';

void main() {
  final document = <String, Object?>{
    'customer': {
      'profile': {'name': 'Ada "Lovelace"', 'language': 'Polish'},
    },
    'items': [
      {'id': 1, 'note': 'needle'},
      {'id': 2, 'note': 'ordinary'},
    ],
    'a/b': {'~key': true},
    'empty': <Object?>[],
    'nothing': null,
  };
  test('fully expanded rows are JSON with quoted escaped keys/values and delimiters', () {
    final model = JsonTreeModel()
      ..update(document, responseId: 1)
      ..expandAll();
    expect(jsonDecode(model.rows.map((r) => r.text).join('\n')), document);
    expect(
      model.rows.any((r) => r.text.contains('"Ada \\"Lovelace\\""')),
      isTrue,
    );
    expect(model.rows.any((r) => r.node.path == '/a~1b/~0key'), isTrue);
    model.collapseAll();
    expect(model.rows.length, 1);
    expect(model.rows.single.text, '{ … }');
  });
  test('search reveals matching values and ancestor context without unrelated siblings', () {
    final model = JsonTreeModel()
      ..update(document, responseId: 1)
      ..collapseAll();
    model.search('NEEDLE');
    final paths = model.rows.map((r) => r.node.path).toSet();
    expect(paths, containsAll(['', '/items', '/items/0', '/items/0/note']));
    expect(paths, isNot(contains('/customer')));
    expect(paths, isNot(contains('/items/1')));
    expect(model.matches, 1);
    model.search('profile');
    expect(model.rows.any((r) => r.text.contains('Lovelace')), isTrue);
    model.search('absent');
    expect(model.rows, isEmpty);
    model.search('');
    expect(model.rows.length, 1);
    expect(model.expanded, isEmpty);
  });
  test('search restores individually chosen expansion; a new response resets equal paths', () {
    final model = JsonTreeModel()..update(document, responseId: 1);
    model.toggle('/customer');
    final original = model.rows.map((r) => r.text).toList();
    model.search('Polish');
    expect(
      model.rows.any((r) => r.node.path == '/customer/profile/language'),
      isTrue,
    );
    model.toggle('/customer/profile');
    model.search('');
    expect(model.rows.map((r) => r.text).toList(), original);
    model.collapseAll();
    model.update(document, responseId: 2);
    expect(model.expanded, contains(''));
    expect(model.expanded, contains('/customer'));
  });
  test('stream updates retain expansion within the same call', () {
    final model = JsonTreeModel()
      ..update([document], responseId: 1)
      ..collapseAll();
    model.update([
      document,
      {'new': 'message'},
    ], responseId: 1);
    expect(model.rows.length, 1);
    model.expandAll();
    expect(model.rows.any((r) => r.text.contains('"new": "message"')), isTrue);
    model.update([document], responseId: 2);
    expect(model.expanded, isNot(contains('/0/customer/profile')));
  });
  testWidgets(
    'compact disclosures highlight matches and restore the previous state',
    (tester) async {
      final key = GlobalKey<ResponseTreeState>();
      String filter = '';
      late StateSetter set;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, s) {
                set = s;
                return ResponseTree(
                  key: key,
                  value: document,
                  responseId: 1,
                  filter: filter,
                );
              },
            ),
          ),
        ),
      );
      expect(find.byType(ExpansionTile), findsNothing);
      key.currentState!.collapseAll();
      await tester.pump();
      expect(find.byKey(const ValueKey('json-row:/customer')), findsNothing);
      set(() => filter = 'Lovelace');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('json-row:/customer/profile/name')),
        findsOneWidget,
      );
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('json-row:/customer/profile/name')),
          matching: find.byType(Text),
        ),
      );
      final span = text.textSpan! as TextSpan;
      expect(
        span.children!.whereType<TextSpan>().any(
          (s) => s.style?.backgroundColor != null,
        ),
        isTrue,
      );
      set(() => filter = '');
      await tester.pump();
      expect(find.byKey(const ValueKey('json-row:/customer')), findsNothing);
      await tester.tap(find.byTooltip('Expand response'));
      await tester.pump();
      expect(find.byKey(const ValueKey('json-row:/customer')), findsOneWidget);
    },
  );
}
