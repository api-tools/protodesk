import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../endpoint.dart';
import '../schema/proto_loader.dart';
import '../schema/schema.dart';
import '../schema/codec.dart';
import '../security/credentials.dart';
import '../security/metadata.dart';
import '../sources/configuration.dart';
import '../sources/discovery.dart';
import '../sources/git_provider.dart';
import '../sources/manager.dart';
import 'grpcurl.dart';
import 'shell.dart';

class GrpcurlPreview {
  final String command;
  final bool sensitive, redacted;
  final List<String> notes;
  GrpcurlPreview(
    this.command, {
    required this.sensitive,
    required this.redacted,
    required this.notes,
  });
}

class _OfflineRepository implements RepositoryProvider {
  const _OfflineRepository();
  @override
  Future<String> resolve(
    String url,
    String reference,
    SourceOperation operation,
  ) async => throw const CommandSyntax(
    'Validate Git sources first. Command export never fetches repositories or reads repository credentials.',
  );
  @override
  Future<void> fetch(
    String url,
    String commit,
    Directory destination,
    SourceOperation operation,
  ) async => throw const CommandSyntax(
    'Validated Git cache is unavailable. Validate sources before exporting their file references.',
  );
}

Future<SourceManifest> commandSourceManifest(
  ProtoLoader loader,
  String databasePath,
  SourceConfiguration configuration,
  SourceOperation operation, {
  ProtoMethod? expectedMethod,
  String? requestBody,
}) async {
  final manager = SourceManager(
    loader,
    RepositoryCache(
      Directory(p.join(p.dirname(databasePath), 'schema-cache')),
      providerForSource: (_) => const _OfflineRepository(),
    ),
  );
  final (validation, manifest) = await manager.validate(
    configuration,
    operation,
  );
  if (expectedMethod != null) {
    final found = validation.schema.methods[expectedMethod.path];
    if (found == null ||
        found.input != expectedMethod.input ||
        found.output != expectedMethod.output ||
        found.clientStreaming != expectedMethod.clientStreaming ||
        found.serverStreaming != expectedMethod.serverStreaming) {
      throw const CommandSyntax(
        'The selected method differs from the local descriptors. Validate/reload sources or select reflection-only export; no settings changed.',
      );
    }
    if (requestBody != null) {
      try {
        ProtoCodec(validation.schema)
            .encode(found.input, jsonDecode(requestBody));
      } catch (_) {
        throw const CommandSyntax(
          'The request is incompatible with the selected local definitions. Reload their schema and review the request fields.',
        );
      }
    }
  }
  return manifest;
}

