import 'dart:convert';

import '../endpoint.dart';

/// Fixed error messages intentionally exclude platform errors, tokens and URLs.
class CredentialFailure implements Exception {
  final String message;
  const CredentialFailure(this.message);
  @override
  String toString() => 'Credentials: $message';
  static const unavailable = CredentialFailure(
    'OS credential store is locked or unavailable. Unlock it and retry; no plaintext fallback is used.',
  );
  static const missing = CredentialFailure(
    'Credential reference is unavailable. Rebind it in Servers.',
  );
  static const wrongScope = CredentialFailure(
    'Credential is bound to a different recipient. Select a credential for this endpoint or repository.',
  );
  static const invalid = CredentialFailure(
    'Unsupported or invalid credential. No credential contents are included in this error.',
  );
}

enum CredentialKind { metadata, github }

/// Recipient binding lives inside the OS-protected payload, not just SQLite.
/// A modified workspace cannot rebind an existing credential to another host.
class CredentialScope {
  final CredentialKind kind;
  final String target;
  const CredentialScope._(this.kind, this.target);

  factory CredentialScope.metadata(
    String address, {
    required bool tls,
    String serverName = '',
    String authority = '',
    String caFileReference = '',
    String httpAuthority = '',
  }) {
    late String host;
    late int port;
    try {
      validateGrpcAuthority(httpAuthority);
      final endpoint = parseServerAddress(address);
      host = endpoint.$1.toLowerCase();
      port = endpoint.$2;
    } catch (_) {
      throw CredentialFailure.invalid;
    }
    if (caFileReference.length > 4096 ||
        caFileReference.codeUnits.any((c) => c < 32 || c == 127)) {
      throw CredentialFailure.invalid;
    }
    final name = host.contains(':') && !host.startsWith('[') ? '[$host]' : host;
    final defaultAuthority = httpAuthority.isEmpty
        ? grpcAuthority(host, port)
        : httpAuthority;
    final effectiveAuthority = authority.isEmpty ? defaultAuthority : authority;
    final effectiveName = serverName.trim().isNotEmpty
        ? serverName.trim()
        : authority.isNotEmpty
        ? authority
        : host;
    for (final value in [effectiveAuthority, effectiveName]) {
      if (value.length > 1024 ||
          value.codeUnits.any((c) => c < 32 || c == 127)) {
        throw CredentialFailure.invalid;
      }
    }
    return CredentialScope._(
      CredentialKind.metadata,
      jsonEncode({
        'endpoint': '$name:$port',
        'tls': tls,
        'caFile': tls ? caFileReference : '',
        'serverName': tls ? effectiveName.toLowerCase() : '',
        'authority': effectiveAuthority.toLowerCase(),
      }),
    );
  }

  factory CredentialScope.github(String owner, String repository) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(owner) ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(repository) ||
        repository == '.' ||
        repository == '..') {
      throw CredentialFailure.invalid;
    }
    return CredentialScope._(
      CredentialKind.github,
      'https://api.github.com/repos/${owner.toLowerCase()}/${repository.toLowerCase()}',
    );
  }

  Map<String, Object?> get description => {'kind': kind.name, 'target': target};
  bool matches(CredentialScope other) =>
      kind == other.kind && target == other.target;
  static CredentialScope decode(Object? object) {
    if (object is! Map ||
        object.keys.any((k) => !['kind', 'target'].contains(k)) ||
        object['target'] is! String ||
        (object['target'] as String).length > 8192) {
      throw CredentialFailure.invalid;
    }
    final kinds = CredentialKind.values.where((k) => k.name == object['kind']);
    if (kinds.isEmpty) throw CredentialFailure.invalid;
    return CredentialScope._(kinds.single, object['target'] as String);
  }
}

bool validCredentialId(String id) =>
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(id);

/// The backend stores protected strings only. Implementations must never use a
/// plaintext file/SQLite fallback when the OS credential service is unavailable.
abstract interface class CredentialVault {
  Future<String?> read(String id);
  Future<void> write(String id, String protectedPayload);
  Future<void> delete(String id);
}

class CredentialValue {
  final CredentialScope scope;
  final String value;
  CredentialValue(this.scope, this.value) {
    if (value.isEmpty ||
        utf8.encode(value).length > 64 * 1024 ||
        value.codeUnits.any((c) => c < 32 || c == 127) ||
        (scope.kind == CredentialKind.github &&
            value.codeUnits.any((c) => c <= 32 || c > 126))) {
      throw CredentialFailure.invalid;
    }
  }
  // Deliberately no toJson: generic exports cannot serialize secret objects.
  String encodeProtected() =>
      jsonEncode({'version': 1, 'scope': scope.description, 'value': value});
  static CredentialValue decodeProtected(String payload) {
    try {
      if (payload.length > 512 * 1024) throw CredentialFailure.invalid;
      final object = jsonDecode(payload);
      if (object is! Map ||
          object['version'] != 1 ||
          object.keys.any((k) => !['version', 'scope', 'value'].contains(k)) ||
          object['value'] is! String) {
        throw CredentialFailure.invalid;
      }
      return CredentialValue(
        CredentialScope.decode(object['scope']),
        object['value'] as String,
      );
    } catch (_) {
      throw CredentialFailure.invalid;
    }
  }

