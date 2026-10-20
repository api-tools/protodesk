import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../endpoint.dart';
import '../request_options.dart';
import '../security/credentials.dart';
import '../security/redaction.dart';
import '../sources/configuration.dart';
import '../workflow/storage.dart';

typedef Record = Map<String, Object?>;

class WorkspaceStore {
  final Database db;
  final String path;
  static const _id = Uuid();
  static const columns = {
    'servers': [
      'name',
      'address',
      'tlsEnabled',
      'tlsCaFile',
      'tlsClientCertificateFile',
      'tlsClientKeyFile',
      'tlsServerName',
      'httpAuthority',
      'reflectionMetadataJson',
      'metadataReferencesJson',
      'reflectionMetadataReferencesJson',
      'reflectionEnabled',
      'protoFilesJson',
      'protoFoldersJson',
      'protoSourcesJson',
      'metadataJson',
      'createdAt',
      'updatedAt',
    ],
    'history_items': [
      'serverId',
      'serverName',
      'serverAddress',
      'serviceName',
      'methodName',
      'fullMethod',
      'requestJson',
      'requestStreamJson',
      'requestMetadataJson',
      'requestCredentialReferencesJson',
      'requestOptionsJson',
      'responseJson',
      'statusCode',
      'statusMessage',
      'durationMs',
      'error',
      'createdAt',
    ],
    'credentials': [
      'name',
      'kind',
      'scopeJson',
      'state',
      'createdAt',
      'updatedAt',
    ],
    'collections': ['name', 'description', 'createdAt', 'updatedAt'],
    'collection_requests': [
      'collectionId',
      'name',
      'serverId',
      'serverName',
      'serverAddress',
      'serviceName',
      'methodName',
      'fullMethod',
      'requestJson',
      'requestStreamJson',
      'requestMetadataJson',
      'requestCredentialReferencesJson',
      'requestOptionsJson',
      'createdAt',
      'updatedAt',
    ],
  };
  WorkspaceStore._(this.db, this.path);
  static String defaultPath() {
    final env = Platform.environment;
    final override = env['PROTODESK_DATA_DIR'];
    if (override != null && override.isNotEmpty) {
      if (!p.isAbsolute(override)) {
        throw const FormatException('PROTODESK_DATA_DIR must be absolute');
      }
      return p.join(override, 'protodesk.sqlite');
    }
    final base = Platform.isMacOS
        ? p.join(env['HOME']!, 'Library', 'Application Support')
        : Platform.isWindows
        ? env['APPDATA']!
        : env['XDG_CONFIG_HOME'] ?? p.join(env['HOME']!, '.config');
    return p.join(base, 'ProtoDesk', 'protodesk.sqlite');
  }

