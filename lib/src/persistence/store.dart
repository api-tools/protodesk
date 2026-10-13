import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

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
      'reflectionEnabled',
      'protoFilesJson',
      'protoFoldersJson',
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
      'responseJson',
      'statusCode',
      'statusMessage',
      'durationMs',
      'error',
      'createdAt',
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
          if (table.key == 'servers' &&
              !database
                  .select('PRAGMA table_info(servers)')
                  .any((r) => r['name'] == 'tls_ca_file')) {
            database.execute(
              "ALTER TABLE servers ADD COLUMN tls_ca_file TEXT NOT NULL DEFAULT ''",
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
      for (final key in ['protoFiles', 'protoFolders']) {
        try {
          record[key] = (jsonDecode(
            record.remove('${key}Json') as String,
          ) as List).cast<String>();
        } catch (_) {
          throw FormatException(
            'Saved server ${record['name']} has invalid $key. Restore its backup or repair the source list.',
          );
        }
      }
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
        final decoded = jsonDecode(record[key] as String);
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
      final endpoint = Uri.tryParse('http://${record['address']}');
      if (endpoint == null ||
          endpoint.host.isEmpty ||
          !endpoint.hasPort ||
          endpoint.port < 1 ||
          endpoint.port > 65535 ||
          endpoint.path.isNotEmpty ||
          (record['address'] as String).contains('://')) {
        throw const FormatException('Server address must be host:port');
      }
      final metadata = jsonDecode(record['metadataJson'] as String? ?? '{}');
      if (metadata is! Map || metadata.values.any((v) => v is! String)) {
        throw const FormatException(
          'Server metadata must be an object of strings',
        );
      }
    }
    if ((table == 'collections' || table == 'collection_requests') &&
        (record['name'] ?? '').toString().trim().isEmpty) {
      throw const FormatException('Name is required');
    }
    final keys = ['workspaceId', 'id', ...columns[table]!];
    final values = keys.map((key) {
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
  Record exportWorkspace() => {
    'kind': 'protodesk.workspace',
    'version': 1,
    'workspaceId': 'local',
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'servers': list('servers'),
    'collections': list('collections'),
  };
  Record importWorkspace(Object? input) {
    if (input is! Map ||
        input['kind'] != 'protodesk.workspace' ||
        input['version'] != 1) {
      throw const FormatException(
        'Not a supported ProtoDesk workspace (version 1 required)',
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
        final old = data.remove('id');
        data.remove('createdAt');
        data.remove('updatedAt');
        data['name'] = '${data['name']} (imported)';
        final saved = save('servers', data);
        ids[old] = saved['id'] as String;
      }
      for (final collection in collections) {
        final data = Map<String, Object?>.from(collection as Map);
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

  void _check(String table) {
    if (!columns.containsKey(table)) throw ArgumentError.value(table);
  }

  void close() => db.close();
}
