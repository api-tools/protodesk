import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:path/path.dart' as p;
import 'package:protodesk/src/interchange/export.dart';
import 'package:protodesk/src/interchange/grpcurl.dart';
import 'package:protodesk/src/interchange/shell.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/schema/proto_loader.dart';
import 'package:protodesk/src/security/catalog.dart';
import 'package:protodesk/src/security/credentials.dart';

import 'fixtures/credential_vault.dart';
import 'mtls_test.dart'
    show RequiredClientCredentials, MetadataReflection, CapturedFixture;

void main() {
  final executable = Platform.environment['GRPCURL'];
  test(
    'opt-in installed grpcurl executes exported argv and POSIX quoting against the local mTLS fixture',
    () async {
      final loader = ProtoLoader(
        compiler: Platform.environment['PROTOC'] ?? 'assets/protoc/bin/protoc',
        standardRoot: 'assets/protoc/include',
      );
      final schema = await loader.load(['test/fixtures/runtime.proto'], []);
      final reflection = MetadataReflection(schema),
          fixture = CapturedFixture(schema);
      final server = Server.create(services: [reflection, fixture]);
      await server.serve(
        address: InternetAddress.loopbackIPv4,
        port: 0,
        security: RequiredClientCredentials(),
        requireClientCertificate: true,
      );
      final directory = Directory.systemTemp.createTempSync(
        'protodesk-command-cli-',
      );
      final store = WorkspaceStore.open('${directory.path}/data.sqlite');
      final service = CredentialService(
        MemoryVault(),
        SqliteCredentialCatalog(store),
      );
      try {
        final profile = <String, Object?>{
          'address': '127.0.0.1:${server.port}',
          'tlsEnabled': true,
          'tlsServerName': 'localhost',
          'httpAuthority': 'localhost',
          'tlsCaFile': p.absolute('test/fixtures/mtls/ca.pem'),
          'tlsClientCertificateFile': p.absolute(
            'test/fixtures/mtls/client-chain.pem',
          ),
          'tlsClientKeyFile': p.absolute('test/fixtures/mtls/client-key.pem'),
          'reflectionEnabled': true,
          'metadataJson': '{"x-test":"CLI literal"}',
          'reflectionMetadataJson': '{"x-reflect":"CLI discovery"}',
        };
        final payload = jsonEncode({
          'text': r"Unicode 日本語 'quote' $(printf SHOULD_STAY_LITERAL) `printf SHOULD_STAY_LITERAL` ; & |",
        });
        for (final shell in CommandShell.values) {
          final result = await exportGrpcurl(
            server: profile,
            method: schema.methods['/runtime.fixture.Echo/Unary']!,
            body: payload,
            requestMetadata: '{}',
            requestReferences: MetadataReferences({}),
            authority: '',
            timeoutMs: 5000,
            shell: shell,
            credentials: service,
            includeBody: true,
            includeLiteralHeaders: true,
          );
          final args = literalCommand(result.command, shell).skip(1).toList();
          final process = await Process.run(
            executable!,
            args,
            runInShell: false,
          ).timeout(const Duration(seconds: 15));
          expect(process.exitCode, 0, reason: process.stderr.toString());
          expect(jsonDecode(process.stdout as String), jsonDecode(payload));
          expect(fixture.metadata[':authority'], 'localhost');
          expect(fixture.metadata['x-test'], 'CLI literal');
          expect(fixture.metadata.containsKey('x-reflect'), false);
          expect(
            reflection.seen.every(
              (m) =>
                  m[':authority'] == 'localhost' &&
                  m['x-reflect'] == 'CLI discovery' &&
                  !m.containsKey('x-test'),
            ),
            true,
          );
          if (shell == CommandShell.posix && !Platform.isWindows) {
            // This explicit developer-only check runs our own generated fixture
            // command. The application/parser never executes a shell or grpcurl.
            final command = result.command.replaceFirst(
              'grpcurl',
              quoteArgument(executable, CommandShell.posix),
            );
            final shellResult = await Process.run(
              Platform.isMacOS ? '/bin/zsh' : '/bin/sh',
              ['-f', '-c', command],
              runInShell: false,
            ).timeout(const Duration(seconds: 15));
            expect(
              shellResult.exitCode,
              0,
              reason: shellResult.stderr.toString(),
            );
            expect(
              jsonDecode(shellResult.stdout as String),
              jsonDecode(payload),
            );
          }
        }
        for (final value in [
          'YQ',
          '_w==',
          'Zh==',
          'YQ=',
          '%59Q==',
          'not base64?',
        ]) {
          final args = [
            '-cacert',
            profile['tlsCaFile'] as String,
            '-cert',
            profile['tlsClientCertificateFile'] as String,
            '-key',
            profile['tlsClientKeyFile'] as String,
            '-authority',
            'localhost',
            '-rpc-header',
            'x-bin: $value',
            '-d',
            '{}',
            profile['address'] as String,
            'runtime.fixture.Echo/Unary',
          ];
          final process = await Process.run(
            executable!,
            args,
            runInShell: false,
          ).timeout(const Duration(seconds: 15));
          expect(process.exitCode, 0, reason: process.stderr.toString());
          expect(
            base64.decode(base64.normalize(fixture.metadata['x-bin']!)),
            base64.decode(importedBinaryHeader(value)),
            reason: 'binary payload equivalence; Go may omit base64 padding',
          );
        }
      } finally {
        service.dispose();
        store.close();
        await server.shutdown();
        directory.deleteSync(recursive: true);
      }
    },
    skip: executable == null
        ? 'Set GRPCURL to an installed developer CLI to run the optional local interoperability check.'
        : false,
  );
}
