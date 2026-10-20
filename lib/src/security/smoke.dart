import 'dart:io';

import '../persistence/store.dart';
import 'catalog.dart';
import 'credentials.dart';
import 'native_vault.dart';

/// Explicit developer verification only. Use isolated storage, never enumerate
/// OS items, and delete only synthetic entries owned by this empty catalog.
Future<void> smokeNativeCredentials(String dataPath) async {
  final isolated = Platform.environment['PROTODESK_DATA_DIR'];
  if (isolated == null || isolated.isEmpty || File(dataPath).existsSync()) {
    throw StateError(
      'Credential smoke requires isolated, unused PROTODESK_DATA_DIR',
    );
  }
  final store = WorkspaceStore.open(dataPath);
  final catalog = SqliteCredentialCatalog(store);
  final service = CredentialService(NativeCredentialVault(), catalog);
  try {
    final scope = CredentialScope.github(
      'protodesk-synthetic-test',
      'not-a-repository',
    );
    final id = await service.create(
      'Synthetic OS store smoke',
      CredentialValue(scope, 'not-a-real-credential'),
    );
    if (await service.resolve(id, scope) != 'not-a-real-credential') {
      throw CredentialFailure.unavailable;
    }
    await service.delete(id);
    stdout.writeln(
      'CREDENTIAL_SMOKE: PASS (native write/read/delete, no plaintext fallback)',
    );
  } finally {
    for (final record in catalog.entries) {
      await service.delete(record['id'] as String);
    }
    service.dispose();
    store.close();
  }
}
