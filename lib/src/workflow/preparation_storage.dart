import 'dart:convert';

import '../persistence/store.dart';
import '../security/credentials.dart';
import 'preparation.dart';

class PreparationTemplate {
  final String body, metadata, references;
  const PreparationTemplate(this.body, this.metadata, this.references);
  String encode() => jsonEncode({
    'version': 1,
    'body': body,
    'metadata': metadata,
    'references': references,
  });
  factory PreparationTemplate.decode(String raw) {
    try {
      if (raw.length > 64 * 1024 * 1024) throw const FormatException();
      final value = jsonDecode(raw) as Map;
      PreparationProfiles.exact(value, {
        'version',
        'body',
        'metadata',
        'references',
      });
      if (value['version'] != 1) throw const FormatException();
      final result = PreparationTemplate(
        value['body'] as String,
        value['metadata'] as String,
        value['references'] as String,
      );
      if (utf8.encode(result.body).length > 4 * 1024 * 1024 ||
          utf8.encode(result.metadata).length > 16 * 1024 * 1024) {
        throw const FormatException();
      }
      jsonDecode(result.body);
      literalHeaders(parseLiteralMetadata(result.metadata));
      MetadataReferences.decode(result.references);
      return result;
    } catch (_) {
      throw const PreparationFailure(
        'Saved preparation template is unsupported or invalid. Original data remains intact.',
      );
    }
  }
}

class PreparationTemplateStore {
  final WorkspaceStore store;
  PreparationTemplateStore(this.store);
  String? raw(String server, String method) =>
      store.db.select(
            'SELECT state_json FROM request_templates WHERE workspace_id=? AND server_id=? AND full_method=?',
            ['local', server, method],
          ).firstOrNull?['state_json']
          as String?;
  PreparationTemplate? load(String server, String method) {
    final value = raw(server, method);
    return value == null ? null : PreparationTemplate.decode(value);
  }

  void save(String server, String method, PreparationTemplate value) {
    final previous = raw(server, method);
    if (previous != null) PreparationTemplate.decode(previous);
    final encoded = value.encode();
    PreparationTemplate.decode(encoded);
    store.db.execute(
      'INSERT INTO request_templates VALUES(?,?,?,?,?) ON CONFLICT(workspace_id,server_id,full_method) DO UPDATE SET state_json=excluded.state_json,updated_at=excluded.updated_at',
      [
        'local',
        server,
        method,
        encoded,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }
}
