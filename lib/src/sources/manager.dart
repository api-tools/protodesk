import 'dart:io';

import 'package:path/path.dart' as p;

import '../schema/proto_loader.dart';
import 'configuration.dart';
import 'discovery.dart';
import 'git_provider.dart';
import '../security/credentials.dart';

class SourceManager {
  final ProtoLoader loader;
  final RepositoryCache cache;
  final FileDiscovery discovery;
  SourceManager(this.loader, this.cache, {FileDiscovery? discovery})
    : discovery = discovery ?? FileDiscovery();
  Future<SourceManifest> discover(
    SourceConfiguration configuration,
    SourceOperation operation, {
    bool refresh = false,
  }) async {
    final entries = <String>[], roots = <String>[];
    for (final root in configuration.importRoots) {
      roots.add(await safePath(root, directory: true));
    }
    final found = <int, List<String>>{};
    final available = <String>{}, selectedPaths = <String>{};
    void entry(String path) {
      if (selectedPaths.add(path)) entries.add(path);
      if (entries.length > SourceLimits.files) {
        throw const FormatException('Selected entry points exceed 2048 files');
      }
    }

    void track(Iterable<String> paths) {
      available.addAll(paths);
      if (available.length > SourceLimits.files) {
        throw const FormatException(
          'Combined sources exceed 2048 discovered proto files',
        );
      }
    }

    final sources = configuration.sources;
    for (var i = 0; i < sources.length; i++) {
      operation.progress('Discovering source ${i + 1} of ${sources.length}…');
      final source = sources[i];
      if (source['type'] == 'file') {
        final path = await safePath(source['path'] as String, directory: false);
        track([path]);
        entry(path);
        found[i] = [p.basename(path)];
        // Explicit roots take precedence; file parent is a fallback suggestion.
        if (!roots.any((r) => p.isWithin(p.absolute(r), path))) {
          roots.add(p.dirname(path));
        }
        continue;
      }
      String root;
      if (source['type'] == 'git') {
        final (revision, commit) = await cache.acquire(
          source,
          operation,
          refresh: refresh,
        );
        source['commit'] = commit;
        source['cachedAt'] = (await File(
          p.join(revision.path, '.complete'),
        ).lastModified()).toUtc().toIso8601String();
        root = p.join(revision.path, source['directory'] as String? ?? '');
        for (final include in SourceConfiguration.strings(
          source['roots'] ?? [source['directory'] ?? ''],
        )) {
          roots.add(p.join(revision.path, relativePath(include)));
        }
      } else {
        root = await safePath(source['path'] as String, directory: true);
        // Discovery directory is also an automatically suggested root.
        if (!roots.any(
          (r) =>
              p.equals(p.absolute(r), p.absolute(root)) ||
              p.isWithin(p.absolute(r), p.absolute(root)),
        )) {
          roots.add(root);
        }
      }
      final names = await discovery.discover(root, operation);
      track(names.map((name) => p.join(root, name)));
      found[i] = names;
      final selected = source['entries'] == null
          ? names
          : SourceConfiguration.strings(source['entries']);
      for (final name in selected) {
        if (!names.contains(name)) {
          throw FormatException('Selected entry point no longer exists: $name');
        }
        entry(p.join(root, name));
      }
    }
    return SourceManifest(
      entries,
      roots.toSet().toList(),
      found,
      SourceConfiguration({...configuration.data, 'sources': sources}),
    );
  }

  Future<(SchemaValidation, SourceManifest)> validate(
    SourceConfiguration configuration,
    SourceOperation operation, {
    bool refresh = false,
  }) async {
    final manifest = await discover(configuration, operation, refresh: refresh);
    // Discovery and staging each retain their bounded scan budget.
    operation.scanned = 0;
    final validation = await loader.validate(
      manifest.entries,
      manifest.roots,
      operation: operation,
    );
    operation.check();
    final valid = SourceConfiguration({
      ...manifest.configuration.data,
      'validation': validation.metadata,
    });
    return (
      validation,
      SourceManifest(
        manifest.entries,
        manifest.roots,
        manifest.discovered,
        valid,
      ),
    );
  }

  factory SourceManager.forWorkspace(
    ProtoLoader loader,
    String databasePath, {
    CredentialService? credentials,
  }) => SourceManager(
    loader,
    RepositoryCache(
      Directory(p.join(p.dirname(databasePath), 'schema-cache')),
      providerForSource: credentials == null
          ? null
          : (source) {
              if (source['credentialRef'] == null) return GitHubProvider();
              final (owner, name) = repository(source['url'] as String);
              return AuthenticatedGitHubProvider(
                credentials,
                source['credentialRef'] as String,
                owner,
                name,
              );
            },
    ),
  );
}
