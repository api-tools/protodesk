import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/schema/codec.dart';
import 'package:protodesk/src/schema/schema.dart';

void main() {
  final schema = SchemaRegistry();
  const text = ProtoField(
    name: 'text',
    jsonName: 'text',
    number: 1,
    type: 9,
    optional: true,
  );
  const child = ProtoField(
    name: 'child',
    jsonName: 'child',
    number: 2,
    type: 11,
    typeName: 'Child',
  );
  const values = ProtoField(
    name: 'values',
    jsonName: 'values',
    number: 3,
    type: 11,
    typeName: 'google.protobuf.Value',
    label: 3,
  );
  const numbers = ProtoField(
    name: 'numbers',
    jsonName: 'numbers',
    number: 4,
    type: 5,
    label: 3,
  );
  const mapping = ProtoField(
    name: 'mapping',
    jsonName: 'mapping',
    number: 5,
    type: 11,
    typeName: 'Entry',
    label: 3,
  );
  schema.messages['Request'] = ProtoMessage('Request', [
    text,
    child,
    values,
    numbers,
    mapping,
  ]);
  schema.messages['Child'] = ProtoMessage('Child', []);
  schema.messages['Entry'] = ProtoMessage('Entry', [
    const ProtoField(name: 'key', jsonName: 'key', number: 1, type: 9),
    const ProtoField(name: 'value', jsonName: 'value', number: 2, type: 5),
  ], mapEntry: true);
  schema.messages['google.protobuf.Value'] = ProtoMessage(
    'google.protobuf.Value',
    [
      const ProtoField(
        name: 'null_value',
        jsonName: 'nullValue',
        number: 1,
        type: 14,
        typeName: 'google.protobuf.NullValue',
        oneof: 0,
      ),
    ],
  );
  schema.enums['google.protobuf.NullValue'] = {0: 'NULL_VALUE'};
  final codec = ProtoCodec(schema);

  test(
    'omitted and null fields encode identically, including repeated Value',
    () {
      expect(codec.encode('Request', {}), isEmpty);
      expect(
        codec.encode('Request', {
          'text': null,
          'child': null,
          'values': null,
          'numbers': null,
          'mapping': null,
        }),
        isEmpty,
      );
      for (final field in schema.messages['Request']!.fields) {
        expect(() => codec.validateField(field, null), returnsNormally);
      }
    },
  );
  test(
    'explicit empty optional string and empty message retain wire presence',
    () {
      // Independent protobuf wire expectations: field tags followed by zero length.
      expect(codec.encode('Request', {'text': ''}), [10, 0]);
      expect(codec.encode('Request', {'child': {}}), [18, 0]);
      expect(codec.decode('Request', [10, 0, 18, 0]), {
        'text': '',
        'child': {},
      });
    },
  );
  test(
    'null collection elements are rejected except protobuf null sentinels',
    () {
      expect(
        () => codec.encode('Request', {
          'numbers': [null],
        }),
        throwsFormatException,
      );
      expect(() => codec.validateField(numbers, [null]), throwsFormatException);
      expect(
        () => codec.encode('Request', {
          'mapping': {'a': null},
        }),
        throwsFormatException,
      );
      expect(
        () => codec.validateField(mapping, {'a': null}),
        throwsFormatException,
      );
      expect(
        codec.encode('Request', {
          'values': [null],
        }),
        [26, 2, 8, 0],
      );
      expect(codec.decode('Request', [26, 2, 8, 0]), {
        'values': [null],
      });
      expect(() => codec.validateField(values, [null]), returnsNormally);
    },
  );
  test('null does not satisfy proto2 required fields', () {
    const required = ProtoField(
      name: 'required',
      jsonName: 'required',
      number: 1,
      type: 9,
      label: 2,
    );
    schema.messages['Required'] = ProtoMessage('Required', [
      required,
    ], syntax: 'proto2');
    expect(
      () => codec.encode('Required', {'required': null}),
      throwsFormatException,
    );
    expect(() => codec.validateField(required, null), throwsFormatException);
  });
  test('required Value accepts its explicit null sentinel', () {
    const required = ProtoField(
      name: 'value',
      jsonName: 'value',
      number: 1,
      type: 11,
      typeName: 'google.protobuf.Value',
      label: 2,
    );
    schema.messages['RequiredValue'] = ProtoMessage('RequiredValue', [
      required,
    ], syntax: 'proto2');
    expect(codec.encode('RequiredValue', {'value': null}), [10, 2, 8, 0]);
    expect(() => codec.validateField(required, null), returnsNormally);
  });
}
