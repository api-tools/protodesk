import 'dart:io';
import 'dart:convert';

import 'package:protodesk/src/schema/codec.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/main.dart';
import 'package:protodesk/src/presentation/field_editor.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/schema/schema.dart';

void main() {
  late SchemaRegistry schema;
  setUpAll(() async {
    schema =
        await ProtoLoader(
          compiler:
              Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
          standardRoot: 'assets/protoc/include',
        ).load([
          'test/fixtures/runtime.proto',
          'test/fixtures/editor_types.proto',
        ], []);
  });
  ProtoField field(String name) => schema
      .messages['runtime.fixture.Payload']!
      .fields
      .firstWhere((f) => f.name == name);
  Future<void> mount(
    WidgetTester tester,
    ProtoField f,
    Object? initial,
    void Function(Object?) observe,
  ) async {
    var value = initial;
    var present = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => FieldEditor(
                field: f,
                schema: schema,
                value: value,
                present: present,
                onChanged: (v) {
                  observe(v);
                  setState(() {
                    present = !identical(v, unsetFieldValue);
                    value = present ? v : null;
                  });
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty strings can be present and explicitly unset', (
    tester,
  ) async {
    Object? changed;
    await mount(
      tester,
      const ProtoField(
        name: 'text',
        jsonName: 'text',
        number: 1,
        type: 9,
        optional: true,
      ),
      'filled',
      (v) => changed = v,
    );
    await tester.enterText(find.byType(TextField), '');
    expect(changed, '');
    await tester.tap(find.byTooltip('Unset field'));
    expect(identical(changed, unsetFieldValue), true);
  });

  testWidgets('an untouched child can be explicitly present but empty', (
    tester,
  ) async {
    Object? changed;
    final f = schema.messages['editor.fixture.Editors']!.fields.firstWhere(
      (f) => f.name == 'child',
    );
    await mount(tester, f, null, (v) => changed = v);
    await tester.tap(find.byTooltip('Set empty message').first);
    expect(changed, <String, Object?>{});
    expect(
      ProtoCodec(schema).encode('editor.fixture.Editors', {'child': changed}),
      [10, 0],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unset').first);
    expect(identical(changed, unsetFieldValue), true);
  });

  testWidgets('NullValue has separate set-null and unset actions', (
    tester,
  ) async {
    Object? changed = 'unchanged';
    await mount(
      tester,
      const ProtoField(
        name: 'nil',
        jsonName: 'nil',
        number: 1,
        type: 14,
        typeName: 'google.protobuf.NullValue',
      ),
      null,
      (v) => changed = v,
    );
    await tester.tap(find.text('Set null'));
    expect(changed, isNull);
    await tester.tap(find.text('Unset'));
    expect(identical(changed, unsetFieldValue), true);
  });

  testWidgets('string well-known fields show editable unquoted values', (
    tester,
  ) async {
    for (final entry in {
      'timestamp': '2020-01-02T03:04:05Z',
      'duration': '1.25s',
      'mask': 'nested.text,text',
    }.entries) {
      await tester.pumpWidget(const SizedBox());
      await mount(tester, field(entry.key), entry.value, (_) {});
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        entry.value,
      );
    }
  });
  testWidgets(
    'map editor accepts JSON object keys rather than map-entry field names',
    (tester) async {
      Object? changed;
      await mount(tester, field('children'), {}, (v) => changed = v);
      await tester.enterText(
        find.byType(TextField),
        '{"north":{"text":"mapped"}}',
      );
      await tester.pumpAndSettle();
      expect(changed, {
        'north': {'text': 'mapped'},
      });
      expect(find.textContaining('Unknown field'), findsNothing);
    },
  );
  testWidgets(
    'removing a repeated row does not move its invalid draft to the next row',
    (tester) async {
      final f = const ProtoField(
        name: 'values',
        jsonName: 'values',
        number: 1,
        type: 5,
        label: 3,
      );
      await mount(tester, f, [2, 3], (_) {});
      await tester.enterText(find.byType(TextField).first, 'bad');
      await tester.pump();
      await tester.tap(find.byTooltip('Remove item 1'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '3',
      );
      expect(find.textContaining('Invalid radix'), findsNothing);
    },
  );
  testWidgets(
    'nested aliases load and normalize without duplicate fields; oneof switching clears sibling',
    (tester) async {
      Object? changed;
      final f = schema.messages['editor.fixture.Editors']!.fields.first;
      await mount(tester, f, {
        'custom_name': 'before',
        'text': 'choice',
      }, (v) => changed = v);
      final inputs = find.byType(TextField);
      expect(tester.widget<TextField>(inputs.at(2)).controller!.text, 'before');
      await tester.enterText(inputs.at(2), 'after');
      await tester.ensureVisible(inputs.at(4));
      await tester.enterText(inputs.at(4), '5');
      await tester.pump();
      expect(changed, {'customLABEL': 'after', 'number': 5});
    },
  );

  testWidgets('date picker starts at loaded date rather than today', (
    tester,
  ) async {
    await mount(tester, field('timestamp'), '2020-01-02T03:04:05Z', (_) {});
    await tester.tap(find.byTooltip('Choose date'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
          .initialDate,
      DateTime(2020, 1, 2),
    );
    await tester.tap(find.text('Cancel'));
  });
  testWidgets(
    'all well-known editor families accept edits and round-trip field wire',
    (tester) async {
      final values = <String, Object?>{
        'timestamp': '2020-01-02T03:04:05Z',
        'duration': '-1.25s',
        'mask': 'child.customLABEL,child.name',
        'double_value': 1.25,
        'float_value': 2.5,
        'int64_value': '-9223372036854775808',
        'uint64_value': '18446744073709551615',
        'int32_value': -2147483648,
        'uint32_value': 4294967295,
        'bool_value': false,
        'string_value': 'wrapped',
        'bytes_value': 'AP8q',
        'structured': {
          'nested': {
            'list': [1, true, null],
          },
        },
        'value': null,
        'list': [1, 's', false, null],
        'any': {
          '@type': 'type.googleapis.com/editor.fixture.Child',
          'name': 'resolved',
        },
        'empty': {},
      };
      final message = schema.messages['editor.fixture.Editors']!;
      for (final entry in values.entries) {
        await tester.pumpWidget(const SizedBox());
        Object? changed = 'not changed';
        final f = message.fields.firstWhere((f) => f.name == entry.key);
        await mount(tester, f, null, (v) => changed = v);
        if (f.typeName == 'google.protobuf.BoolValue') {
          await tester.tap(find.byType(Checkbox));
          await tester.pump();
        } else if (f.typeName == 'google.protobuf.Empty') {
          await tester.tap(find.byTooltip('Set empty message'));
          await tester.pump();
        } else {
          final input =
              f.typeName == 'google.protobuf.Timestamp' ||
                  f.typeName == 'google.protobuf.Duration' ||
                  f.typeName == 'google.protobuf.FieldMask' ||
                  ProtoCodec.wrappers.containsKey(f.typeName.split('.').last)
              ? entry.value.toString()
              : jsonEncode(entry.value);
          await tester.enterText(find.byType(TextField), 'invalid');
          await tester.pump();
          await tester.enterText(find.byType(TextField), input);
          await tester.pump();
        }
        expect(changed, entry.value, reason: entry.key);
        final roundTrip = ProtoCodec(schema).decode(
          message.name,
          ProtoCodec(schema).encode(message.name, {f.jsonName: changed}),
        ) as Map;
        expect(roundTrip.containsKey(f.jsonName), true, reason: entry.key);
        expect(
          find.textContaining('FormatException'),
          findsNothing,
          reason: entry.key,
        );
      }
    },
  );

  testWidgets(
    'empty string/bytes wrappers retain presence and Value null is displayed explicitly',
    (tester) async {
      final message = schema.messages['editor.fixture.Editors']!;
      for (final name in ['string_value', 'bytes_value']) {
        await tester.pumpWidget(const SizedBox());
        Object? changed;
        await mount(
          tester,
          message.fields.firstWhere((f) => f.name == name),
          'x',
          (v) => changed = v,
        );
        await tester.enterText(find.byType(TextField), '');
        expect(changed, '');
      }
      await tester.pumpWidget(const SizedBox());
      await mount(
        tester,
        message.fields.firstWhere((f) => f.name == 'value'),
        null,
        (_) {},
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'null',
      );
    },
  );

  testWidgets(
    'recursive and depth-limited nested fields use valid JSON fallback',
    (tester) async {
      final f = schema.messages['editor.fixture.Editors']!.fields.firstWhere(
        (f) => f.name == 'recursive',
      );
      Object? changed;
      await mount(tester, f, {
        'name': 'root',
        'child': {'name': 'leaf'},
      }, (v) => changed = v);
      await tester.enterText(
        find.byType(TextField).last,
        '{"name":"changed","child":{"name":"deep"}}',
      );
      await tester.pump();
      expect(changed, {
        'name': 'root',
        'child': {
          'name': 'changed',
          'child': {'name': 'deep'},
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme,
          home: Scaffold(
            body: FieldEditor(
              field: f,
              schema: schema,
              value: {'name': 'deep'},
              depth: 6,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 4);
    },
  );

  testWidgets(
    'repeated WKT defaults are valid and removing rows preserves remaining drafts',
    (tester) async {
      final message = schema.messages['editor.fixture.Editors']!;
      for (final name in ['timestamps', 'durations', 'bools', 'values']) {
        await tester.pumpWidget(const SizedBox());
        Object? changed;
        final f = message.fields.firstWhere((f) => f.name == name);
        await mount(tester, f, [], (v) => changed = v);
        await tester.tap(find.text('Add item'));
        await tester.pump();
        expect((changed as List), hasLength(1));
        ProtoCodec(schema).encode(message.name, {f.jsonName: changed});
        await tester.ensureVisible(find.byTooltip('Remove item 1'));
        await tester.tap(find.byTooltip('Remove item 1'));
        await tester.pump();
        expect(changed, isEmpty);
      }
    },
  );
  testWidgets(
    'date/time picker preserves loaded time, seconds and nanos and supports pre-1970 dates',
    (tester) async {
      Object? changed;
      const value = '1900-01-02T03:04:05.123456789Z';
      await mount(tester, field('timestamp'), value, (v) => changed = v);
      await tester.tap(find.byTooltip('Choose date'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
            .initialDate,
        DateTime(1900, 1, 2),
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TimePickerDialog>(find.byType(TimePickerDialog))
            .initialTime,
        const TimeOfDay(hour: 3, minute: 4),
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(changed, value);
    },
  );
  testWidgets('setting an empty message clears invalid nested drafts', (
    tester,
  ) async {
    final f = schema.messages['editor.fixture.Editors']!.fields.firstWhere(
      (f) => f.name == 'child',
    );
    final form = GlobalKey<FormState>();
    var value = <String, Object?>{};
    await tester.pumpWidget(
      MaterialApp(
        theme: deskTheme,
        home: Scaffold(
          body: Form(
            key: form,
            child: StatefulBuilder(
              builder: (context, setState) => FieldEditor(
                field: f,
                schema: schema,
                value: value,
                onChanged: (v) =>
                    setState(() => value = Map<String, Object?>.from(v as Map)),
              ),
            ),
          ),
        ),
      ),
    );
    final count = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is FieldEditor && w.field.name == 'count',
      ),
      matching: find.byType(TextField),
    );
    await tester.enterText(count, 'invalid');
    await tester.pump();
    expect(form.currentState!.validate(), false);
    await tester.tap(find.byTooltip('Set empty message').first);
    await tester.pumpAndSettle();
    expect(value, isEmpty);
    expect(form.currentState!.validate(), true);
    expect(tester.widget<TextField>(count).controller!.text, '');
  });
  testWidgets('empty strings and wrappers can be set directly from unset', (
    tester,
  ) async {
    final fields = [
      const ProtoField(
        name: 'optional',
        jsonName: 'optional',
        number: 1,
        type: 9,
        optional: true,
      ),
      ...schema.messages['editor.fixture.Editors']!.fields.where(
        (f) => ['string_value', 'bytes_value'].contains(f.name),
      ),
    ];
    for (final f in fields) {
      await tester.pumpWidget(const SizedBox());
      Object? changed = unsetFieldValue;
      await mount(tester, f, null, (v) => changed = v);
      await tester.tap(find.byTooltip('Set empty value'));
      await tester.pumpAndSettle();
      expect(changed, '');
      await tester.tap(find.byTooltip('Unset field'));
      await tester.pumpAndSettle();
      expect(identical(changed, unsetFieldValue), true);
    }
  });
  testWidgets(
    'NullValue presence controls wrap in a narrow repeated-item pane',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme,
          home: Scaffold(
            body: SizedBox(
              width: 150,
              child: FieldEditor(
                field: const ProtoField(
                  name: 'nil',
                  jsonName: 'nil',
                  number: 1,
                  type: 14,
                  typeName: 'google.protobuf.NullValue',
                ),
                schema: schema,
                value: null,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  test('Any preserves ordinary Empty and special wrapper/Value presence', () {
    final codec = ProtoCodec(schema);
    for (final json in [
      {'@type': 'type.googleapis.com/google.protobuf.Empty'},
      {'@type': 'type.googleapis.com/google.protobuf.StringValue', 'value': ''},
      {'@type': 'type.googleapis.com/google.protobuf.Value', 'value': null},
      {
        '@type': 'type.googleapis.com/google.protobuf.Any',
        'value': {'@type': 'type.googleapis.com/google.protobuf.Empty'},
      },
    ]) {
      expect(
        codec.decode(
          'google.protobuf.Any',
          codec.encode('google.protobuf.Any', json),
        ),
        json,
      );
    }
  });
}
