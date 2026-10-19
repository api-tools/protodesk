import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../sources/configuration.dart';
import '../sources/discovery.dart';
import 'schema.dart';
import 'wire.dart';

class SchemaValidation {
  final SchemaRegistry schema;
  final Map<String, String> resolved;
  final List<String> entryPoints;
  final String output;
  SchemaValidation(this.schema, this.resolved, this.entryPoints, this.output);
  int get dependencies =>
      schema.files.keys.where((f) => !entryPoints.contains(f)).length;
  Map<String, Object?> get metadata => {
    'at': DateTime.now().toUtc().toIso8601String(),
    'files': schema.files.length,
    'dependencies': dependencies,
    'services': schema.services.length,
    'methods': schema.methods.length,
    'warnings': output
        .split('\n')
        .where(
          (line) => RegExp(r'\bwarning\b', caseSensitive: false).hasMatch(line),
        )
        .length,
  };
}

class SchemaDiagnostic extends FormatException {
  final String category, output;
  final List<String> roots;
  final List<String> suggestions;
  SchemaDiagnostic(
    this.category,
    this.output,
    this.roots, {
    this.suggestions = const [],
  }) : super(
         '$category\n$output\nConfigured import roots:\n${roots.join('\n')}\n${category == 'Missing import' ? 'Add the directory containing the imported relative path as an import root.' : 'Review the compiler diagnostics and selected entry points.'}',
       );
}

/// Copies bounded source roots into isolation. Only protoc parses proto syntax.
class ProtoLoader {
  final String compiler, standardRoot;
  ProtoLoader({required this.compiler, required this.standardRoot});
  Future<SchemaRegistry> load(List<String> files, List<String> folders) async =>
      (await validate(
        files,
        [...folders, ...files.map(p.dirname)],
        operation: SourceOperation(),
        discoverFolders: folders,
      )).schema;

