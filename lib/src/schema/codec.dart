import 'dart:convert';
import 'dart:typed_data';

import 'schema.dart';
import 'wire.dart';

class ProtoCodec {
  final SchemaRegistry schema;
  ProtoCodec(this.schema);
  ProtoMessage message(String type) =>
      schema.messages[type] ?? (throw FormatException('Unknown message $type'));
  bool isMap(ProtoField f) => f.type == 11 && message(f.typeName).mapEntry;
  static const wrappers = {
    'DoubleValue': 1,
    'FloatValue': 2,
    'Int64Value': 3,
    'UInt64Value': 4,
    'Int32Value': 5,
    'UInt32Value': 13,
    'BoolValue': 8,
    'StringValue': 9,
    'BytesValue': 12,
  };
  Uint8List encode(String type, Object? json, {int depth = 0}) {
    if (depth > 64) throw const FormatException('Message nesting exceeds 64');
    final m = message(type);
    json = _toOrdinary(type, json);
    if (json is! Map) throw FormatException('$type requires a JSON object');
    final w = WireWriter();
    final used = <int>{};
    final oneofs = <int>{};
    for (final entry in json.entries) {
      final matches = m.fields.where(
        (f) => f.name == entry.key || f.jsonName == entry.key,
      );
      if (matches.isEmpty) {
        throw FormatException('Unknown field ${entry.key} in $type');
      }
      final f = matches.first;
      if (!used.add(f.number)) {
        throw FormatException('Duplicate field ${f.name}');
      }
      final value = entry.value;
      if (value == null &&
          f.typeName != 'google.protobuf.Value' &&
          f.typeName != 'google.protobuf.NullValue') {
        continue;
      }
      if (f.oneof != null && !oneofs.add(f.oneof!)) {
        throw FormatException('Multiple members of oneof in $type');
      }
      if (isMap(f)) {
        _writeMap(w, f, value, depth);
      } else if (f.repeated) {
        if (value is! List) {
          throw FormatException('${f.name} requires an array');
        }
        for (final v in value) {
          _write(w, f, v, depth);
        }
      } else {
        if (m.syntax == 'proto3' &&
            f.type != 11 &&
            f.oneof == null &&
            !f.optional &&
            _isDefault(f, value)) {
          continue;
        }
        _write(w, f, value, depth);
      }
    }
    for (final field in m.fields.where((f) => f.label == 2)) {
      if (!used.contains(field.number) ||
          (json[field.jsonName] ?? json[field.name]) == null) {
        throw FormatException('Required field ${field.name} is missing');
      }
    }
    final bytes = w.finish();
    if (bytes.length > 32 * 1024 * 1024) {
      throw const FormatException('Message exceeds 32 MiB');
    }
    return bytes;
  }

  bool _isDefault(ProtoField f, Object? v) {
    if (f.type == 9 || f.type == 12) return v == '';
    if (f.type == 8) return v == false;
    if (f.type == 14) return v == 0 || v == schema.enums[f.typeName]?[0];
    return v == 0 || v == '0';
  }

  void validateField(ProtoField field, Object? value) {
    final writer = WireWriter();
    if (isMap(field)) {
      _writeMap(writer, field, value, 0);
    } else if (field.repeated) {
      if (value is! List) {
        throw const FormatException('Repeated field requires an array');
      }
      for (final item in value) {
        _write(writer, field, item, 0);
      }
    } else {
      _write(writer, field, value, 0);
    }
    if (writer.finish().length > 32 * 1024 * 1024) {
      throw const FormatException('Field exceeds 32 MiB');
    }
  }

  void _writeMap(WireWriter w, ProtoField f, Object? value, int depth) {
    if (value is! Map) {
      throw FormatException('${f.name} requires an object');
    }
    final map = message(f.typeName);
    for (final e in value.entries) {
      Object key = e.key;
      final k = map.fields.first;
      if (k.type == 8) {
        if (key != 'true' && key != 'false') {
          throw const FormatException('Invalid boolean map key');
        }
        key = key == 'true';
      }
      w.data(
        f.number,
        encode(f.typeName, {
          k.jsonName: key,
          map.fields[1].jsonName: e.value,
        }, depth: depth + 1),
      );
    }
  }

