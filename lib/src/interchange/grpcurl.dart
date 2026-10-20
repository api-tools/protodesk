import 'dart:convert';
import 'dart:isolate';

import '../endpoint.dart';
import '../persistence/store.dart';
import '../sources/configuration.dart';
import 'shell.dart';

const redactedCommandBody = '__PROTODESK_REDACTED_BODY__';
const redactedCommandHeader = '__PROTODESK_REDACTED_HEADER__';

/// Literal request configuration only. Parsing performs no I/O and cannot
/// execute a command, connect a server, read an environment or load a file.
class GrpcurlCommand {
  final String address, fullMethod, body;
  final bool tls, reflection;
  final String caFile, certificateFile, keyFile, serverName, authority;
  final int? timeoutMs;
  final List<String> files, roots, warnings;
  final Map<String, String> rpcHeaders, reflectionHeaders;
  GrpcurlCommand._({
    required this.address,
    required this.fullMethod,
    required this.body,
    required this.tls,
    required this.reflection,
    required this.caFile,
    required this.certificateFile,
    required this.keyFile,
    required this.serverName,
    required this.authority,
    required this.timeoutMs,
    required this.files,
    required this.roots,
    required this.rpcHeaders,
    required this.reflectionHeaders,
    required this.warnings,
  });

  factory GrpcurlCommand.parse(String text, CommandShell shell) {
    final tokens = literalCommand(text, shell);
    if (tokens.isEmpty ||
        ![
          'grpcurl',
          'grpcurl.exe',
        ].contains(tokens.first.split(RegExp(r'[/\\]')).last.toLowerCase())) {
      throw const CommandSyntax(
        'Start with grpcurl. Shell prefixes, pipelines and scripts are unsupported.',
      );
    }
    final values = <String, List<String>>{};
    final flags = <String, bool>{};
    const scalar = {
      'd',
      'cacert',
      'cert',
      'key',
      'servername',
      'authority',
      'max-time',
      'format',
    };
    const multiple = {
      'H',
      'rpc-header',
      'reflect-header',
      'proto',
      'import-path',
    };
    const booleans = {'plaintext', 'use-reflection'};
    var i = 1;
    for (; i < tokens.length; i++) {
      final token = tokens[i];
      if (token == '--') {
        i++;
        break;
      }
      if (!token.startsWith('-')) break;
      final pair = token.replaceFirst(RegExp(r'^--?'), '').split('=');
      final name = pair.first;
      final inline = pair.length > 1 ? pair.skip(1).join('=') : null;
      if (booleans.contains(name)) {
        if (flags.containsKey(name) ||
            (inline != null && !['true', 'false'].contains(inline))) {
          throw const CommandSyntax(
            'Boolean flags require a single true/false value using =.',
          );
        }
        flags[name] = inline != 'false';
        continue;
      }
      if (!scalar.contains(name) && !multiple.contains(name)) {
        throw const CommandSyntax(
          'Unsupported grpcurl flag. Only JSON RPCs, TLS file references, authority, deadlines, headers and proto/import paths are supported. No flag or command contents are silently ignored.',
        );
      }
      if (scalar.contains(name) && values.containsKey(name)) {
        throw const CommandSyntax(
          'Repeated scalar flags are unsupported; keep one value.',
        );
      }
      final String value;
      if (inline != null) {
        value = inline;
      } else {
        if (++i == tokens.length) {
          throw const CommandSyntax('A flag is missing its value.');
        }
        value = tokens[i];
      }
      values.putIfAbsent(name, () => []).add(value);
    }
    final positional = tokens.skip(i).toList();
    if (positional.length != 2) {
      throw const CommandSyntax(
        'Provide exactly one host:port endpoint and one package.Service/Method. list/describe and additional commands are unsupported.',
      );
    }
    final address = positional[0];
    try {
      parseServerAddress(address);
    } catch (_) {
      throw const CommandSyntax(
        'Use one host:port endpoint. Unix sockets, credentials, URLs and paths are unsupported.',
      );
    }
    final method = positional[1].replaceFirst(RegExp(r'^/'), '');
    if (!RegExp(
      r'^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*/[A-Za-z_][A-Za-z0-9_]*$',
    ).hasMatch(method)) {
      throw const CommandSyntax(
        'Use package.Service/Method for an RPC. Discovery verbs and dotted method syntax are unsupported.',
      );
    }
    String one(String name, [String fallback = '']) =>
        values[name]?.single ?? fallback;
    if (one('format', 'json') != 'json') {
      throw const CommandSyntax('Only Protobuf JSON input is supported.');
    }
    final body = one('d', '{}');
    if (body == redactedCommandBody) {
      throw const CommandSyntax(
        'This is a redacted preview. Replace omitted values with real JSON/headers before import.',
      );
    }
    if (body.startsWith('@')) {
      throw const CommandSyntax(
        'stdin and file input are unsupported. Paste a single literal JSON value using -d.',
      );
    }
    try {
      jsonDecode(body);
    } catch (_) {
      throw const CommandSyntax(
        'Request data must be one valid JSON value; sensitive contents are omitted from this error.',
      );
    }
    final tls = flags['plaintext'] != true;
    final ca = one('cacert'), cert = one('cert'), key = one('key');
    for (final path in [
      ca,
      cert,
      key,
      ...values['proto'] ?? <String>[],
      ...values['import-path'] ?? <String>[],
    ]) {
      if (path.length > 8192 ||
          path.contains('-----BEGIN') ||
          path.codeUnits.any((c) => c < 32 || c == 127)) {
        throw const CommandSyntax(
          'Schema/TLS options must contain supported file paths, never PEM contents or control characters.',
        );
      }
    }
    if (cert.isEmpty != key.isEmpty) {
      throw const CommandSyntax(
        'Client authentication requires both -cert and -key.',
      );
    }
    final suppliedName = one('servername'),
        suppliedAuthority = one('authority');
    if (!tls && [ca, cert, key, suppliedName].any((v) => v.isNotEmpty)) {
      throw const CommandSyntax(
        'TLS options with -plaintext are unsupported. Remove them or enable TLS; they will not be silently ignored.',
      );
    }
    if (tls &&
        suppliedName.isNotEmpty &&
        suppliedAuthority.isNotEmpty &&
        suppliedName != suppliedAuthority) {
      throw const CommandSyntax(
        'grpcurl does not support different -servername and -authority values.',
      );
    }
    final authority = suppliedAuthority.isNotEmpty
        ? suppliedAuthority
        : suppliedName;
    final derivedName = authority.isNotEmpty
        ? tlsNameForAuthority(authority)
        : '';
    final name = tls ? derivedName : '';
    int? timeout;
    if (values.containsKey('max-time')) {
      final seconds = double.tryParse(one('max-time'));
      if (seconds == null ||
          !seconds.isFinite ||
          seconds <= 0 ||
          seconds > 86400 ||
          (seconds * 1000 - (seconds * 1000).round()).abs() > 0.000001) {
        throw const CommandSyntax(
          'Use a positive -max-time of at most 24 hours with millisecond precision. Unlimited deadlines are unsupported.',
        );
      }
      timeout = (seconds * 1000).round();
    }
    Map<String, String> headers(List<String> raw) {
      final result = <String, String>{};
      for (final header in raw) {
        final colon = header.indexOf(':');
        if (colon <= 0) {
          throw const CommandSyntax('Headers require name: value.');
        }
        final key = header.substring(0, colon).trim().toLowerCase();
        final value = header.substring(colon + 1).trim();
        if (!RegExp(r'^[a-z0-9_.-]+$').hasMatch(key) ||
            key.length > 256 ||
            value.codeUnits.any((c) => c < 32 || c == 127)) {
          throw const CommandSyntax(
            'Invalid metadata name/value; sensitive contents are omitted.',
          );
        }
        if (value == redactedCommandHeader) {
          throw const CommandSyntax(
            'Rebind redacted headers before importing.',
          );
        }
        if (result.containsKey(key)) {
          throw const CommandSyntax(
            'Repeated headers are multi-valued in grpcurl and cannot be represented by one ProtoDesk header. Keep one value per name/context.',
          );
        }
        result[key] = key.endsWith('-bin')
            ? importedBinaryHeader(value)
            : value;
      }
      if (result.length > 128) {
        throw const CommandSyntax(
          'At most 128 headers per context are supported.',
        );
      }
      return result;
    }

    final common = values['H'] ?? <String>[];
    final rpc = headers([...common, ...values['rpc-header'] ?? <String>[]]);
    final reflect = headers([
      ...common,
      ...values['reflect-header'] ?? <String>[],
    ]);
    final files = values['proto'] ?? <String>[],
        roots = values['import-path'] ?? <String>[];
    if (files.length > 2048 || roots.length > 128) {
      throw const CommandSyntax(
        'Too many schema entry points or import roots.',
      );
    }
    final reflection = flags['use-reflection'] ?? files.isEmpty;
    if (!reflection && files.isEmpty) {
      throw const CommandSyntax(
        'Reflection disabled: provide at least one -proto entry point.',
      );
    }
    return GrpcurlCommand._(
      address: address,
      fullMethod: '/$method',
      body: body,
      tls: tls,
      reflection: reflection,
      caFile: ca,
      certificateFile: cert,
      keyFile: key,
      serverName: name,
      authority: authority,
      timeoutMs: timeout,
      files: List.unmodifiable(files),
      roots: List.unmodifiable(roots),
      rpcHeaders: Map.unmodifiable(rpc),
      reflectionHeaders: Map.unmodifiable(reflect),
      warnings: List.unmodifiable([
        if (!values.containsKey('d')) 'No -d was supplied. Draft {} represents an empty ordinary message; verify well-known-type JSON before invoking.',
        if (timeout == null) 'No deadline was supplied. ProtoDesk retains its current RPC timeout.',
        if (timeout != null) 'grpcurl max-time includes connection/discovery; ProtoDesk applies this timeout after Connect to the RPC.',
        if (reflection && files.isNotEmpty) 'grpcurl combines local/reflection descriptors; ProtoDesk uses reflection first with configured local fallback.',
        if (files.isNotEmpty ||
            roots.isNotEmpty ||
            [ca, cert, key].any((v) => v.isNotEmpty))
          'Paths are references only. Grant native picker access on macOS and validate sources before use.',
        if (rpc.isNotEmpty || reflect.isNotEmpty) 'Imported headers are stored literals. Explicitly migrate sensitive values to protected references in Servers.',
      ]),
    );
  }

