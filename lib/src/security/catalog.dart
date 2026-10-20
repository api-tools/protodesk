import 'dart:convert';

import '../persistence/store.dart';
import 'credentials.dart';

class SqliteCredentialCatalog implements CredentialCatalog {
  final WorkspaceStore store;
  SqliteCredentialCatalog(this.store);
  List<Record> get entries => store.list('credentials');
  Record entry(String id) => entries.firstWhere(
    (r) => r['id'] == id,
    orElse: () => throw CredentialFailure.missing,
  );
  @override
  String create(String label, CredentialScope scope) {
    if (entries.length >= 1000) {
      throw const CredentialFailure(
        'Credential catalog is limited to 1000 entries.',
      );
    }
    return store.save('credentials', {
          'name': label,
          'kind': scope.kind.name,
          'scopeJson': jsonEncode(scope.description),
          'state': 'pending',
        })['id']
        as String;
  }

  @override
  bool contains(String id) => entries.any((r) => r['id'] == id);
  @override
  void state(String id, String state) =>
      store.save('credentials', {...entry(id), 'state': state});
  @override
  void remove(String id) => store.delete('credentials', id);
  List<Record> matching(CredentialScope scope) => entries.where((r) {
    if (r['state'] != 'ready') return false;
    try {
      return CredentialScope.decode(jsonDecode(r['scopeJson'] as String))
          .matches(scope);
    } catch (_) {
      return false;
    }
  }).toList();
}
