import 'dart:convert';

import 'credentials.dart';

/// Diagnostic copies redact every metadata value, including unknown custom
/// authentication header names. Complete response JSON copies remain unchanged.
Map<String, String> redactedMetadata(Map<String, String> metadata) => {
  for (final key in metadata.keys) key: '[redacted]',
};

Map<String, Object?> exportMetadata(
  Map<String, Object?> record,
  String literalKey,
  String referencesKey,
) {
  final result = {...record};
  final text = record[literalKey] as String? ?? '';
  final literals = text.trim().isEmpty
      ? <String, String>{}
      : parseLiteralMetadata(text);
  final references = MetadataReferences.decode(
    record[referencesKey] as String?,
  );
  result[literalKey] = text.trim().isEmpty ? '' : '{}';
  result[referencesKey] = MetadataReferences({
    for (final key in literals.keys) key.toLowerCase(): null,
    ...references.headers,
  }).encode();
  return result;
}

/// Remove exact and JSON-escaped known secrets from exception text. Never use
/// this as a substitute for excluding request/response bodies from diagnostics.
String redactKnownSecrets(String text, Iterable<String> secrets) {
  final values = <String>{};
  for (final value in secrets) {
    if (value.isEmpty) continue;
    values.add(value);
    final encoded = jsonEncode(value);
    values.add(encoded.substring(1, encoded.length - 1));
  }
  final ordered = values.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final value in ordered) {
    text = text.replaceAll(value, '[redacted]');
  }
  return text;
}