  Record serverRecord(
    String name, {
    required List<String> resolvedFiles,
    required List<String> resolvedRoots,
  }) => {
    'name': name,
    'address': address,
    'tlsEnabled': tls,
    'tlsCaFile': caFile,
    'tlsClientCertificateFile': certificateFile,
    'tlsClientKeyFile': keyFile,
    'tlsServerName': serverName,
    'httpAuthority': authority,
    'reflectionEnabled': reflection,
    'metadataJson': jsonEncode(rpcHeaders),
    'reflectionMetadataJson': jsonEncode(reflectionHeaders),
    'protoSources': {
      ...SourceConfiguration.legacy(resolvedFiles, []).data,
      'importRoots': resolvedRoots,
    },
  };
}

/// grpcurl uses WithAuthority for both flags and derives the TLS host from it.
/// Preserve that behavior explicitly; ProtoDesk can otherwise separate the two.
String tlsNameForAuthority(String authority) {
  final uri = Uri.tryParse('grpc://$authority');
  if (authority.length > 1024 ||
      uri == null ||
      uri.host.isEmpty ||
      uri.path.isNotEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      authority.codeUnits.any((c) => c <= 32 || c == 127)) {
    throw const CommandSyntax('Invalid authority/server name.');
  }
  return uri.host.startsWith('[')
      ? uri.host.substring(1, uri.host.length - 1)
      : uri.host;
}

/// grpcurl decodes standard/URL-safe padded/raw base64, falling back to the
/// literal UTF-8 bytes. Dart gRPC expects the wire header's base64 string.
String importedBinaryHeader(String value) {
  try {
    if (!RegExp(r'^[A-Za-z0-9+/=_-]*$').hasMatch(value) ||
        (RegExp(r'[+/]').hasMatch(value) && RegExp(r'[-_]').hasMatch(value))) {
      throw const FormatException();
    }
    var normalized = base64.normalize(value);
    final padding = normalized.endsWith('==')
        ? 2
        : normalized.endsWith('=')
        ? 1
        : 0;
    if (padding > 0) {
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      final index = normalized.length - padding - 1;
      final canonical =
          alphabet[alphabet.indexOf(normalized[index]) &
              (padding == 2 ? 48 : 60)];
      normalized = normalized.replaceRange(index, index + 1, canonical);
    }
    return base64.encode(base64.decode(normalized));
  } catch (_) {
    return base64.encode(utf8.encode(value));
  }
}

Future<GrpcurlCommand> parseGrpcurlCommand(String text, CommandShell shell) =>
    Isolate.run(() => GrpcurlCommand.parse(text, shell));