  Future<SchemaValidation> validate(
    List<String> files,
    List<String> importRoots, {
    required SourceOperation operation,
    List<String> discoverFolders = const [],
  }) async {
    final roots = <String>[];
    for (final root in importRoots) {
      final canonical = await safePath(root, directory: true);
      if (!roots.contains(canonical)) roots.add(canonical);
    }
    final selected = <String>[...files];
    for (final folder in discoverFolders) {
      for (final name in await FileDiscovery().discover(folder, operation)) {
        selected.add(p.join(folder, name));
      }
    }
    final targets = <String, String>{};
    for (final file in selected) {
      if (!file.endsWith('.proto')) {
        throw const FormatException('Entry points must be .proto files');
      }
      final path = await safePath(file, directory: false);
      final root = roots.where((r) => p.isWithin(r, path)).firstOrNull;
      if (root == null) {
        throw FormatException(
          'Entry point is outside configured import roots: $file',
        );
      }
      final name = p.posix.joinAll(p.split(p.relative(path, from: root)));
      if (targets.containsKey(name) && targets[name] != path) {
        throw FormatException('Duplicate proto import path $name');
      }
      targets[name] = path;
    }
    if (targets.isEmpty) {
      throw const FormatException('Select at least one .proto entry point');
    }
    final standard = await safePath(standardRoot, directory: true);
    final temp = await Directory.systemTemp.createTemp('protodesk-schema-');
    final copied = <String, String>{}, resolved = <String, String>{};
    final portableNames = <String, String>{};
    var bytes = 0;
    try {
      operation.progress('Staging safe schema sources…');
      for (final root in [...roots, standard]) {
        for (final name in await FileDiscovery().discover(root, operation)) {
          operation.check();
          relativePath(name, allowEmpty: false);
          final source = await safePath(p.join(root, name), directory: false);
          if (!p.isWithin(root, source)) {
            throw SchemaDiagnostic(
              'Invalid path',
              '$name escapes its import root',
              roots,
            );
          }
          if (copied.containsKey(name)) {
            if (copied[name] != source && root != standard) {
              throw SchemaDiagnostic(
                'Conflicting import path',
                '$name exists in multiple roots',
                roots,
              );
            }
            continue;
          }
          final previousName = portableNames[name.toLowerCase()];
          if (previousName != null && previousName != name) {
            throw SchemaDiagnostic(
              'Conflicting import path',
              '$name conflicts with $previousName on case-insensitive platforms',
              roots,
            );
          }
          portableNames[name.toLowerCase()] = name;
          final content = await File(source).readAsBytes();
          bytes += content.length;
          if (content.length > SourceLimits.fileBytes ||
              bytes > SourceLimits.totalBytes ||
              copied.length >= SourceLimits.files) {
            throw const FormatException(
              'Schema staging exceeds resource limits',
            );
          }
          final destination = File(p.join(temp.path, name));
          await destination.parent.create(recursive: true);
          await destination.writeAsBytes(content);
          copied[name] = source;
          resolved[name] = root;
        }
      }
      operation.progress('Compiling with bundled protoc…');
      final output = p.join(temp.path, 'descriptor.pb');
      final process = await Process.start(p.absolute(compiler), [
        '--proto_path=${temp.path}',
        '--descriptor_set_out=$output',
        '--include_imports',
        ...targets.keys,
      ], workingDirectory: temp.path);
      final stdoutDone = process.stdout.drain<void>();
      final errors = StringBuffer();
      var errorBytes = 0;
      final stderrDone = process.stderr.transform(utf8.decoder).listen((text) {
        errorBytes += text.length;
        if (errorBytes <= 128 * 1024) {
          errors.write(text);
        } else {
          process.kill();
        }
      }).asFuture<void>();
      final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (operation.cancelled || operation.clock.elapsed.inSeconds > 90) {
          process.kill();
        }
      });
      int code;
      try {
        code = await process.exitCode.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        process.kill();
        await process.exitCode;
        throw SchemaDiagnostic(
          'Compilation timeout',
          'protoc exceeded 10 seconds',
          roots,
        );
      } finally {
        timer.cancel();
      }
      await stdoutDone;
      await stderrDone;
      operation.check();
      final diagnostics = errors.toString();
      if (code != 0) {
        final category = diagnostics.contains('File not found')
            ? 'Missing import'
            : diagnostics.contains('already defined')
            ? 'Conflicting definitions'
            : diagnostics.contains('edition')
            ? 'Unsupported Protobuf feature'
            : 'Invalid Protobuf syntax';
        final suggestions = <String>[];
        if (category == 'Missing import') {
          final missing = RegExp(
            r'^([^:\n]+): File not found\.',
            multiLine: true,
          ).allMatches(diagnostics).map((m) => m[1]!).toList();
          for (final root in roots) {
            var parent = p.dirname(root);
            for (var level = 0; level < 3; level++) {
              for (final name in missing) {
                relativePath(name, allowEmpty: false);
                if (await File(p.join(parent, name)).exists() &&
                    !suggestions.contains(parent)) {
                  suggestions.add(parent);
                }
              }
              parent = p.dirname(parent);
            }
          }
        }
        throw SchemaDiagnostic(
          category,
          diagnostics,
          roots,
          suggestions: suggestions,
        );
      }
      if (await File(output).length() > 64 * 1024 * 1024) {
        throw const FormatException('Descriptor set exceeds 64 MiB');
      }
      final descriptorBytes = await File(output).readAsBytes();
      SchemaRegistry schema;
      try {
        schema = await _decodeDescriptors(descriptorBytes);
      } on FormatException catch (e) {
        throw SchemaDiagnostic(
          'Unsupported Protobuf feature',
          e.message,
          roots,
        );
      }
      final used = <String, String>{};
      for (final file in schema.files.entries) {
        final descriptor = WireReader(file.value).fields();
        used[file.key] = resolved[file.key] ?? 'bundled';
        for (final dependency in descriptor[3] ?? []) {
          final name = utf8.decode(dependency as List<int>);
          used[name] = resolved[name] ?? 'bundled';
        }
      }
      return SchemaValidation(schema, used, targets.keys.toList(), diagnostics);
    } finally {
      await temp.delete(recursive: true);
    }
  }
}

Future<SchemaRegistry> _decodeDescriptors(List<int> bytes) =>
    Isolate.run(() => SchemaRegistry()..addDescriptorSet(bytes));
