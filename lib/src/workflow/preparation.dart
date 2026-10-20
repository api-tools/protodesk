import 'dart:convert';
import 'dart:isolate';

import '../security/credentials.dart';

class PreparationFailure implements Exception {
  final String message;
  const PreparationFailure(this.message);
  @override
  String toString() => 'Request preparation: $message';
}

/// Definitions only. Preparing explicitly materializes a reviewed draft;
/// changing an environment never changes an existing call or saved snapshot.
class PreparationProfiles {
  late final Map<String, Object?> data;
  PreparationProfiles(Map<String, Object?> input) {
    try {
      data = Map<String, Object?>.from(jsonDecode(jsonEncode(input)) as Map);
      if (utf8.encode(jsonEncode(data)).length > 4 * 1024 * 1024) {
        throw const FormatException();
      }
      exact(data, {'version', 'environments', 'presets'});
      if (data['version'] != 1 ||
          data['environments'] is! List ||
          data['presets'] is! List ||
          environments.length > 32 ||
          presets.length > 32) {
        throw const FormatException();
      }
      final ids = <String>{};
      for (final list in [environments, presets]) {
        final names = <String>{};
        for (final item in list) {
          final id = item['id'] as String, name = item['name'] as String;
          if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id) ||
              !ids.add(id) ||
              name.trim().isEmpty ||
              name.length > 80 ||
              name.codeUnits.any((c) => c < 32 || c == 127) ||
              !names.add(name.toLowerCase())) {
            throw const FormatException();
          }
        }
      }
      for (final environment in environments) {
        exact(environment, {'id', 'name', 'variables'});
        final variables = environment['variables'] as Map;
        if (variables.length > 256) throw const FormatException();
        for (final entry in variables.entries) {
          if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$')
              .hasMatch(entry.key as String)) {
            throw const FormatException();
          }
          final variable = entry.value as Map;
          exact(variable, {'bound', 'value'});
          if (variable['bound'] is! bool ||
              (variable['bound'] == true) != variable.containsKey('value')) {
            throw const FormatException();
          }
          if (variable['bound'] == true) validValue(variable['value']);
        }
      }
      for (final preset in presets) {
        exact(preset, {'id', 'name', 'metadata', 'references'});
        final headers = literalHeaders(
          (preset['metadata'] as Map).cast<String, String>(),
        );
        final refs = MetadataReferences.decode(preset['references'] as String);
        if ({...headers.keys, ...refs.headers.keys}.length > 128) {
          throw const FormatException();
        }
      }
    } catch (_) {
      throw const PreparationFailure(
        'Invalid or unsupported profile definitions. Original data is preserved; review version, names, variables and metadata.',
      );
    }
  }
  static void exact(Map value, Set<String> allowed) {
    if (value.keys.any((key) => key is! String || !allowed.contains(key))) {
      throw const FormatException();
    }
  }

  static void validValue(Object? value, [int depth = 0]) {
    if (depth > 64) throw const FormatException();
    if (value is Map) {
      if (value.keys.any((k) => k is! String)) throw const FormatException();
      for (final item in value.values) {
        validValue(item, depth + 1);
      }
    } else if (value is List) {
      for (final item in value) {
        validValue(item, depth + 1);
      }
    } else if (value != null &&
        value is! String &&
        value is! bool &&
        value is! num) {
      throw const FormatException();
    }
    if (value is double && !value.isFinite) throw const FormatException();
  }

  factory PreparationProfiles.empty() =>
      PreparationProfiles({'version': 1, 'environments': [], 'presets': []});
  factory PreparationProfiles.decode(String? raw) {
    if (raw == null || raw.isEmpty) return PreparationProfiles.empty();
    try {
      if (raw.length > 4 * 1024 * 1024) throw const FormatException();
      return PreparationProfiles(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      throw const PreparationFailure(
        'Saved preparation definitions are invalid or unsupported. They remain intact.',
      );
    }
  }
  List<Map<String, Object?>> get environments => (data['environments'] as List)
      .map((e) => (e as Map).cast<String, Object?>())
      .toList();
  List<Map<String, Object?>> get presets => (data['presets'] as List)
      .map((e) => (e as Map).cast<String, Object?>())
      .toList();
  String encode() => jsonEncode(data);
  String safeExport() => PreparationProfiles({
    'version': 1,
    'environments': [
      for (final environment in environments)
        {
          ...environment,
          'variables': {
            for (final key in (environment['variables'] as Map).keys)
              key: {'bound': false},
          },
        },
    ],
    'presets': [
      for (final preset in presets)
        {
          ...preset,
          'metadata': <String, String>{},
          'references': MetadataReferences({
            for (final key in literalHeaders(
              (preset['metadata'] as Map).cast<String, String>(),
            ).keys)
              key: null,
            for (final key in MetadataReferences.decode(
              preset['references'] as String,
            ).headers.keys)
              key: null,
          }).encode(),
        },
    ],
  }).encode();
}

