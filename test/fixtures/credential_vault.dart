import 'dart:async';

import 'package:protodesk/src/security/credentials.dart';

class MemoryVault implements CredentialVault {
  final values = <String, String>{};
  int reads = 0, writes = 0;
  bool locked = false, discardWrites = false;
  Completer<void>? pending;
  void check() {
    if (locked) throw StateError('backend contained a synthetic-secret');
  }

  @override
  Future<String?> read(String id) async {
    reads++;
    check();
    return values[id];
  }

  @override
  Future<void> write(String id, String payload) async {
    writes++;
    check();
    if (pending != null) await pending!.future;
    if (!discardWrites) values[id] = payload;
  }

  @override
  Future<void> delete(String id) async {
    check();
    values.remove(id);
  }
}