Future<GrpcurlPreview> exportGrpcurl({
  required Map<String, Object?> server,
  required ProtoMethod method,
  required String body,
  required String requestMetadata,
  required MetadataReferences requestReferences,
  required String authority,
  required int timeoutMs,
  required CommandShell shell,
  required CredentialService credentials,
  SourceManifest? sources,
  bool includeBody = false,
  bool includeLiteralHeaders = false,
  bool includeProtectedHeaders = false,
}) async {
  if (method.clientStreaming) {
    throw const CommandSyntax(
      'Interactive client/bidirectional request sequences cannot be reproduced by this command exporter. Use ProtoDesk streaming controls. Unary and server-stream RPCs are supported.',
    );
  }
  final (host, port) = parseServerAddress(server['address'] as String);
  final tls = server['tlsEnabled'] == true;
  final reflection = server['reflectionEnabled'] != false;
  if (!reflection && (sources == null || sources.entries.isEmpty)) {
    throw const CommandSyntax(
      'Reflection is disabled. Include validated local/cached proto references.',
    );
  }
  final profileAuthority = (server['httpAuthority'] as String? ?? '').isNotEmpty
      ? server['httpAuthority'] as String
      : grpcAuthority(host, port);
  final commandAuthority = authority.isEmpty ? profileAuthority : authority;
  if (reflection &&
      commandAuthority.toLowerCase() != profileAuthority.toLowerCase()) {
    throw const CommandSyntax(
      'grpcurl uses one authority for reflection and the RPC. This ProtoDesk call override cannot be exported with separate reflection routing. Select validated local descriptors without reflection; settings are unchanged.',
    );
  }
  final configuredSni = (server['tlsServerName'] as String? ?? '').trim();
  final desiredName = configuredSni.isNotEmpty
      ? configuredSni
      : authority.isNotEmpty
      ? authority
      : host;
  final cliName = tlsNameForAuthority(commandAuthority);
  String bareHost(String name) => name.startsWith('[') && name.endsWith(']')
      ? name.substring(1, name.length - 1)
      : name;
  if (tls &&
      bareHost(desiredName).toLowerCase() != bareHost(cliName).toLowerCase()) {
    throw const CommandSyntax(
      'grpcurl couples TLS server name and HTTP/2 authority. This independent ProtoDesk combination cannot be exported faithfully; your settings are unchanged.',
    );
  }
  if (includeBody &&
      (body.length > 4 * 1024 * 1024 ||
          utf8.encode(body).length > 4 * 1024 * 1024)) {
    throw const CommandSyntax(
      'Included JSON exceeds the 4 MiB command interchange limit.',
    );
  }
  if (includeBody) {
    try {
      jsonDecode(body);
    } catch (_) {
      throw const CommandSyntax(
        'Fix invalid request JSON before including the body.',
      );
    }
  }
  final plan = MetadataPlan.rpc(server, requestMetadata, requestReferences);
  final reflect = reflection
      ? MetadataPlan.reflection(server)
      : MetadataPlan({}, MetadataReferences({}));
  final scope = CredentialScope.metadata(
    server['address'] as String,
    tls: tls,
    serverName: configuredSni,
    authority: authority,
    caFileReference: server['tlsCaFile'] as String? ?? '',
    httpAuthority: server['httpAuthority'] as String? ?? '',
  );
  // Reflection uses the profile's authority, independently of call overrides.
  final reflectionScope = CredentialScope.metadata(
    server['address'] as String,
    tls: tls,
    serverName: configuredSni,
    caFileReference: server['tlsCaFile'] as String? ?? '',
    httpAuthority: server['httpAuthority'] as String? ?? '',
  );
  Future<Map<String, String>> headers(
    MetadataPlan value,
    CredentialScope recipient,
  ) async => {
    for (final entry in value.literals.entries)
      entry.key: includeLiteralHeaders ? entry.value : redactedCommandHeader,
    for (final entry in value.references.headers.entries)
      entry.key: includeProtectedHeaders
          ? await credentials.resolve(entry.value, recipient)
          : redactedCommandHeader,
  };
  if (plan.literals.length + plan.references.headers.length > 128 ||
      reflect.literals.length + reflect.references.headers.length > 128) {
    throw const CommandSyntax(
      'Command interchange supports at most 128 metadata headers per context.',
    );
  }
  final rpcHeaders = await headers(plan, scope);
  final reflectionHeaders = await headers(reflect, reflectionScope);
  for (final entry in [...rpcHeaders.entries, ...reflectionHeaders.entries]) {
    if (entry.key.length > 256 ||
        entry.value.length > 64 * 1024 ||
        utf8.encode(entry.value).length > 64 * 1024 ||
        !RegExp(r'^[a-z0-9_.-]+$').hasMatch(entry.key) ||
        entry.value.codeUnits.any((c) => c < 32 || c == 127)) {
      throw const CommandSyntax(
        'Repair invalid metadata before command export; sensitive contents omitted.',
      );
    }
    if (entry.key.endsWith('-bin') && entry.value != redactedCommandHeader) {
      try {
        if (!RegExp(r'^[A-Za-z0-9+/=]*$').hasMatch(entry.value)) {
          throw const FormatException();
        }
        base64.decode(base64.normalize(entry.value));
      } catch (_) {
        throw const CommandSyntax(
          'Binary metadata must contain valid wire base64 for command export. Existing metadata is unchanged.',
        );
      }
    }
  }
  if (timeoutMs > 86400000) {
    throw const CommandSyntax(
      'The command interchange deadline limit is 24 hours. Existing call options are unchanged.',
    );
  }
  final pieces = ['grpcurl'];
  var argumentCount = 1;
  void flag(String name, [String? value]) {
    pieces.add(name);
    argumentCount++;
    if (value != null) {
      pieces.add(quoteArgument(value, shell));
      argumentCount++;
    }
  }

  if (!tls) flag('-plaintext');
  if (tls) {
    for (final pair in [
      ('-cacert', 'tlsCaFile'),
      ('-cert', 'tlsClientCertificateFile'),
      ('-key', 'tlsClientKeyFile'),
    ]) {
      final path = server[pair.$2] as String? ?? '';
      if (path.isNotEmpty) flag(pair.$1, path);
    }
  }
  flag('-authority', commandAuthority);
  if (sources != null) {
    for (final root in sources.roots) {
      flag('-import-path', root);
    }
    for (final file in sources.entries) {
      flag('-proto', file);
    }
  }
  flag('-use-reflection=$reflection');
  flag('-max-time', ((timeoutMs > 0 ? timeoutMs : 5000) / 1000).toString());
  for (final name in rpcHeaders.keys.toList()..sort()) {
    flag('-rpc-header', '$name: ${rpcHeaders[name]}');
  }
  for (final name in reflectionHeaders.keys.toList()..sort()) {
    flag('-reflect-header', '$name: ${reflectionHeaders[name]}');
  }
  flag('-d', includeBody ? body : redactedCommandBody);
  pieces.add(quoteArgument(server['address'] as String, shell));
  pieces.add(quoteArgument(method.path.replaceFirst(RegExp(r'^/'), ''), shell));
  argumentCount += 2;
  final command = pieces.join(' ');
  if (command.length > 4 * 1024 * 1024 ||
      utf8.encode(command).length > 4 * 1024 * 1024 ||
      argumentCount > 4096) {
    throw const CommandSyntax(
      'Command exceeds the 4 MiB / 4096 argument interchange limit. Reduce included data or schema entries.',
    );
  }
  final redacted =
      !includeBody ||
      rpcHeaders.values.contains(redactedCommandHeader) ||
      reflectionHeaders.values.contains(redactedCommandHeader);
  return GrpcurlPreview(
    command,
    sensitive:
        includeBody ||
        (includeLiteralHeaders &&
            (plan.literals.isNotEmpty || reflect.literals.isNotEmpty)) ||
        (includeProtectedHeaders &&
            (plan.references.headers.isNotEmpty ||
                reflect.references.headers.isNotEmpty)),
    redacted: redacted,
    notes: [
      if (shell == CommandShell.powershell) 'Requires PowerShell 7.3+ with Standard/Windows native argument passing. Windows PowerShell 5.1 and Legacy mode are unsupported.',
      if (!includeBody) 'Redacted preview: the body placeholder is intentionally invalid JSON. Replace omitted values before running or importing.',
      if (redacted) 'Redacted header placeholders must be rebound; they are not authentication values.',
      if (includeBody || includeLiteralHeaders || includeProtectedHeaders) 'Included data may contain payloads or reusable credentials. Clipboard contents are local, but copying them elsewhere can disclose that data.',
      if (sources != null && sources.entries.isNotEmpty) 'Proto/import paths are local references and must exist on the computer running grpcurl.',
      if (reflection && sources != null && sources.entries.isNotEmpty) 'grpcurl combines local/reflection descriptors; ProtoDesk uses reflection first with local fallback.',
      'grpcurl max-time includes connection/discovery; ProtoDesk starts the RPC timeout after Connect.',
    ],
  );
}

