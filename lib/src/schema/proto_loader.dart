import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'schema.dart';

/// Compiles a copied, validated source graph. protoc never sees user symlinks.
class ProtoLoader {
  final String compiler, standardRoot;
  ProtoLoader({required this.compiler, required this.standardRoot});
  Future<SchemaRegistry> load(List<String> files, List<String> folders) async {
    final deadline = Stopwatch()..start();
    var scanned = 0;
    final roots = <String>[];
    final targets = <String, String>{};
    void add(String name, String path) {
      if (targets.containsKey(name) && targets[name] != path) {
        throw FormatException('Duplicate proto import path $name');
      }
      targets[name] = path;
      if (targets.length > 2048) {
        throw const FormatException('Too many proto files (maximum 2048)');
      }
    }

    for (final folder in folders) {
      final root = await Directory(folder).resolveSymbolicLinks();
      roots.add(root);
      await for (final entry in Directory(
        root,
      ).list(recursive: true, followLinks: false)) {
        if (++scanned > 100000 || deadline.elapsed.inSeconds >= 10) {
          throw const FormatException(
            'Proto folder scan exceeded resource limits',
          );
        }
        if (entry is File && entry.path.endsWith('.proto')) {
          add(
            p.posix.joinAll(p.split(p.relative(entry.path, from: root))),
            entry.path,
          );
        }
      }
    }
    for (final file in files) {
      if (!file.endsWith('.proto')) {
        throw FormatException('Not a .proto file: $file');
      }
      final path = await File(file).resolveSymbolicLinks();
      roots.add(p.dirname(path));
      add(p.basename(path), path);
    }
    if (targets.isEmpty) return SchemaRegistry();
    roots.add(await Directory(standardRoot).resolveSymbolicLinks());
    final temp = await Directory.systemTemp.createTemp('protodesk-schema-');
    try {
      var total = 0;
      final visited = <String>{};
      Future<void> copy(String name, [String? explicit]) async {
        if (p.posix.isAbsolute(name) ||
            name.contains('\\') ||
            name.split('/').contains('..') ||
            name.contains(':')) {
          throw FormatException('Unsafe proto import: $name');
        }
        if (deadline.elapsed.inSeconds >= 10) {
          throw const FormatException('Proto loading exceeded 10 seconds');
        }
        if (!visited.add(name)) return;
        if (visited.length > 2048) {
          throw const FormatException('Import graph exceeds 2048 files');
        }
        String? source = explicit;
        if (source == null) {
          for (final root in roots) {
            final candidate = File(p.join(root, name));
            if (!await candidate.exists()) continue;
            final resolved = await candidate.resolveSymbolicLinks();
            if (!p.isWithin(root, resolved)) {
              throw FormatException('Import escapes its root: $name');
            }
            source = resolved;
            break;
          }
        }
        if (source == null) {
          throw FormatException(
            'Import not found: $name. Add its containing folder.',
          );
        }
        final f = File(source);
        final size = await f.length();
        total += size;
        if (size > 4 * 1024 * 1024 || total > 32 * 1024 * 1024) {
          throw const FormatException('Proto sources exceed resource limits');
        }
        final text = await f.readAsString();
        final imports = _imports(text);
        final destination = File(p.join(temp.path, name));
        await destination.parent.create(recursive: true);
        await destination.writeAsString(text);
        for (final imported in imports) {
          await copy(imported);
        }
      }

      for (final target in targets.entries) {
        await copy(target.key, target.value);
      }
      final output = p.join(temp.path, 'descriptor.pb');
      final process = await Process.start(p.absolute(compiler), [
        '--proto_path=${temp.path}',
        '--descriptor_set_out=$output',
        '--include_imports',
        ...targets.keys.map((name) => p.join(temp.path, name)),
      ], workingDirectory: temp.path);
      final out = process.stdout.drain<void>();
      final error = process.stderr
          .transform(const SystemEncoding().decoder)
          .take(128)
          .join();
      int code;
      try {
        code = await process.exitCode.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        throw const FormatException('Proto compilation exceeded 10 seconds');
      }
      await out;
      final diagnostics = await error;
      if (code != 0) {
        throw FormatException('Proto compilation failed: $diagnostics');
      }
      final schema = SchemaRegistry()
        ..addDescriptorSet(await File(output).readAsBytes());
      return schema;
    } finally {
      await temp.delete(recursive: true);
    }
  }

  List<String> _imports(String source) {
    // Tokenize strings and comments together so comment markers inside strings stay literal.
    final token = RegExp(
      r'/\*[\s\S]*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\b[a-zA-Z_][a-zA-Z_0-9]*\b|;',
      multiLine: true,
    );
    final tokens = token
        .allMatches(source)
        .map((m) => m[0]!)
        .where((t) => !t.startsWith('//') && !t.startsWith('/*'))
        .toList();
    final imports = <String>[];
    for (var i = 0; i < tokens.length; i++) {
      if (tokens[i] != 'import') continue;
      i++;
      if (i < tokens.length && (tokens[i] == 'public' || tokens[i] == 'weak')) {
        i++;
      }
      if (i >= tokens.length || !tokens[i].startsWith('"')) {
        throw const FormatException('Invalid proto import');
      }
      final name = tokens[i].substring(1, tokens[i].length - 1);
      if (name.contains('\\')) {
        throw const FormatException('Escaped proto imports are not allowed');
      }
      imports.add(name);
    }
    return imports;
  }
}