  void _write(WireWriter w, ProtoField f, Object? v, int depth) {
    final type = f.type;
    if (type == 10) {
      w.tag(f.number, 3);
      w.raw(encode(f.typeName, v, depth: depth + 1));
      w.tag(f.number, 4);
      return;
    }
    if (type == 11) {
      w.data(f.number, encode(f.typeName, v, depth: depth + 1));
      return;
    }
    if (type == 9) {
      if (v is! String) throw FormatException('${f.name} must be a string');
      w.text(f.number, v);
      return;
    }
    if (type == 12) {
      if (v is! String) throw FormatException('${f.name} must be base64');
      w.data(f.number, base64.decode(base64.normalize(v)));
      return;
    }
    if (type == 1 || type == 2) {
      final number = v is num
          ? v.toDouble()
          : switch (v) {
              'NaN' => double.nan,
              'Infinity' => double.infinity,
              '-Infinity' => double.negativeInfinity,
              String value
                  when RegExp(r'^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$')
                      .hasMatch(value) =>
                double.tryParse(value) ??
                    (throw FormatException('${f.name} must be a number')),
              _ => throw FormatException('${f.name} must be a number'),
            };
      final special = v == 'NaN' || v == 'Infinity' || v == '-Infinity';
      if (!special && !number.isFinite) {
        throw FormatException('${f.name} outside floating-point range');
      }
      final data = ByteData(type == 1 ? 8 : 4);
      if (type == 1) {
        data.setFloat64(0, number, Endian.little);
      } else {
        data.setFloat32(0, number, Endian.little);
        if (!special && !data.getFloat32(0, Endian.little).isFinite) {
          throw FormatException('${f.name} outside float32 range');
        }
      }
      w.tag(f.number, type == 1 ? 1 : 5);
      w.raw(data.buffer.asUint8List());
      return;
    }
    BigInt n;
    if (type == 8) {
      if (v is! bool) throw FormatException('${f.name} must be boolean');
      n = BigInt.from(v ? 1 : 0);
    } else if (type == 14) {
      final values = schema.enums[f.typeName]!;
      final numbers =
          schema.enumNumbers[f.typeName] ??
          {for (final e in values.entries) e.value: e.key};
      if (v == null && f.typeName == 'google.protobuf.NullValue') {
        n = BigInt.zero;
      } else if (v is String && numbers.containsKey(v)) {
        n = BigInt.from(numbers[v]!);
      } else if (v is int) {
        n = BigInt.from(v);
      } else {
        throw FormatException('Invalid enum ${f.name}');
      }
    } else {
      if (v is! String && v is! num) {
        throw FormatException('${f.name} requires an integer');
      }
      n = _integer(v.toString(), f.name);
    }
    final unsigned = {4, 6, 7, 13}.contains(type);
    final bits = {3, 4, 6, 16, 18}.contains(type) ? 64 : 32;
    final min = unsigned ? BigInt.zero : -(BigInt.one << (bits - 1));
    final max = (BigInt.one << (unsigned ? bits : bits - 1)) - BigInt.one;
    if (n < min || n > max) {
      throw FormatException('${f.name} outside $bits-bit range');
    }
    if (type == 17 || type == 18) {
      n = (n << 1) ^ (n >> (bits - 1));
    }
    if ({6, 7, 15, 16}.contains(type)) {
      final length = (type == 6 || type == 16) ? 8 : 4;
      w.tag(f.number, length == 8 ? 1 : 5);
      n = n.toUnsigned(length * 8);
      w.raw(
        List.generate(
          length,
          (i) => ((n >> (8 * i)) & BigInt.from(255)).toInt(),
        ),
      );
    } else {
      w.tag(f.number, 0);
      w.varint(n);
    }
  }