/// Resolve only user-requested local references. No source content is read,
/// fetched or compiled; real schema validation remains an explicit operation.
Future<Map<String, Object?>> commandServerRecord(
  GrpcurlCommand command,
  String name,
  SourceOperation operation, {
  String? baseDirectory,
}) async {
  String absolute(String value) {
    if (value.startsWith(r'\\') || value.startsWith('//')) {
      throw const CommandSyntax(
        'UNC/network paths are unsupported in command import. Select a trusted source with the native picker instead.',
      );
    }
    if (!Platform.isWindows && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
      throw const CommandSyntax(
        'Windows paths cannot be imported on this platform. Replace them with local paths.',
      );
    }
    if (p.isAbsolute(value)) return p.normalize(value);
    if (baseDirectory == null) {
      throw const CommandSyntax(
        'Choose the command working directory to resolve relative paths.',
      );
    }
    final root = p.normalize(p.absolute(baseDirectory));
    final result = p.normalize(p.join(root, value));
    if (!p.equals(root, result) && !p.isWithin(root, result)) {
      throw const CommandSyntax(
        'Relative path escapes the selected working directory. Select a containing directory and adjust the command.',
      );
    }
    return result;
  }

  final roots = command.roots.map(absolute).toList();
  final files = <String>[];
  for (final path in command.files) {
    operation.check();
    if (p.isAbsolute(path) ||
        p.windows.isAbsolute(path) ||
        path.startsWith(r'\\')) {
      files.add(absolute(path));
      continue;
    }
    String? resolved;
    for (final root in roots) {
      operation.check();
      final rootType = await FileSystemEntity.type(root, followLinks: false);
      if (rootType == FileSystemEntityType.link) {
        throw const CommandSyntax('Unsafe import-root symlink.');
      }
      if (rootType != FileSystemEntityType.directory) continue;
      final canonicalRoot = await safePath(root, directory: true);
      final candidate = p.normalize(p.join(canonicalRoot, path));
      if (!p.isWithin(canonicalRoot, candidate)) {
        throw const CommandSyntax('Proto entry escapes its import root.');
      }
      final type = await FileSystemEntity.type(candidate, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const CommandSyntax('Unsafe proto entry symlink.');
      }
      if (type == FileSystemEntityType.file) {
        resolved = await safePath(candidate, directory: false);
        if (!p.isWithin(canonicalRoot, resolved)) {
          throw const CommandSyntax(
            'Resolved proto entry escapes its import root.',
          );
        }
        break;
      }
    }
    files.add(resolved ?? absolute(path));
  }
  String tlsPath(String path) => path.isEmpty ? '' : absolute(path);
  return {
    ...command.serverRecord(name, resolvedFiles: files, resolvedRoots: roots),
    'tlsCaFile': tlsPath(command.caFile),
    'tlsClientCertificateFile': tlsPath(command.certificateFile),
    'tlsClientKeyFile': tlsPath(command.keyFile),
  };
}
