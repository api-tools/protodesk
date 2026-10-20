import 'dart:io';
import 'dart:convert';

import '../persistence/store.dart';
import '../request_options.dart';
import '../schema/proto_loader.dart';
import '../schema/codec.dart';
import '../workflow/preparation.dart';
import '../workflow/preparation_storage.dart';
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
    final definitions = PreparationProfiles({
      'version': 1,
      'environments': [
        {
          'id': 'compiled',
          'name': 'Compiled fixture',
          'variables': {
            'empty': {'bound': true, 'value': ''},
            'nil': {'bound': true, 'value': null},
          },
        },
      ],
      'presets': [],
    });
    final prepared = await prepareRequestInWorker(
      definitions: definitions.encode(),
      body: r'{"value":"${empty}"}',
      metadata: '{}',
      references: '',
      environmentId: 'compiled',
    );
    final codec = ProtoCodec(schema);
    final decoded = codec.decode(
      method.input,
      codec.encode(method.input, jsonDecode(prepared.body)),
    ) as Map;
    if (!decoded.containsKey('value') || decoded['value'] != '') {
      throw StateError(
        'Compiled preparation lost optional empty-string presence',
      );
    }
    final nullValue = await prepareRequestInWorker(
      definitions: definitions.encode(),
      body: r'"${nil}"',
      metadata: '{}',
      references: '',
      environmentId: 'compiled',
    );
    if (nullValue.body != 'null') {
      throw StateError('Compiled preparation lost explicit null');
    }
    final record = store.list('servers').first;
    store.save('servers', {
      ...record,
      'requestProfilesJson': definitions.encode(),
    });
    final sourceTemplate = PreparationTemplate(
      r'{"value":"${empty}"}',
      '{}',
      '',
    );
    PreparationTemplateStore(store)
        .save(record['id'] as String, method.path, sourceTemplate);
    if (PreparationTemplateStore(store)
            .load(record['id'] as String, method.path)!
            .encode() !=
        sourceTemplate.encode()) {
      throw StateError('Compiled reusable template persistence failed');
    }
    final exportedProfiles = PreparationProfiles.decode(
      ((store.exportWorkspace()['servers'] as List).firstWhere(
            (s) => (s as Map)['id'] == record['id'],
          ) as Map)['requestProfilesJson']
          as String,
    );
    final exportedVariables =
        exportedProfiles.environments.single['variables'] as Map;
    if ((exportedVariables['empty'] as Map)['bound'] != false ||
        (exportedVariables['nil'] as Map).containsKey('value')) {
      throw StateError('Compiled preparation safe export lost unbound state');
    }
    if (store.list('history_items').isNotEmpty ||
        store.list('credentials').isNotEmpty) {
      throw StateError('Command check invoked or created credentials');
    }
    stdout.writeln(
      'COMMAND_SMOKE: PASS (AOT isolate, bundled compiler, POSIX/PowerShell round trips, optional empty value, persisted authority/deadline, environment/preset worker, zero network/credential use)',
    );
  } finally {
    credentials.dispose();
    store.close();
  }
}
