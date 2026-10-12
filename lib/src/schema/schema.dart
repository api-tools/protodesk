import 'wire.dart';

class ProtoField {
  final String name, jsonName, typeName;
  final int number, type, label;
  final int? oneof;
  final bool optional;
  const ProtoField({
    required this.name,
    required this.jsonName,
    required this.number,
    required this.type,
    this.typeName = '',
    this.label = 1,
    this.oneof,
    this.optional = false,
  });
  bool get repeated => label == 3;
  ProtoField get item => ProtoField(
    name: name,
    jsonName: jsonName,
    number: number,
    type: type,
    typeName: typeName,
  );
  static ProtoField fromDescriptor(Map<int, List<Object>> d) => ProtoField(
    name: d.text(1),
    jsonName: d.text(10, camel(d.text(1))),
    number: d.integer(3),
    type: d.integer(5),
    typeName: d.text(6).replaceFirst(RegExp(r'^\.'), ''),
    label: d.integer(4, 1),
    oneof: d.containsKey(9) ? d.integer(9) : null,
    optional: d.integer(17) == 1,
  );
  static String camel(String name) =>
      name.replaceAllMapped(RegExp(r'_([a-z])'), (m) => m[1]!.toUpperCase());
}

class ProtoMessage {
  final String name;
  final List<ProtoField> fields;
  final bool mapEntry;
  final String syntax;
  ProtoMessage(
    this.name,
    this.fields, {
    this.mapEntry = false,
    this.syntax = 'proto3',
  });
}

class ProtoMethod {
  final String service, name, input, output;
  final bool clientStreaming, serverStreaming;
  const ProtoMethod(
    this.service,
    this.name,
    this.input,
    this.output, {
    this.clientStreaming = false,
    this.serverStreaming = false,
  });
  String get path => '/$service/$name';
}

class SchemaRegistry {
  final messages = <String, ProtoMessage>{};
  final enums = <String, Map<int, String>>{};
  final enumNumbers = <String, Map<String, int>>{};
  final methods = <String, ProtoMethod>{};
  final files = <String, List<int>>{};
  List<String> get services =>
      methods.values.map((m) => m.service).toSet().toList()..sort();
  void addDescriptorSet(List<int> bytes) {
    for (final file in WireReader(bytes).fields()[1] ?? []) {
      addFile(file as List<int>);
    }
    validate();
  }

  void addFile(List<int> bytes) {
    final file = WireReader(bytes).fields();
    final filename = file.text(1);
    if (files.containsKey(filename)) return;
    files[filename] = bytes;
    final package = file.text(2);
    final syntax = file.text(12, 'proto2');
    if (syntax == 'editions') {
      throw const FormatException(
        'Protobuf editions are not yet supported; use proto2/proto3',
      );
    }
    String qualify(String prefix, String name) =>
        prefix.isEmpty ? name : '$prefix.$name';
    void addEnum(Map<int, List<Object>> e, String prefix) {
      final name = qualify(prefix, e.text(1));
      final canonical = <int, String>{};
      final numbers = <String, int>{};
      for (final value in e.messages(2)) {
        final number = value.integer(2), label = value.text(1);
        canonical.putIfAbsent(number, () => label);
        numbers[label] = number;
      }
      enums[name] = canonical;
      enumNumbers[name] = numbers;
    }

    void addMessage(Map<int, List<Object>> m, String prefix, [int depth = 0]) {
      if (depth > 64) {
        throw const FormatException('Schema nesting exceeds 64 levels');
      }
      final name = qualify(prefix, m.text(1));
      messages[name] = ProtoMessage(
        name,
        m.messages(2).map(ProtoField.fromDescriptor).toList(),
        mapEntry: m.messages(7).any((o) => o.integer(7) == 1),
        syntax: syntax,
      );
      for (final n in m.messages(3)) {
        addMessage(n, name, depth + 1);
      }
      for (final e in m.messages(4)) {
        addEnum(e, name);
      }
    }

    for (final m in file.messages(4)) {
      addMessage(m, package);
    }
    for (final e in file.messages(5)) {
      addEnum(e, package);
    }
    for (final s in file.messages(6)) {
      final service = qualify(package, s.text(1));
      for (final m in s.messages(2)) {
        final method = ProtoMethod(
          service,
          m.text(1),
          m.text(2).substring(1),
          m.text(3).substring(1),
          clientStreaming: m.integer(5) == 1,
          serverStreaming: m.integer(6) == 1,
        );
        methods[method.path] = method;
      }
    }
    if (files.length > 2048 || messages.length > 20000) {
      throw const FormatException('Schema exceeds resource limit');
    }
  }

  void validate() {
    for (final m in messages.values) {
      final numbers = <int>{};
      for (final f in m.fields) {
        if (!numbers.add(f.number)) {
          throw FormatException('Duplicate field in ${m.name}');
        }
        if ((f.type == 11 || f.type == 10) &&
            !messages.containsKey(f.typeName)) {
          throw FormatException('Missing message descriptor ${f.typeName}');
        }
        if (f.type == 14 && !enums.containsKey(f.typeName)) {
          throw FormatException('Missing enum descriptor ${f.typeName}');
        }
      }
    }
  }
}
