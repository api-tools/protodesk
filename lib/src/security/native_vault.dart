import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credentials.dart';

/// OS-backed storage only. Legacy macOS Keychain avoids a sharing entitlement
/// or provisioning profile; the existing sandbox/Developer ID policy remains.
/// Instantiation is lazy: no OS operation occurs until explicit credential use.
class NativeCredentialVault implements CredentialVault {
  final FlutterSecureStorage storage;
  NativeCredentialVault({FlutterSecureStorage? storage})
    : storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(
              accountName: 'ProtoDesk credentials',
              usesDataProtectionKeychain: false,
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );
  String _key(String id) {
    if (!validCredentialId(id)) throw CredentialFailure.invalid;
    return 'protodesk.credential.$id';
  }

  @override
  Future<String?> read(String id) async {
    final key = _key(id);
    try {
      return await storage.read(key: key);
    } catch (_) {
      throw CredentialFailure.unavailable;
    }
  }

  @override
  Future<void> write(String id, String protectedPayload) async {
    final key = _key(id);
    try {
      await storage.write(key: key, value: protectedPayload);
    } catch (_) {
      throw CredentialFailure.unavailable;
    }
  }

  @override
  Future<void> delete(String id) async {
    final key = _key(id);
    try {
      await storage.delete(key: key);
    } catch (_) {
      throw CredentialFailure.unavailable;
    }
  }
}