  BigInt _integer(String value, String field) {
    if (value.length > 128) throw FormatException('Invalid integer $field');
    final direct = BigInt.tryParse(value);
    if (direct != null) return direct;
    final match = RegExp(r'^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$')
        .firstMatch(value);
    if (match == null || value.length > 128) {
      throw FormatException('Invalid integer $field');
    }
    final fraction = match[3] ?? '';
    final exponent = int.tryParse(match[4] ?? '0');
    if (exponent == null || exponent.abs() > 128) {
      throw FormatException('Integer exponent outside supported range: $field');
    }
    var integer = BigInt.parse('${match[2]}$fraction');
    final shift = exponent - fraction.length;
    if (shift >= 0) {
      integer *= BigInt.from(10).pow(shift);
    } else {
      final divisor = BigInt.from(10).pow(-shift);
      if (integer.remainder(divisor) != BigInt.zero) {
        throw FormatException('$field requires an integer');
      }
      integer ~/= divisor;
    }
    return match[1] == '-' ? -integer : integer;
  }

  Object? decode(String type, List<int> bytes, {int depth = 0}) {
    if (depth > 64) throw const FormatException('Message nesting exceeds 64');
    final m = message(type);
    final r = WireReader(bytes);
    final json = <String, Object?>{};
    final active = <int, String>{};
    while (!r.done) {
      final tag = r.varint().toInt();
      final number = tag >> 3;
      final wire = tag & 7;
      if (number == 0) throw const FormatException('Invalid field tag');
      final raw = r.value(wire, number: number);
      final fields = m.fields.where((f) => f.number == number);
      if (fields.isEmpty) continue;
      final f = fields.first;
      final expected = switch (f.type) {
        1 || 6 || 16 => 1,
        2 || 7 || 15 => 5,
        9 || 11 || 12 => 2,
        10 => 3,
        _ => 0,
      };
      final values = <Object?>[];
      if (f.repeated && wire == 2 && expected != 2) {
        final packed = WireReader(raw as List<int>);
        while (!packed.done) {
          values.add(_read(f, packed.value(expected), depth));
        }
      } else {
        if (wire != expected) {
          throw FormatException('Incorrect wire type for ${f.name}');
        }
        values.add(_read(f, raw, depth));
      }
      if (isMap(f)) {
        final map = json.putIfAbsent(
          f.jsonName,
          () => <String, Object?>{},
        ) as Map<String, Object?>;
        final descriptor = message(f.typeName);
        final entry = values.single as Map;
        final key =
            entry[descriptor.fields[0].jsonName] ??
            defaultValue(descriptor.fields[0]);
        map[key.toString()] =
            entry[descriptor.fields[1].jsonName] ??
            defaultValue(descriptor.fields[1]);
      } else if (f.repeated) {
        (json.putIfAbsent(f.jsonName, () => <Object?>[]) as List).addAll(
          values,
        );
      } else {
        if (f.oneof != null) {
          final old = active[f.oneof];
          if (old != null) json.remove(old);
          active[f.oneof!] = f.jsonName;
        }
        final previous = json[f.jsonName];
        final next = values.last;
        json[f.jsonName] =
            (f.type == 10 || f.type == 11) &&
                previous is Map<String, Object?> &&
                next is Map<String, Object?> &&
                !f.typeName.startsWith('google.protobuf.')
            ? _merge(f.typeName, previous, next)
            : next;
      }
    }
    for (final field in m.fields) {
      if (field.label == 2 && !json.containsKey(field.jsonName)) {
        throw FormatException('Required field ${field.name} is missing');
      }
      if (m.syntax == 'proto3' &&
          !field.repeated &&
          field.type != 11 &&
          field.type != 10 &&
          field.oneof == null &&
          !field.optional &&
          _isDefault(field, json[field.jsonName])) {
        json.remove(field.jsonName);
      }
    }
    return _fromOrdinary(type, json);
  }

