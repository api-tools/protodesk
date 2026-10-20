import 'dart:io';

import '../persistence/store.dart';
import '../request_options.dart';
import '../schema/proto_loader.dart';
import '../security/catalog.dart';
import '../security/credentials.dart';
import '../sources/configuration.dart';
import 'export.dart';
import 'grpcurl.dart';
import 'shell.dart';

class _NoCredentialReads implements CredentialVault {
  @override
  Future<String?> read(String id) async =>
      throw StateError('Unexpected credential read in command smoke');
  @override
  Future<void> write(String id, String value) async =>
      throw StateError('Unexpected credential write in command smoke');
  @override
  Future<void> delete(String id) async =>
      throw StateError('Unexpected credential delete in command smoke');
}

/// Explicit isolated developer check; never runs during normal startup or
/// contacts an endpoint. A pre-existing user database is refused.
Future<void> smokeCommands(
  ProtoLoader loader,
  Directory tools,
  String databasePath,
) async {
  if (Platform.environment['PROTODESK_DATA_DIR'] == null ||
      File(databasePath).existsSync()) {
    throw StateError('Command smoke requires fresh isolated storage');
  }
  final proto = File('${tools.path}/command-smoke.proto');
  await proto.writeAsString(
    'syntax="proto3"; package command.fixture; message Data { optional string value=1; } service Echo { rpc Call(Data) returns(Data); }',
  );
  final config = SourceConfiguration.legacy([proto.path], []);
  final manifest = await commandSourceManifest(
    loader,
    databasePath,
    config,
    SourceOperation(),
  );
  final schema = (await loader.validate(
    manifest.entries,
    manifest.roots,
    operation: SourceOperation(),
  )).schema;
  final method = schema.methods['/command.fixture.Echo/Call']!;
  final store = WorkspaceStore.open(databasePath);
  final credentials = CredentialService(
    _NoCredentialReads(),
    SqliteCredentialCatalog(store),
  );
  try {
    for (final shell in CommandShell.values) {
      final preview = await exportGrpcurl(
        server: {
          'address': 'command-fixture.invalid:443',
          'tlsEnabled': false,
          'reflectionEnabled': false,
          'httpAuthority': 'command.fixture',
          'protoSources': config.data,
          'metadataJson': '{}',
        },
        method: method,
        body: '{"value":""}',
        requestMetadata: '{}',
        requestReferences: MetadataReferences({}),
        authority: '',
        timeoutMs: 1234,
        shell: shell,
        credentials: credentials,
        sources: manifest,
        includeBody: true,
      );
      final parsed = await parseGrpcurlCommand(preview.command, shell);
      if (parsed.body != '{"value":""}' ||
          parsed.authority != 'command.fixture' ||
          parsed.timeoutMs != 1234 ||
          parsed.files.length != 1) {
        throw StateError('Compiled command round trip lost request state');
      }
      final profile = store.save(
        'servers',
        await commandServerRecord(parsed, 'Command check', SourceOperation()),
      );
      final collection = store.save('collections', {'name': 'Command check'});
      final request = store.save('collection_requests', {
        'name': 'Command check',
        'collectionId': collection['id'],
        'serverId': profile['id'],
        'fullMethod': parsed.fullMethod,
        'requestJson': parsed.body,
        'requestOptionsJson': RequestOptions(
          parsed.timeoutMs!,
          parsed.authority,
        ).encode(),
      });
      if (RequestOptions.decode(request['requestOptionsJson'] as String)!
                  .authority !=
              'command.fixture' ||
          profile['httpAuthority'] != 'command.fixture') {
        throw StateError('Compiled command persistence lost options');
      }
    }
    if (store.list('history_items').isNotEmpty ||
        store.list('credentials').isNotEmpty) {
      throw StateError('Command check invoked or created credentials');
    }
    stdout.writeln(
      'COMMAND_SMOKE: PASS (AOT isolate, bundled compiler, POSIX/PowerShell round trips, optional empty value, persisted authority/deadline, zero network/credential use)',
    );
  } finally {
    credentials.dispose();
    store.close();
  }
}
