import 'dart:convert';
import 'dart:async';

import 'package:path/path.dart' as p;

import '../security/credentials.dart';

/// Versioned JSON is retained verbatim, including extension fields.
class SourceConfiguration {
  final Map<String, Object?> data;
  SourceConfiguration(Map<String, Object?> value)
    : data = Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map) {
    if (data['version'] != 1) {
      throw const FormatException(
        'Unsupported proto source configuration version',
      );
    }
    if (data['sources'] is! List || data['importRoots'] is! List) {
      throw const FormatException('Invalid proto source configuration');
    }
    if (sources.length > 2048 ||
        importRoots.length > 128 ||
        jsonEncode(data).length > 2 * 1024 * 1024) {
      throw const FormatException(
        'Source configuration exceeds resource limits',
      );
    }
    final ids = <Object?>{};
    for (final source in sources) {
      if (source['id'] != null &&
          (source['id'] is! String || !ids.add(source['id']))) {
        throw const FormatException('Source IDs must be unique strings');
      }
      if (!['file', 'directory', 'git'].contains(source['type'])) {
        throw FormatException('Unsupported source type: ${source['type']}');
      }
      if (source['type'] == 'git') {
        repository(source['url'] as String? ?? '');
        if (source['credentialRef'] != null &&
            (source['credentialRef'] is! String ||
                !validCredentialId(source['credentialRef'] as String))) {
          throw CredentialFailure.invalid;
        }
        relativePath(source['directory'] as String? ?? '');
        for (final root in strings(source['roots'] ?? [''])) {
          relativePath(root);
        }
        if ((source['ref'] as String? ?? '').trim().isEmpty) {
          throw const FormatException('Repository reference is required');
        }
        final commit = source['commit'];
        if (commit != null &&
            !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit as String)) {
          throw const FormatException('Invalid cached commit SHA');
        }
      } else if ((source['path'] as String? ?? '').isEmpty) {
        throw const FormatException('Source path is required');
      }
      if (source['entries'] != null) {
        for (final entry in strings(source['entries'])) {
          relativePath(entry, allowEmpty: false);
        }
      }
    }
    strings(data['importRoots']);
  }
  List<Map<String, Object?>> get sources => (data['sources'] as List)
      .map((s) => Map<String, Object?>.from(s as Map))
      .toList();
  List<String> get importRoots => strings(data['importRoots']);
  bool get isEmpty => sources.isEmpty;
  static List<String> strings(Object? value) {
    if (value is! List ||
        value.length > 2048 ||
        value.any((e) => e is! String || e.length > 4096)) {
      throw const FormatException('Expected a list of paths');
    }
    return value.cast<String>().toList();
  }

  factory SourceConfiguration.legacy(
    List<String> files,
    List<String> folders,
  ) => SourceConfiguration({
    'version': 1,
    'sources': [
      for (final file in files) {'type': 'file', 'path': file},
      for (final folder in folders) {'type': 'directory', 'path': folder},
    ],
    'importRoots': <String>[],
  });
  static SourceConfiguration fromRecord(Map<String, Object?> record) {
    if (record['sourceError'] != null) {
      throw FormatException(record['sourceError'].toString());
    }
    final config = record['protoSources'];
    return config is Map
        ? SourceConfiguration(Map<String, Object?>.from(config))
        : SourceConfiguration.legacy(
            strings(record['protoFiles'] ?? []),
            strings(record['protoFolders'] ?? []),
          );
  }
}

String relativePath(String value, {bool allowEmpty = true}) {
  if (value.isEmpty && allowEmpty) return '';
  if (value.isEmpty ||
      value.contains('\\') ||
      value.contains(':') ||
      value.contains('\u0000') ||
      p.posix.isAbsolute(value) ||
      value.split('/').any((s) => s == '..' || s == '.')) {
    throw const FormatException(
      'Repository/import path must stay within its root',
    );
  }
  return value.replaceAll(RegExp(r'/+$'), '');
}

(String, String) repository(String value) {
  if (!RegExp(r'^https://github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$')
      .hasMatch(value)) {
    throw const FormatException(
      'Use a public GitHub HTTPS repository URL without credentials or URL parameters',
    );
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'github.com' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.length != 2) {
    throw const FormatException(
      'Use a public https://github.com/owner/repository URL without credentials',
    );
  }
  final owner = uri.pathSegments[0];
  final name = uri.pathSegments[1].replaceFirst(RegExp(r'\.git$'), '');
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(owner) ||
      !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name) ||
      name == '.' ||
      name == '..') {
    throw const FormatException('Invalid GitHub repository name');
  }
  return (owner, name);
}

class SourceOperation {
  bool cancelled = false;
  int scanned = 0;
  final _cancelSignal = Completer<void>();
  final _cancelCallbacks = <void Function()>[];
  final clock = Stopwatch()..start();
  final void Function(String)? onProgress;
  SourceOperation({this.onProgress});
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _cancelSignal.complete();
    for (final callback in List<void Function()>.of(_cancelCallbacks)) {
      callback();
    }
  }

  void onCancel(void Function() callback) {
    _cancelCallbacks.add(callback);
    if (cancelled) callback();
  }

  void removeCancel(void Function() callback) =>
      _cancelCallbacks.remove(callback);
  Future<T> wait<T>(Future<T> work) => Future.any([
    work,
    _cancelSignal.future.then<T>(
      (_) => throw const FormatException('Source operation cancelled'),
    ),
  ]);
  void check() {
    if (cancelled) throw const FormatException('Source operation cancelled');
    if (clock.elapsed > const Duration(seconds: 90)) {
      throw const FormatException('Source operation exceeded 90 seconds');
    }
  }

  void visit() {
    check();
    if (++scanned > 100000) {
      throw const FormatException('Source scan exceeds 100000 entries');
    }
  }

  void progress(String message) {
    check();
    onProgress?.call(message);
  }
}
