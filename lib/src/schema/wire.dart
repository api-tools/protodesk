import 'dart:convert';
import 'dart:typed_data';

/// Descriptor-independent protobuf wire reader, also used for reflection.
class WireReader {
  final Uint8List bytes;
  int offset = 0;
  WireReader(List<int> value) : bytes = Uint8List.fromList(value) {
    if (bytes.length > 32 * 1024 * 1024) {
      throw const FormatException('Message exceeds 32 MiB');
    }
  }
  bool get done => offset == bytes.length;
  void require(int count) {
    if (count < 0 || offset + count > bytes.length) {
      throw const FormatException('Truncated protobuf');
    }
  }

  BigInt varint() {
    var value = BigInt.zero;
    for (var i = 0; i < 10; i++) {
      require(1);
      final b = bytes[offset++];
      if (i == 9 && b > 1) throw const FormatException('Invalid varint');
      value |= BigInt.from(b & 127) << (7 * i);
      if (b < 128) return value;
    }
    throw const FormatException('Invalid varint');
  }

  Uint8List take(int count) {
    require(count);
    final result = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return result;
  }

  Object value(int wire, {int? number}) => switch (wire) {
    0 => varint(),
    1 => take(8),
    2 => take(varint().toInt()),
    3 => group(number!),
    5 => take(4),
    _ => throw FormatException('Unsupported protobuf wire type $wire'),
  };
  Uint8List group(int number, [int depth = 0]) {
    if (depth > 64) throw const FormatException('Group nesting exceeds 64');
    final start = offset;
    while (!done) {
      final tagStart = offset;
      final tag = varint().toInt();
      if ((tag & 7) == 4) {
        if ((tag >> 3) != number) {
          throw const FormatException('Mismatched group');
        }
        return Uint8List.sublistView(bytes, start, tagStart);
      }
      if ((tag & 7) == 3) {
        group(tag >> 3, depth + 1);
      } else {
        value(tag & 7, number: tag >> 3);
      }
    }
    throw const FormatException('Unterminated group');
  }

  Map<int, List<Object>> fields() {
    final result = <int, List<Object>>{};
    while (!done) {
      final tag = varint().toInt();
      if (tag >> 3 == 0) throw const FormatException('Invalid field number');
      (result[tag >> 3] ??= []).add(value(tag & 7, number: tag >> 3));
    }
    return result;
  }
}

class WireWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  void varint(BigInt value) {
    value = value.toUnsigned(64);
    while (value > BigInt.from(127)) {
      _bytes.addByte((value & BigInt.from(127)).toInt() | 128);
      value >>= 7;
    }
    _bytes.addByte(value.toInt());
  }

  void tag(int number, int wire) => varint(BigInt.from(number * 8 + wire));
  void raw(List<int> bytes) => _bytes.add(bytes);
  void integer(int number, int value) {
    tag(number, 0);
    varint(BigInt.from(value));
  }

  void data(int number, List<int> value) {
    tag(number, 2);
    varint(BigInt.from(value.length));
    raw(value);
  }

  void text(int number, String value) => data(number, utf8.encode(value));
  Uint8List finish() => _bytes.takeBytes();
}

extension DescriptorFields on Map<int, List<Object>> {
  int integer(int n, [int fallback = 0]) => containsKey(n)
      ? (this[n]!.last as BigInt).toSigned(64).toInt()
      : fallback;
  String text(int n, [String fallback = '']) =>
      containsKey(n) ? utf8.decode(this[n]!.last as List<int>) : fallback;
  List<Map<int, List<Object>>> messages(int n) =>
      (this[n] ?? []).map((v) => WireReader(v as List<int>).fields()).toList();
}
