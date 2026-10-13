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
                onChanged: (v) {
                  observe(v);
                  setState(() => value = v);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

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
}
