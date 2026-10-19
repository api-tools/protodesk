// Opt-in live public GitHub acquisition check. Never run this in offline CI.
import 'dart:io';

import 'package:protodesk/src/sources/configuration.dart';
import 'package:protodesk/src/sources/git_provider.dart';
import 'package:protodesk/src/sources/manager.dart';
import 'package:protodesk/src/schema/proto_loader.dart';

class OfflineProvider implements RepositoryProvider {
  @override
  Future<String> resolve(
    String url,
    String reference,
    SourceOperation operation,
  ) async => throw StateError('Unexpected offline network access');
  @override
  Future<void> fetch(
    String url,
    String commit,
    Directory destination,
    SourceOperation operation,
  ) async => throw StateError('Unexpected offline network access');
}

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'protodesk-github-smoke-',
  );
  try {
    final loader = ProtoLoader(
      compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
      standardRoot: 'assets/protoc/include',
    );
    final source = SourceConfiguration({
      'version': 1,
      'sources': [
        {
          'type': 'git',
          'url': 'https://github.com/grpc/grpc-proto',
          'ref': 'master',
          'directory': 'grpc/reflection/v1',
          'roots': [''],
          'entries': ['reflection.proto'],
        },
      ],
      'importRoots': [],
    });
    final manager = SourceManager(loader, RepositoryCache(directory));
    final (validation, manifest) = await manager.validate(
      source,
      SourceOperation(),
    );
    if (validation.schema.methods.isEmpty) {
      throw StateError('Public fixture has no RPC methods');
    }
    stdout.writeln(
      'GitHub acquisition: PASS (${validation.schema.files.length} files; resolved commit ${manifest.configuration.sources.single['commit']})',
    );
    final offline = SourceManager(
      loader,
      RepositoryCache(directory, provider: OfflineProvider()),
    );
    final (cached, _) = await offline.validate(
      manifest.configuration,
      SourceOperation(),
    );
    if (cached.schema.methods.length != validation.schema.methods.length) {
      throw StateError('Offline schema differs');
    }
    stdout.writeln(
      'Offline cached validation with network provider disabled: PASS',
    );
  } finally {
    await directory.delete(recursive: true);
  }
}