  Object? _read(ProtoField f, Object raw, int depth) {
    final type = f.type;
    if (type == 11 || type == 10) {
      return decode(f.typeName, raw as List<int>, depth: depth + 1);
    }
    if (type == 9) return utf8.decode(raw as List<int>);
    if (type == 12) return base64.encode(raw as List<int>);
    if (type == 1 || type == 2) {
      final data = ByteData.sublistView(Uint8List.fromList(raw as List<int>));
      final n = type == 1
          ? data.getFloat64(0, Endian.little)
          : data.getFloat32(0, Endian.little);
      return n.isNaN
          ? 'NaN'
          : n == double.infinity
          ? 'Infinity'
          : n == double.negativeInfinity
          ? '-Infinity'
          : n;
    }
    var n = raw is BigInt ? raw : BigInt.zero;
    if (raw is List<int>) {
      for (var i = 0; i < raw.length; i++) {
        n |= BigInt.from(raw[i]) << (8 * i);
      }
    }
    if (type == 8) return n != BigInt.zero;
    if (type == 17 || type == 18) {
      n = (n >> 1) ^ (-(n & BigInt.one));
    } else if ({3, 5, 14, 15, 16}.contains(type)) {
      n = n.toSigned({3, 16}.contains(type) ? 64 : 32);
    }
    if (type == 14) {
      return f.typeName == 'google.protobuf.NullValue'
          ? null
          : schema.enums[f.typeName]?[n.toInt()] ?? n.toInt();
    }
    return {3, 4, 6, 16, 18}.contains(type) ? n.toString() : n.toInt();
  }

  Map<String, Object?> _merge(
    String type,
    Map<String, Object?> previous,
    Map<String, Object?> next,
  ) {
    final result = {...previous};
    for (final f in message(type).fields) {
      if (!next.containsKey(f.jsonName)) continue;
      if (f.oneof != null) {
        for (final other in message(
          type,
        ).fields.where((s) => s.oneof == f.oneof)) {
          result.remove(other.jsonName);
        }
      }
      final a = result[f.jsonName], b = next[f.jsonName];
      if (isMap(f) && a is Map && b is Map) {
        result[f.jsonName] = {...a, ...b};
      } else if (f.repeated && a is List && b is List) {
        result[f.jsonName] = [...a, ...b];
      } else if ((f.type == 11 || f.type == 10) &&
          a is Map<String, Object?> &&
          b is Map<String, Object?>) {
        result[f.jsonName] = _merge(f.typeName, a, b);
      } else {
        result[f.jsonName] = b;
      }
    }
    return result;
  }

