import 'dart:collection';
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../persistence/store.dart';

void initializeWorkflowStorage(Database db) {
  db.execute(
    'CREATE TABLE IF NOT EXISTS request_drafts (workspace_id TEXT NOT NULL, server_id TEXT NOT NULL, full_method TEXT NOT NULL, state_json TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(workspace_id,server_id,full_method))',
  );
  db.execute(
    'CREATE TABLE IF NOT EXISTS request_templates (workspace_id TEXT NOT NULL, server_id TEXT NOT NULL, full_method TEXT NOT NULL, state_json TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(workspace_id,server_id,full_method))',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS history_page ON history_items(workspace_id,created_at DESC,id DESC)',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS history_server_page ON history_items(workspace_id,server_id,created_at DESC,id DESC)',
  );
}

class RequestDraft {
  final String body, metadata, references, authority, signature;
  final int timeoutMs;
  final List<Object?> queue, lastSent;
  RequestDraft({
    required this.body,
    required this.metadata,
    required this.references,
    required this.authority,
    required this.timeoutMs,
    required this.signature,
    required this.queue,
    required this.lastSent,
  });
  Map<String, Object?> toJson() => {
    'version': 1,
    'body': body,
    'metadata': metadata,
    'references': references,
    'authority': authority,
    'timeoutMs': timeoutMs,
    'signature': signature,
    'queue': queue,
    'lastSent': lastSent,
  };
  factory RequestDraft.decode(String raw) {
    if (raw.length > 64 * 1024 * 1024) {
      throw const FormatException('Draft exceeds 64 MiB');
    }
    final map = jsonDecode(raw) as Map;
    if (map['version'] != 1 ||
        map.keys.any(
          (key) => !{
            'version',
            'body',
            'metadata',
            'references',
            'authority',
            'timeoutMs',
            'signature',
            'queue',
            'lastSent',
          }.contains(key),
        )) {
      throw const FormatException(
        'Unsupported draft format; original data preserved',
      );
    }
    return RequestDraft(
      body: map['body'] as String,
      metadata: map['metadata'] as String,
      references: map['references'] as String,
      authority: map['authority'] as String,
      timeoutMs: map['timeoutMs'] as int,
      signature: map['signature'] as String,
      queue: List<Object?>.from(map['queue'] as List),
      lastSent: List<Object?>.from(map['lastSent'] as List),
    );
  }
}

class DraftStore {
  final WorkspaceStore store;
  DraftStore(this.store);
  String? raw(String server, String method) =>
      store.db.select(
            'SELECT state_json FROM request_drafts WHERE workspace_id=? AND server_id=? AND full_method=?',
            ['local', server, method],
          ).firstOrNull?['state_json']
          as String?;
  RequestDraft? load(String server, String method) {
    final value = raw(server, method);
    return value == null ? null : RequestDraft.decode(value);
  }

  void save(String server, String method, RequestDraft state) {
    // Never silently replace a future/corrupt record during startup or editing.
    final original = raw(server, method);
    if (original != null) RequestDraft.decode(original);
    final value = jsonEncode(state.toJson());
    if (utf8.encode(value).length > 64 * 1024 * 1024) {
      throw const FormatException('Draft exceeds 64 MiB');
    }
    store.db.execute(
      'INSERT INTO request_drafts VALUES(?,?,?,?,?) ON CONFLICT(workspace_id,server_id,full_method) DO UPDATE SET state_json=excluded.state_json,updated_at=excluded.updated_at',
      [
        'local',
        server,
        method,
        value,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }
}

class HistoryFilter {
  final String text, serverId, status;
  final DateTime? from, until;
  const HistoryFilter({
    this.text = '',
    this.serverId = '',
    this.status = '',
    this.from,
    this.until,
  });
}

class HistoryPage {
  final List<Record> rows;
  final bool hasNext;
  HistoryPage(this.rows, this.hasNext);
}

/// Listing remains small even when history contains large response bodies.
/// Payloads are fetched for one record only when preview/reuse accesses them.
class HistoryRecord extends MapBase<String, Object?> {
  final WorkspaceStore store;
  final Map<String, Object?> summary;
  Map<String, Object?>? _data;
  HistoryRecord(this.store, this.summary);
  bool get payloadLoaded => _data != null;
  Map<String, Object?> full() {
    if (_data != null) return _data!;
    final row = store.db.select(
      'SELECT * FROM history_items WHERE workspace_id=? AND id=?',
      ['local', summary['id']],
    ).firstOrNull;
    if (row == null) {
      throw const FormatException('History item no longer exists');
    }
    return _data = {
      for (final entry in row.entries)
        WorkspaceStore.camel(entry.key): entry.value,
    };
  }

  @override
  Object? operator [](Object? key) => _data != null
      ? _data![key]
      : summary.containsKey(key)
      ? summary[key]
      : full()[key];
  @override
  void operator []=(String key, Object? value) => full()[key] = value;
  @override
  Iterable<String> get keys =>
      _data?.keys ??
      ['workspaceId', 'id', ...WorkspaceStore.columns['history_items']!];
  @override
  void clear() => full().clear();
  @override
  Object? remove(Object? key) => full().remove(key);
}

HistoryPage queryHistory(
  WorkspaceStore store, {
  HistoryFilter filter = const HistoryFilter(),
  int offset = 0,
  int limit = 50,
}) {
  if (filter.text.length > 4096) {
    throw const FormatException('History search is limited to 4096 characters');
  }
  if (offset < 0 || limit < 1 || limit > 200) {
    throw ArgumentError('Invalid history page');
  }
  final where = <String>['workspace_id=?'], args = <Object?>['local'];
  if (filter.text.isNotEmpty) {
    where.add(
      'instr(lower(server_name || char(10) || server_address || char(10) || full_method),lower(?))>0',
    );
    args.add(filter.text);
  }
  if (filter.serverId.isNotEmpty) {
    where.add('server_id=?');
    args.add(filter.serverId);
  }
  if (filter.status.isNotEmpty) {
    where.add('status_code=?');
    args.add(filter.status);
  }
  if (filter.from != null) {
    where.add('created_at>=?');
    args.add(filter.from!.toUtc().toIso8601String());
  }
  if (filter.until != null) {
    where.add('created_at<?');
    args.add(filter.until!.toUtc().toIso8601String());
  }
  final rows = store.db.select(
    'SELECT workspace_id,id,server_id,server_name,server_address,service_name,method_name,full_method,status_code,duration_ms,created_at FROM history_items WHERE ${where.join(' AND ')} ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?',
    [...args, limit + 1, offset],
  );
  return HistoryPage([
    for (final row in rows.take(limit))
      HistoryRecord(store, {
        for (final entry in row.entries)
          WorkspaceStore.camel(entry.key): entry.value,
      }),
  ], rows.length > limit);
}
