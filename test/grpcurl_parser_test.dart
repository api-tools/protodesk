import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/interchange/grpcurl.dart';
import 'package:protodesk/src/interchange/shell.dart';
import 'package:protodesk/src/security/credentials.dart';
import 'package:protodesk/src/security/metadata.dart';

void main() {
  for (final shell in CommandShell.values) {
    test(
      '$shell preserves ProtoJSON, optional empty strings, null and independent headers',
      () {
        const body =
            '{"text":"","nested":{},"value":null,"unicode":"日本語 🚀","text2":"it\'s a : \\"quote\\""}';
        // Quote generated arguments through the same documented shell syntax.
        final command = [
          'grpcurl',
          '-plaintext',
          '-H',
          'x-both: common: value',
          '-rpc-header',
          'x-rpc: application',
          '-reflect-header',
          'x-discovery: reflection',
          '-d',
          body,
          '-max-time',
          '1.25',
          'localhost:80',
          'example.Echo/Call',
        ];
        final parsed = GrpcurlCommand.parse(
          'grpcurl ${command.skip(1).map((v) => quoteArgument(v, shell)).join(' ')}',
          shell,
        );
        expect(parsed.body, body);
        expect(parsed.fullMethod, '/example.Echo/Call');
        expect(parsed.tls, false);
        expect(parsed.timeoutMs, 1250);
        expect(parsed.rpcHeaders, {
          'x-both': 'common: value',
          'x-rpc': 'application',
        });
        expect(parsed.reflectionHeaders, {
          'x-both': 'common: value',
          'x-discovery': 'reflection',
        });
        final record = parsed.serverRecord(
          'Imported',
          resolvedFiles: [],
          resolvedRoots: [],
        );
        expect(jsonDecode(record['metadataJson'] as String), parsed.rpcHeaders);
        expect(
          jsonDecode(record['reflectionMetadataJson'] as String),
          parsed.reflectionHeaders,
        );
      },
    );
  }
  test('TLS identity file references, import roots and reflection flags remain separate', () {
    final parsed = GrpcurlCommand.parse(
      "grpcurl -cacert 'CA chain.pem' -cert client.pem -key client.key -authority 'api.example:443' -proto services/user.proto -import-path proto -use-reflection=false -d '{}' endpoint.example:443 example.Echo/Call",
      CommandShell.posix,
    );
    expect(parsed.serverName, 'api.example');
    expect(parsed.authority, 'api.example:443');
    expect(parsed.certificateFile, 'client.pem');
    expect(parsed.keyFile, 'client.key');
    expect(parsed.files, ['services/user.proto']);
    expect(parsed.roots, ['proto']);
    expect(parsed.reflection, false);
    expect(parsed.warnings.join(' '), contains('Paths are references'));
  });
  test('servername flag also controls grpcurl authority; different explicit values are rejected', () {
    final parsed = GrpcurlCommand.parse(
      'grpcurl -servername tls.example endpoint.example:443 example.Echo/Call',
      CommandShell.posix,
    );
    expect(parsed.serverName, 'tls.example');
    expect(parsed.authority, 'tls.example');
    expect(
      () => GrpcurlCommand.parse(
        'grpcurl -servername tls.example -authority other.example endpoint.example:443 example.Echo/Call',
        CommandShell.posix,
      ),
      throwsA(isA<CommandSyntax>()),
    );
  });
  test(
    'unsupported flags/input fail without echoing sensitive request data',
    () {
      for (final flags in [
        '-insecure',
        '-connect-timeout 3',
        '-d @',
        '-format text',
        '-d synthetic-secret',
        '-max-time 0',
        '-max-time 0.0001',
        '-cert client.pem',
        '-use-reflection=false',
        '-d {} -d {}',
        '-H x:one -rpc-header x:two',
      ]) {
        expect(
          () => GrpcurlCommand.parse(
            'grpcurl $flags localhost:50051 example.Echo/Call',
            CommandShell.posix,
          ),
          throwsA(
            isA<CommandSyntax>().having(
              (e) => e.toString(),
              'redacted',
              isNot(contains('synthetic-secret')),
            ),
          ),
          reason: flags,
        );
      }
    },
  );
  test('binary CLI metadata is normalized to Dart wire base64', () {
    final parsed = GrpcurlCommand.parse(
      "grpcurl -H 'x-bin: YQ' -rpc-header 'y-bin: not base64?' -reflect-header 'z-bin: _w==' -d '{}' localhost:50051 example.Service/Call",
      CommandShell.posix,
    );
    expect(parsed.rpcHeaders['x-bin'], 'YQ==');
    expect(
      parsed.rpcHeaders['y-bin'],
      base64.encode(utf8.encode('not base64?')),
    );
    expect(parsed.reflectionHeaders['z-bin'], '/w==');
    expect(importedBinaryHeader('Zh=='), 'Zg==');
    expect(importedBinaryHeader('YQ='), base64.encode(utf8.encode('YQ=')));
    expect(
      importedBinaryHeader('%59Q=='),
      base64.encode(utf8.encode('%59Q==')),
    );
  });
  test('ordinary JSON strings may contain marker-like text without becoming omitted fields', () {
    final parsed = GrpcurlCommand.parse(
      "grpcurl -d '{\"text\":\"__PROTODESK_REDACTED_HEADER__\"}' localhost:50051 example.Service/Call",
      CommandShell.posix,
    );
    expect(jsonDecode(parsed.body), {'text': redactedCommandHeader});
  });
  test('redacted preview is not accepted as literal authentication or body data', () {
    expect(
      () => GrpcurlCommand.parse(
        'grpcurl -d $redactedCommandBody localhost:50051 example.Echo/Call',
        CommandShell.posix,
      ),
      throwsA(isA<CommandSyntax>()),
    );
    expect(
      () => GrpcurlCommand.parse(
        "grpcurl -H 'authorization: $redactedCommandHeader' localhost:50051 example.Echo/Call",
        CommandShell.posix,
      ),
      throwsA(isA<CommandSyntax>()),
    );
  });
  test(
    'shared metadata precedence matches case-insensitive protected overrides',
    () {
      const id = '11111111-1111-4111-8111-111111111111';
      final server = <String, Object?>{
        'metadataJson': '{"Authorization":"legacy","x-keep":"yes"}',
        'metadataReferencesJson': MetadataReferences({'authorization': id})
            .encode(),
        'reflectionMetadataJson': '{}',
      };
      final rpc = MetadataPlan.rpc(
        server,
        '{"AUTHORIZATION":"request"}',
        MetadataReferences({}),
      );
      expect(rpc.references.headers, isEmpty);
      expect(rpc.literals, {'authorization': 'request', 'x-keep': 'yes'});
      expect(MetadataPlan.reflection(server).literals, isEmpty);
      final protected = MetadataPlan.rpc(server, '{}', MetadataReferences({}));
      expect(protected.references.headers, {'authorization': id});
      expect(protected.literals, {'x-keep': 'yes'});
    },
  );
}