Map<String, String> literalHeaders(Map<String, String> input) {
  final result = <String, String>{};
  for (final entry in input.entries) {
    final key = entry.key.toLowerCase();
    if (!RegExp(r'^[a-z0-9_.-]{1,256}$').hasMatch(key) ||
        result.containsKey(key) ||
        utf8.encode(entry.value).length > 64 * 1024 ||
        entry.value.codeUnits.any((c) => c < 32 || c == 127)) {
      throw const PreparationFailure(
        'Invalid/ambiguous metadata names or values; sensitive contents omitted.',
      );
    }
    result[key] = entry.value;
  }
  if (result.length > 128) {
    throw const PreparationFailure('Metadata exceeds 128 headers.');
  }
  return result;
}

class PreparedRequest {
  final String body;
  final Map<String, String> metadata;
  final MetadataReferences references;
  final List<String> notes;
  PreparedRequest(this.body, this.metadata, this.references, this.notes);
}

/// Pure bounded preparation; no OS environment, shell, network, files or vault.
PreparedRequest prepareRequest({
  required PreparationProfiles profiles,
  required String body,
  required String metadata,
  required MetadataReferences references,
  String? environmentId,
  List<String> presetIds = const [],
}) {
  profiles = PreparationProfiles(profiles.data);
  if (utf8.encode(metadata).length > 16 * 1024 * 1024) {
    throw const PreparationFailure('Metadata template exceeds 16 MiB.');
  }
  if (utf8.encode(body).length > 4 * 1024 * 1024) {
    throw const PreparationFailure('Template exceeds 4 MiB.');
  }
  if (presetIds.length != presetIds.toSet().length) {
    throw const PreparationFailure('Duplicate preset selection.');
  }
  final variables = <String, Object?>{};
  if (environmentId != null) {
    final environment = profiles.environments
        .where((e) => e['id'] == environmentId)
        .firstOrNull;
    if (environment == null) {
      throw const PreparationFailure('Selected environment no longer exists.');
    }
    for (final entry in (environment['variables'] as Map).entries) {
      final definition = entry.value as Map;
      if (definition['bound'] == true) {
        variables[entry.key as String] = definition['value'];
      }
    }
  }
  const outputLimit = 32 * 1024 * 1024;
  var outputBytes = 0;
  void consume(int count) {
    outputBytes += count;
    if (outputBytes > outputLimit) {
      throw const PreparationFailure('Prepared JSON exceeds 32 MiB.');
    }
  }

  final costs = <String, int>{};
  Object? variable(String name) {
    if (!variables.containsKey(name)) {
      throw PreparationFailure(
        'Variable $name is missing or unbound. Select/bind an environment value before preparing.',
      );
    }
    return variables[name];
  }

  String textValue(Object? value) {
    if (value is Map || value is List) {
      throw const PreparationFailure(
        'Object/array variables require a whole JSON value placeholder.',
      );
    }
    return value is String ? value : jsonEncode(value);
  }

  final variableName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');
  String text(String value, {int limit = outputLimit}) {
    final buffer = StringBuffer();
    var i = 0;
    void append(String part) {
      if (buffer.length + part.length > limit) {
        throw const PreparationFailure(
          'Substitution exceeds its output limit.',
        );
      }
      buffer.write(part);
    }

    while (i < value.length) {
      final escaped = value.startsWith(r'$${', i);
      if (escaped || value.startsWith(r'${', i)) {
        final start = i + (escaped ? 3 : 2), end = value.indexOf('}', start);
        if (escaped) {
          if (end < 0) {
            append(value.substring(i + 1));
            break;
          }
          append(value.substring(i + 1, end + 1));
          i = end + 1;
          continue;
        }
        if (end < 0 || !variableName.hasMatch(value.substring(start, end))) {
          throw const PreparationFailure(
            'Invalid variable placeholder. Use \${name} or escape it as \$\${name}.',
          );
        }
        append(textValue(variable(value.substring(start, end))));
        i = end + 1;
      } else {
        append(value[i]);
        i++;
      }
    }
    return buffer.toString();
  }

  final wholeVariable = RegExp(r'^\$\{([A-Za-z_][A-Za-z0-9_]{0,63})\}$');
  Object? resolve(Object? value, [int depth = 0]) {
    if (depth > 64) {
      throw const PreparationFailure('Template nesting exceeds 64.');
    }
    if (value is String) {
      final whole = wholeVariable.firstMatch(value);
      if (whole != null) {
        final name = whole[1]!, result = variable(name);
        try {
          PreparationProfiles.validValue(result, depth);
        } catch (_) {
          throw const PreparationFailure(
            'Substituted JSON nesting exceeds 64.',
          );
        }
        consume(
          costs.putIfAbsent(name, () => utf8.encode(jsonEncode(result)).length),
        );
        return result;
      }
      final result = text(value);
      consume(utf8.encode(jsonEncode(result)).length);
      return result;
    }
    if (value is List) {
      consume(2 + (value.isEmpty ? 0 : value.length - 1));
      return [for (final item in value) resolve(item, depth + 1)];
    }
    if (value is Map) {
      consume(2 + (value.isEmpty ? 0 : value.length - 1));
      return {
        for (final entry in value.entries)
          entry.key: () {
            consume(utf8.encode(jsonEncode(entry.key)).length + 1);
            return resolve(entry.value, depth + 1);
          }(),
      };
    }
    consume(utf8.encode(jsonEncode(value)).length);
    return value;
  }

  Object? parsed;
  try {
    parsed = jsonDecode(body);
  } catch (_) {
    throw const PreparationFailure(
      'Template must be valid JSON. Sensitive contents omitted.',
    );
  }
  final output = jsonEncode(resolve(parsed));
  if (utf8.encode(output).length > 32 * 1024 * 1024) {
    throw const PreparationFailure('Prepared JSON exceeds 32 MiB.');
  }
  final literals = <String, String>{}, protected = <String, String?>{};
  void merge(Map<String, String> values, MetadataReferences refs) {
    for (final entry in literalHeaders(values).entries) {
      protected.remove(entry.key);
      literals[entry.key] = entry.value;
    }
    for (final entry in refs.headers.entries) {
      literals.remove(entry.key);
      protected[entry.key] = entry.value;
    }
  }

  for (final id in presetIds) {
    final preset = profiles.presets.where((p) => p['id'] == id).firstOrNull;
    if (preset == null) {
      throw const PreparationFailure(
        'Selected metadata preset no longer exists.',
      );
    }
    merge(
      (preset['metadata'] as Map).cast<String, String>(),
      MetadataReferences.decode(preset['references'] as String),
    );
  }
  merge(parseLiteralMetadata(metadata), references);
  final resolved = literalHeaders({
    for (final entry in literals.entries)
      entry.key: text(entry.value, limit: 64 * 1024),
  });
  if ({...resolved.keys, ...protected.keys}.length > 128) {
    throw const PreparationFailure('Prepared metadata exceeds 128 headers.');
  }
  return PreparedRequest(output, resolved, MetadataReferences(protected), [
    'Presets apply in selected order; existing request overrides win. Server defaults remain the base. Reflection, endpoints, TLS and authority are unchanged.',
    'Variables are resolved once in JSON values and literal request/preset headers. Keys and protected credential values are never interpolated. Queued/sent snapshots remain unchanged.',
    if (protected.values.any((id) => id == null)) 'Some protected headers are unbound. Bind them before invoking; preparation did not read any credential.',
  ]);
}

/// This top-level boundary deliberately captures only transferable strings and
/// IDs, never a widget, controller, database handle or credential backend.
Future<PreparedRequest> prepareRequestInWorker({
  required String definitions,
  required String body,
  required String metadata,
  required String references,
  String? environmentId,
  List<String> presetIds = const [],
}) => Isolate.run(
  () => prepareRequest(
    profiles: PreparationProfiles.decode(definitions),
    body: body,
    metadata: metadata,
    references: MetadataReferences.decode(references),
    environmentId: environmentId,
    presetIds: presetIds,
  ),
);