  Object? defaultValue(ProtoField f) => (f.type == 11 || f.type == 10)
      ? {}
      : f.type == 8
      ? false
      : {9, 12}.contains(f.type)
      ? ''
      : f.type == 14
      ? schema.enums[f.typeName]?.values.first
      : {3, 4, 6, 16, 18}.contains(f.type)
      ? '0'
      : 0;
  Object? _toOrdinary(String type, Object? json) {
    if (!type.startsWith('google.protobuf.')) return json;
    final short = type.substring(16);
    if (wrappers.containsKey(short)) return {'value': json};
    if (short == 'Timestamp') {
      if (json is! String) {
        throw const FormatException('Timestamp requires RFC3339');
      }
      final date = DateTime.parse(json).toUtc();
      final micros = date.microsecondsSinceEpoch;
      var seconds = micros ~/ 1000000;
      if (micros < 0 && micros % 1000000 != 0) seconds--;
      final fraction = RegExp(r'\.(\d+)').firstMatch(json)?.group(1) ?? '';
      if (fraction.length > 9) {
        throw const FormatException('Timestamp precision exceeds nanos');
      }
      return {
        'seconds': seconds.toString(),
        'nanos': fraction.isEmpty ? 0 : int.parse(fraction.padRight(9, '0')),
      };
    }
    if (short == 'Duration') {
      final match = RegExp(r'^(-?)(\d+)(?:\.(\d{1,9}))?s$')
          .firstMatch(json.toString());
      if (match == null) {
        throw const FormatException('Duration requires seconds ending in s');
      }
      final sign = match[1] == '-' ? -1 : 1;
      return {
        'seconds': (BigInt.parse(match[2]!) * BigInt.from(sign)).toString(),
        'nanos': int.parse((match[3] ?? '0').padRight(9, '0')) * sign,
      };
    }
    if (short == 'FieldMask') {
      if (json is! String) {
        throw const FormatException('FieldMask requires a string');
      }
      return {
        'paths': json.isEmpty
            ? []
            : json
                  .split(',')
                  .map(
                    (p) => p.replaceAllMapped(
                      RegExp('[A-Z]'),
                      (m) => '_${m[0]!.toLowerCase()}',
                    ),
                  )
                  .toList(),
      };
    }
    if (short == 'Struct') {
      if (json is! Map) {
        throw const FormatException('Struct requires an object');
      }
      return {'fields': json};
    }
    if (short == 'ListValue') {
      if (json is! List) {
        throw const FormatException('ListValue requires an array');
      }
      return {'values': json};
    }
    if (short == 'Value') {
      return switch (json) {
        null => {'nullValue': null},
        bool v => {'boolValue': v},
        num v => {'numberValue': v},
        String v => {'stringValue': v},
        List v => {'listValue': v},
        Map v => {'structValue': v},
        _ => throw const FormatException('Invalid Value'),
      };
    }
    if (short == 'Any') {
      if (json is! Map || json['@type'] is! String) {
        throw const FormatException('Any requires @type');
      }
      final url = json['@type'] as String;
      final inner = url.split('/').last;
      final content =
          inner.startsWith('google.protobuf.') && inner != 'google.protobuf.Any'
                ? json['value']
                : {...json}
            ..remove('@type');
      return {'typeUrl': url, 'value': base64.encode(encode(inner, content))};
    }
    return json;
  }

  Object? _fromOrdinary(String type, Map<String, Object?> json) {
    if (!type.startsWith('google.protobuf.')) return json;
    final short = type.substring(16);
    if (wrappers.containsKey(short)) {
      return json['value'] ?? defaultValue(message(type).fields.first);
    }
    if (short == 'Timestamp') {
      final seconds = int.parse((json['seconds'] ?? '0').toString());
      final nanos = (json['nanos'] ?? 0) as int;
      final date = DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000,
        isUtc: true,
      ).toIso8601String().split('.').first;
      return '$date${_fraction(nanos)}Z';
    }
    if (short == 'Duration') {
      final seconds = BigInt.parse((json['seconds'] ?? '0').toString());
      final nanos = (json['nanos'] ?? 0) as int;
      return '${seconds.isNegative || nanos < 0 ? '-' : ''}${seconds.abs()}${_fraction(nanos.abs())}s';
    }
    if (short == 'FieldMask') {
      return ((json['paths'] ?? []) as List)
          .map((p) => ProtoField.camel(p.toString()))
          .join(',');
    }
    if (short == 'Struct') return json['fields'] ?? {};
    if (short == 'ListValue') return json['values'] ?? [];
    if (short == 'Value') return json.values.firstOrNull;
    if (short == 'Any') {
      final url = (json['typeUrl'] ?? '') as String;
      final inner = url.split('/').last;
      final content = decode(
        inner,
        base64.decode((json['value'] ?? '') as String),
      );
      return {
        '@type': url,
        if (content is Map && !inner.startsWith('google.protobuf.'))
          ...content.cast<String, Object?>()
        else
          'value': content,
      };
    }
    return json;
  }

  String _fraction(int nanos) {
    if (nanos == 0) return '';
    final digits = nanos.toString().padLeft(9, '0');
    return '.${digits.substring(0, nanos % 1000000 == 0
        ? 3
        : nanos % 1000 == 0
        ? 6
        : 9)}';
  }
}