  @override
  String toString() => 'CredentialValue(${scope.kind.name}, [protected])';
}

/// No registry operation accepts a secret value. SQLite contains labels,
/// recipient scope and lifecycle state only, never protected payloads.
abstract interface class CredentialCatalog {
  String create(String label, CredentialScope scope);
  void state(String id, String state);
  bool contains(String id);
  void remove(String id);
}

class CredentialService {
  final CredentialVault vault;
  final CredentialCatalog catalog;
  bool _disposed = false;
  CredentialService(this.vault, this.catalog);
  void dispose() => _disposed = true;
  void _active() {
    if (_disposed) throw CredentialFailure.unavailable;
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
    try {
      _active();
      return await action().timeout(const Duration(seconds: 15));
    } catch (_) {
      throw CredentialFailure.unavailable;
    }
  }

  Future<String> create(String label, CredentialValue value) async {
    _active();
    if (label.trim().isEmpty || label.length > 128) {
      throw CredentialFailure.invalid;
    }
    final id = catalog.create(label.trim(), value.scope);
    if (!validCredentialId(id)) throw CredentialFailure.invalid;
    try {
      await _operation(() => vault.write(id, value.encodeProtected()));
      final verified = await resolve(id, value.scope);
      if (verified != value.value) throw CredentialFailure.unavailable;
      _active();
      catalog.state(id, 'ready');
      return id;
    } catch (_) {
      if (!_disposed) catalog.state(id, 'unavailable');
      rethrow;
    }
  }

  Future<String> resolve(String? id, CredentialScope expected) async {
    if (id == null) throw CredentialFailure.missing;
    if (!validCredentialId(id)) throw CredentialFailure.invalid;
    final payload = await _operation(() => vault.read(id));
    _active();
    if (payload == null) throw CredentialFailure.missing;
    final credential = CredentialValue.decodeProtected(payload);
    if (!credential.scope.matches(expected)) throw CredentialFailure.wrongScope;
    return credential.value;
  }

  Future<void> delete(String id) async {
    _active();
    if (!validCredentialId(id) || !catalog.contains(id)) {
      throw CredentialFailure.missing;
    }
    await _operation(() => vault.delete(id));
    if (await _operation(() => vault.read(id)) != null) {
      throw CredentialFailure.unavailable;
    }
    _active();
    catalog.remove(id);
  }
}

/// Versioned header → opaque reference map. Null denotes an intentionally
/// redacted/unbound value from a safe export, never a literal placeholder token.
class MetadataReferences {
  final Map<String, String?> headers;
  MetadataReferences(Map<String, String?> value)
    : headers = Map.unmodifiable(value) {
    if (headers.length > 128 ||
        headers.entries.any(
          (e) =>
              !RegExp(r'^[a-z0-9_.-]+$').hasMatch(e.key) ||
              e.key.length > 256 ||
              (e.value != null && !validCredentialId(e.value!)),
        )) {
      throw CredentialFailure.invalid;
    }
  }
  factory MetadataReferences.decode(String? text) {
    if (text == null || text.trim().isEmpty) return MetadataReferences({});
    try {
      if (text.length > 64 * 1024) throw CredentialFailure.invalid;
      final data = jsonDecode(text);
      if (data is! Map ||
          data['version'] != 1 ||
          data.keys.any((k) => !['version', 'headers'].contains(k)) ||
          data['headers'] is! Map) {
        throw CredentialFailure.invalid;
      }
      return MetadataReferences(
        Map<String, String?>.from(data['headers'] as Map),
      );
    } catch (_) {
      throw CredentialFailure.invalid;
    }
  }
  String encode() => jsonEncode({'version': 1, 'headers': headers});
  Future<Map<String, String>> resolve(
    Map<String, String> literals,
    CredentialService service,
    CredentialScope scope,
  ) async {
    final result = Map<String, String>.from(literals);
    for (final entry in headers.entries) {
      final value = await service.resolve(entry.value, scope);
      result.removeWhere((key, _) => key.toLowerCase() == entry.key);
      result[entry.key] = value;
    }
    return result;
  }
}

/// Never include malformed metadata source text in errors or diagnostic copies.
Map<String, String> parseLiteralMetadata(String text) {
  try {
    final value = jsonDecode(text);
    if (value is! Map || value.values.any((v) => v is! String)) {
      throw const FormatException();
    }
    return value.cast<String, String>();
  } catch (_) {
    throw const FormatException(
      'Metadata must be a valid JSON object of strings; sensitive contents are omitted.',
    );
  }
}
