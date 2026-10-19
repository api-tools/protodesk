import 'dart:io';

import 'package:path/path.dart' as p;

import 'configuration.dart';

class SourceLimits {
  static const files = 2048, fileBytes = 4 * 1024 * 1024;
  static const totalBytes = 32 * 1024 * 1024, scanned = 100000;
}

/// Selected links are rejected; canonical roots bound subsequent discovery.
Future<String> safePath(String path, {required bool directory}) async {
  final absolute = p.normalize(p.absolute(path));
  FileSystemEntityType type;
  try {
    type = await FileSystemEntity.type(absolute, followLinks: false);
  } on FileSystemException catch (e) {
    throw FormatException(
      'Permission or path error accessing $path (${e.osError?.errorCode})',
    );
  }
  if (type == FileSystemEntityType.link) {
    throw FormatException('Unsafe symlink: $path');
  }
  if (type !=
      (directory
          ? FileSystemEntityType.directory
          : FileSystemEntityType.file)) {
    throw FormatException(
      'Missing or inaccessible ${directory ? 'directory' : 'file'}: $path',
    );
  }
  return await (directory
      ? Directory(absolute).resolveSymbolicLinks()
      : File(absolute).resolveSymbolicLinks());
}

class FileDiscovery {
  Future<List<String>> discover(String root, SourceOperation operation) async {
    root = await safePath(root, directory: true);
    final names = <String>[];
    var bytes = 0;
    final clock = Stopwatch()..start();
    await for (final entry in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      operation.visit();
      if (clock.elapsed.inSeconds >= 10) {
        throw const FormatException('Proto folder scan exceeded 10 seconds');
      }
      if (entry is Link) throw FormatException('Unsafe symlink: ${entry.path}');
      if (entry is File && entry.path.endsWith('.proto')) {
        final size = await entry.length();
        bytes += size;
        if (size > SourceLimits.fileBytes ||
            bytes > SourceLimits.totalBytes ||
            names.length >= SourceLimits.files) {
          throw const FormatException(
            'Proto sources exceed 2048 files / 4 MiB per file / 32 MiB total',
          );
        }
        names.add(p.posix.joinAll(p.split(p.relative(entry.path, from: root))));
      }
    }
    names.sort();
    return names;
  }
}

class SourceManifest {
  final List<String> entries, roots;
  final Map<int, List<String>> discovered;
  final SourceConfiguration configuration;
  SourceManifest(this.entries, this.roots, this.discovered, this.configuration);
}