  static WorkspaceStore open(String path, {bool backup = true}) {
    final file = File(path);
    final existing = file.existsSync();
    file.parent.createSync(recursive: true);
    final database = sqlite3.open(path);
    try {
      if (existing && backup) {
        final folder = Directory(p.join(file.parent.path, 'backups'))
          ..createSync();
        final destination = p.join(
          folder.path,
          'flutter-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.sqlite',
        );
        database.execute('VACUUM INTO ?', [destination]);
        if (!Platform.isWindows) Process.runSync('chmod', ['600', destination]);
      }
      database.execute('PRAGMA foreign_keys = ON');
      final store = WorkspaceStore._(database, path);
      store.transaction(() {
        for (final table in columns.entries) {
          final declarations = table.value.map(
            (key) =>
                '${snake(key)} ${key.endsWith('Enabled') || key == 'durationMs' ? 'INTEGER' : 'TEXT'} NOT NULL',
          );
          database.execute(
            'CREATE TABLE IF NOT EXISTS ${table.key} (workspace_id TEXT NOT NULL, id TEXT NOT NULL, ${declarations.join(', ')}, PRIMARY KEY(workspace_id,id)${table.key == 'collection_requests' ? ', FOREIGN KEY(workspace_id,collection_id) REFERENCES collections(workspace_id,id) ON DELETE CASCADE' : ''})',
          );
          final existingReferenceColumns = database
              .select('PRAGMA table_info(${table.key})')
              .map((r) => r['name'])
              .toSet();
          for (final key in [
            'metadataReferencesJson',
            'reflectionMetadataReferencesJson',
            'requestCredentialReferencesJson',
            'requestOptionsJson',
          ]) {
            if (table.value.contains(key) &&
                !existingReferenceColumns.contains(snake(key))) {
              database.execute(
                "ALTER TABLE ${table.key} ADD COLUMN ${snake(key)} TEXT NOT NULL DEFAULT ''",
              );
            }
          }
          if (table.key == 'servers') {
            final existing = database
                .select('PRAGMA table_info(servers)')
                .map((r) => r['name'])
                .toSet();
            for (final name in [
              'tls_client_certificate_file',
              'tls_client_key_file',
              'tls_server_name',
              'http_authority',
              'reflection_metadata_json',
            ]) {
              if (!existing.contains(name)) {
                database.execute(
                  "ALTER TABLE servers ADD COLUMN $name TEXT NOT NULL DEFAULT ''",
                );
              }
            }
          }
          if (table.key == 'servers' &&
              !database
                  .select('PRAGMA table_info(servers)')
                  .any((r) => r['name'] == 'tls_ca_file')) {
            database.execute(
              "ALTER TABLE servers ADD COLUMN tls_ca_file TEXT NOT NULL DEFAULT ''",
            );
          }
          if (table.key == 'servers' &&
              !database
                  .select('PRAGMA table_info(servers)')
                  .any((r) => r['name'] == 'proto_sources_json')) {
            database.execute(
              "ALTER TABLE servers ADD COLUMN proto_sources_json TEXT NOT NULL DEFAULT ''",
            );
          }
          if (table.value.contains('requestStreamJson')) {
            final existingColumns = database
                .select('PRAGMA table_info(${table.key})')
                .map((r) => r['name'])
                .toSet();
            if (!existingColumns.contains('request_stream_json')) {
              database.execute(
                "ALTER TABLE ${table.key} ADD COLUMN request_stream_json TEXT NOT NULL DEFAULT '[]'",
              );
            }
          }
        }
        initializeWorkflowStorage(database);
        for (final row in database.select(
          "SELECT workspace_id,id,proto_files_json,proto_folders_json FROM servers WHERE proto_sources_json=''",
        )) {
          try {
            final config = SourceConfiguration.legacy(
              SourceConfiguration.strings(
                jsonDecode(row['proto_files_json'] as String),
              ),
              SourceConfiguration.strings(
                jsonDecode(row['proto_folders_json'] as String),
              ),
            );
            database.execute(
              'UPDATE servers SET proto_sources_json=? WHERE workspace_id=? AND id=?',
              [jsonEncode(config.data), row['workspace_id'], row['id']],
            );
          } catch (_) {
            /* Keep malformed legacy JSON intact for recovery. */
          }
        }
      });
      return store;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  static String snake(String key) =>
      key.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
  static String camel(String key) =>
      key.replaceAllMapped(RegExp('_([a-z])'), (m) => m[1]!.toUpperCase());
  T transaction<T>(T Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<Record> list(String table) {
    _check(table);
    final rows = db.select(
      'SELECT * FROM $table WHERE workspace_id = ? ORDER BY ${table == 'history_items' ? 'created_at' : 'updated_at'} DESC',
      ['local'],
    );
    return rows.map((row) => _read(table, row)).toList();
  }

  Record _read(String table, Row row) {
    final record = <String, Object?>{
      for (final e in row.entries) camel(e.key): e.value,
    };
    if (table == 'servers') {
      for (final key in ['tlsEnabled', 'reflectionEnabled']) {
        record[key] = record[key] == 1;
      }
      final errors = <String>[];
      for (final key in ['protoFiles', 'protoFolders']) {
        final raw = record['${key}Json'] as String;
        try {
          record[key] = SourceConfiguration.strings(jsonDecode(raw));
          record.remove('${key}Json');
        } catch (_) {
          record[key] = <String>[];
          errors.add(
            'Saved $key is malformed. Original data is preserved; repair this source configuration.',
          );
        }
      }
      final raw = record['protoSourcesJson'] as String;
      try {
        final config = raw.isEmpty
            ? SourceConfiguration.legacy(
                (record['protoFiles'] as List).cast<String>(),
                (record['protoFolders'] as List).cast<String>(),
              )
            : SourceConfiguration(
                Map<String, Object?>.from(jsonDecode(raw) as Map),
              );
        record['protoSources'] = config.data;
        record.remove('protoSourcesJson');
      } catch (e) {
        errors.add('Saved proto sources require repair: $e');
      }
      if (errors.isNotEmpty) record['sourceError'] = errors.join('\n');
    }
    if (table == 'collections') {
      record['requests'] = list('collection_requests')
          .where((r) => r['collectionId'] == record['id'])
          .toList();
    }
    return record;
  }

  Record save(String table, Record input) {
    _check(table);
    final now = DateTime.now().toUtc().toIso8601String();
    final record = <String, Object?>{
      'workspaceId': 'local',
      'id': input['id'] ?? _id.v4(),
      ...input,
    };
    record['workspaceId'] = 'local';
    if (input.containsKey('id') &&
        db.select('SELECT id FROM $table WHERE workspace_id=? AND id=?', [
          'local',
          input['id'],
        ]).isEmpty) {
      throw const FormatException('Record no longer exists');
    }
    for (final key in [
      'name',
      'address',
      'description',
      'serverAddress',
      'fullMethod',
      'statusCode',
    ]) {
      if (record[key] is String) record[key] = (record[key] as String).trim();
    }
    for (final key in [
      'metadataJson',
      'requestJson',
      'requestStreamJson',
      'requestMetadataJson',
      'responseJson',
    ]) {
      if (columns[table]!.contains(key)) {
        final value = record[key]?.toString().trim() ?? '';
        record[key] = value.isEmpty
            ? (key == 'requestStreamJson' ? '[]' : '{}')
            : value;
        final decoded = key.toLowerCase().endsWith('metadatajson')
            ? parseLiteralMetadata(record[key] as String)
            : jsonDecode(record[key] as String);
        if (key == 'requestStreamJson' &&
            (decoded is! List ||
                decoded.length > 1000 ||
                utf8.encode(record[key] as String).length > 64 * 1024 * 1024)) {
          throw const FormatException(
            'Streaming requests must be an array of at most 1000 messages / 64 MiB',
          );
        }
      }
    }
    for (final key in [
      'metadataReferencesJson',
      'reflectionMetadataReferencesJson',
      'requestCredentialReferencesJson',
    ]) {
      if (columns[table]!.contains(key)) {
        MetadataReferences.decode(record[key] as String?);
      }
    }
    if (columns[table]!.contains('requestOptionsJson')) {
      RequestOptions.decode(record['requestOptionsJson'] as String?);
    }
    if (table == 'credentials') {
      CredentialScope.decode(jsonDecode(record['scopeJson'] as String));
      if (!['pending', 'ready', 'unavailable'].contains(record['state'])) {
        throw CredentialFailure.invalid;
      }
    }
    if (table == 'history_items' &&
        [
          'serverAddress',
          'fullMethod',
          'statusCode',
        ].any((k) => (record[k] ?? '') == '')) {
      throw const FormatException(
        'History requires server address, method, and status',
      );
    }
    if (table == 'collection_requests' &&
        ['collectionId', 'fullMethod'].any((k) => (record[k] ?? '') == '')) {
      throw const FormatException(
        'Saved request requires collection and method',
      );
    }
    record['createdAt'] ??= now;
    if (table != 'history_items') record['updatedAt'] = now;
    if (table == 'servers') {
      if ((record['name'] ?? '').toString().trim().isEmpty ||
          (record['address'] ?? '').toString().trim().isEmpty) {
        throw const FormatException('Server name and address are required');
      }
      parseServerAddress(record['address'] as String);
      validateGrpcAuthority(record['httpAuthority'] as String? ?? '');
      for (final key in ['protoFiles', 'protoFolders']) {
        if (record[key] == null && record['${key}Json'] != null) {
          record[key] = SourceConfiguration.strings(
            jsonDecode(record['${key}Json'] as String),
          );
        }
      }
      if (record['protoSources'] == null &&
          (record['protoSourcesJson'] as String? ?? '').isNotEmpty) {
        record['protoSources'] = SourceConfiguration(
          Map<String, Object?>.from(
            jsonDecode(record['protoSourcesJson'] as String) as Map,
          ),
        ).data;
      }
      if (record['sourceError'] != null) {
        throw const FormatException(
          'Repair the saved proto source configuration before saving. Original data remains intact.',
        );
      }
      record['protoSources'] = SourceConfiguration.fromRecord(record).data;
      for (final key in [
        'tlsClientCertificateFile',
        'tlsClientKeyFile',
        'tlsServerName',
      ]) {
        final text = record[key] as String? ?? '';
        if (text.contains('-----BEGIN') ||
            text.contains('\n') ||
            text.contains('\r') ||
            text.contains('\x00') ||
            text.length > 8192) {
          throw const FormatException(
            'TLS settings must contain file references or a server name, never PEM contents',
          );
        }
      }
      final reflection = (record['reflectionMetadataJson'] as String? ?? '')
          .trim();
      record['reflectionMetadataJson'] = reflection;
      if (reflection.isNotEmpty) {
        parseLiteralMetadata(reflection);
      }
      parseLiteralMetadata(record['metadataJson'] as String? ?? '{}');
    }
    if ((table == 'collections' || table == 'collection_requests') &&
        (record['name'] ?? '').toString().trim().isEmpty) {
      throw const FormatException('Name is required');
    }
    final keys = ['workspaceId', 'id', ...columns[table]!];
    final values = keys.map((key) {
      if (key == 'protoSourcesJson') return jsonEncode(record['protoSources']);
      if (key == 'protoFilesJson' || key == 'protoFoldersJson') {
        return jsonEncode(record[key.substring(0, key.length - 4)] ?? []);
      }
      if (key.endsWith('Enabled')) return record[key] == true ? 1 : 0;
      return record[key] ?? (key == 'durationMs' ? 0 : '');
    }).toList();
    db.execute(
      'INSERT INTO $table (${keys.map(snake).join(',')}) VALUES (${keys.map((_) => '?').join(',')}) ON CONFLICT(workspace_id,id) DO UPDATE SET ${columns[table]!.where((k) => k != 'createdAt').map((k) => '${snake(k)}=excluded.${snake(k)}').join(',')}',
      values,
    );
    return list(table).firstWhere((r) => r['id'] == record['id']);
  }

  void delete(String table, String id) {
    _check(table);
    transaction(() {
      if (table == 'collections') {
        db.execute(
          'DELETE FROM collection_requests WHERE workspace_id=? AND collection_id=?',
          ['local', id],
        );
      }
      db.execute('DELETE FROM $table WHERE workspace_id=? AND id=?', [
        'local',
        id,
      ]);
    });
  }

  void clearHistory() =>
      db.execute('DELETE FROM history_items WHERE workspace_id=?', ['local']);

  /// Safe by default. OS credential values are never read for an export.
  /// Full literal/body inclusion is an explicit user choice, not migration.
  Record exportWorkspace({
    bool includeSensitiveLiterals = false,
    bool includeRequestBodies = false,
  }) {
    Record request(Record item) {
      var result = {...item};
      if (!includeSensitiveLiterals) {
        result = exportMetadata(
          result,
          'requestMetadataJson',
          'requestCredentialReferencesJson',
        );
      }
      if (!includeRequestBodies) {
        result['requestJson'] = '{}';
        result['requestStreamJson'] = '[]';
      }
      return result;
    }

    Record server(Record item) {
      if (includeSensitiveLiterals) return item;
      final source = SourceConfiguration.fromRecord(item);
      // Unknown extension data may contain credentials. Preserve it only with
      // explicit inclusion rather than guessing which fields are sensitive.
      const configKeys = {
        'version',
        'sources',
        'importRoots',
        'validation',
        'validationStale',
      };
      const sourceKeys = {
        'id',
        'type',
        'path',
        'url',
        'ref',
        'directory',
        'roots',
        'entries',
        'commit',
        'cachedAt',
        'credentialRef',
      };
      if (source.data.keys.any((k) => !configKeys.contains(k)) ||
          source.sources.any(
            (s) => s.keys.any((k) => !sourceKeys.contains(k)),
          )) {
        throw const FormatException(
          'Source extensions cannot be safely redacted. Review their contents and explicitly include sensitive literals to export them.',
        );
      }
      return exportMetadata(
        exportMetadata(item, 'metadataJson', 'metadataReferencesJson'),
        'reflectionMetadataJson',
        'reflectionMetadataReferencesJson',
      );
    }

    return {
      'kind': 'protodesk.workspace',
      'version': 2,
      'workspaceId': 'local',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'exportPolicy': {
        'sensitiveLiteralsIncluded': includeSensitiveLiterals,
        'requestBodiesIncluded': includeRequestBodies,
      },
      'servers': list('servers').map(server).toList(),
      'collections': list('collections')
          .map(
            (c) => {
              ...c,
              'requests': (c['requests'] as List)
                  .map((r) => request(Map<String, Object?>.from(r as Map)))
                  .toList(),
            },
          )
          .toList(),
    };
  }

  Record importWorkspace(Object? input) {
    if (input is! Map ||
        input['kind'] != 'protodesk.workspace' ||
        ![1, 2].contains(input['version'])) {
      throw const FormatException(
        'Not a supported ProtoDesk workspace (version 1 or 2 required)',
      );
    }
    final servers = input['servers'];
    final collections = input['collections'];
    if (servers is! List ||
        collections is! List ||
        servers.length + collections.length > 10000) {
      throw const FormatException('Invalid workspace records');
    }
    return transaction(() {
      final ids = <Object?, String>{};
      var count = 0;
      for (final server in servers) {
        final data = Map<String, Object?>.from(server as Map);
        _checkImportFields('servers', data);
        final old = data.remove('id');
        data.remove('createdAt');
        data.remove('updatedAt');
        data['name'] = '${data['name']} (imported)';
        final saved = save('servers', data);
        ids[old] = saved['id'] as String;
      }
      for (final collection in collections) {
        final data = Map<String, Object?>.from(collection as Map);
        _checkImportFields('collections', data);
        data.remove('id');
        data.remove('createdAt');
        data.remove('updatedAt');
        data['name'] = '${data['name']} (imported)';
        final requests = data.remove('requests') as List? ?? [];
        final saved = save('collections', data);
        for (final request in requests) {
          final item = Map<String, Object?>.from(request as Map)
            ..remove('id')
            ..remove('createdAt')
            ..remove('updatedAt');
          _checkImportFields('collection_requests', item);
          item['collectionId'] = saved['id'];
          item['serverId'] = ids[item['serverId']] ?? item['serverId'];
          save('collection_requests', item);
          count++;
        }
      }
      return {
        'serverCount': servers.length,
        'collectionCount': collections.length,
        'savedRequestCount': count,
      };
    });
  }

  void _checkImportFields(String table, Record record) {
    final supported = {
      'id',
      'workspaceId',
      ...columns[table]!,
      if (table == 'servers') ...[
        'protoFiles',
        'protoFolders',
        'protoSources',
        'sourceError',
      ],
      if (table == 'collections') 'requests',
    };
    final unknown = record.keys
        .where((key) => !supported.contains(key))
        .toList();
    if (unknown.isNotEmpty) {
      throw FormatException(
        'Unsupported workspace fields in $table: ${unknown.join(', ')}. Import aborted without discarding data.',
      );
    }
  }

  void _check(String table) {
    if (!columns.containsKey(table)) throw ArgumentError.value(table);
  }

  void close() => db.close();
}
