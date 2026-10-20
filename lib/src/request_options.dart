import 'dart:convert';

/// Versioned request options are independent of connection/source configuration.
/// Missing legacy options preserve the caller's existing values when loaded.
class RequestOptions {
  final int timeoutMs;
  final String authority;
  RequestOptions(int timeoutMs, this.authority)
    : timeoutMs = timeoutMs > 0 ? timeoutMs : 5000 {
    if (authority.length > 1024 ||
        authority.codeUnits.any((c) => c < 32 || c == 127)) {
      throw const FormatException(
        'Invalid request authority; sensitive contents omitted.',
      );
    }
  }
  String encode() => jsonEncode({
    'version': 1,
    'timeoutMs': timeoutMs,
    'authority': authority,
  });
  static RequestOptions? decode(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    try {
      if (text.length > 8192) throw const FormatException();
      final value = jsonDecode(text);
      if (value is! Map ||
          value['version'] != 1 ||
          value['timeoutMs'] is! int ||
          value['authority'] is! String ||
          value.keys.any(
            (k) => !['version', 'timeoutMs', 'authority'].contains(k),
          )) {
        throw const FormatException();
      }
      return RequestOptions(
        value['timeoutMs'] as int,
        value['authority'] as String,
      );
    } catch (_) {
      throw const FormatException(
        'Unsupported or invalid request options; existing data remains intact.',
      );
    }
  }
}
