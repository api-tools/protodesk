import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// File references only are persisted. PEM bytes remain in connection memory.
class TlsIdentity {
  final List<int> certificate, privateKey;
  TlsIdentity._(this.certificate, this.privateKey);

  static Future<TlsIdentity?> load(String certificate, String key) async {
    if (certificate.isEmpty && key.isEmpty) return null;
    if (certificate.isEmpty || key.isEmpty) {
      throw const FormatException(
        'Client identity requires both certificate chain and private key files',
      );
    }
    Future<List<int>> read(String path, String role) async {
      try {
        final file = File(path);
        if (await file.length() > 1024 * 1024) {
          throw const FormatException('PEM file exceeds 1 MiB');
        }
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty || bytes.length > 1024 * 1024) {
          throw const FormatException('PEM file must contain 1 byte–1 MiB');
        }
        return bytes;
      } on FileSystemException {
        throw FormatException(
          '$role file unavailable. Reselect it to grant access.',
        );
      }
    }

    final cert = await read(certificate, 'Client certificate');
    final secret = await read(key, 'Client private key');
    final text = utf8.decode(secret, allowMalformed: true);
    if (text.contains('ENCRYPTED') || text.contains('Proc-Type: 4,ENCRYPTED')) {
      throw const FormatException(
        'Encrypted client keys are unsupported. Select an unencrypted PEM key; no password is stored.',
      );
    }
    bool pem(String text, String type) {
      final match = RegExp(
        '-----BEGIN ($type)-----\\s+([A-Za-z0-9+/=\\s]+)-----END \\1-----',
      ).firstMatch(text);
      if (match == null) return false;
      try {
        final bytes = base64.decode(
          match.group(2)!.replaceAll(RegExp(r'\s'), ''),
        );
        return bytes.length > 16 && bytes.first == 0x30;
      } catch (_) {
        return false;
      }
    }

    if (!pem(utf8.decode(cert, allowMalformed: true), 'CERTIFICATE') ||
        !pem(text, 'PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY')) {
      throw const FormatException(
        'Select a PEM certificate chain and an unencrypted PEM private key. Binary containers and malformed PEM are unsupported.',
      );
    }
    final identity = TlsIdentity._(cert, secret);
    // Keep malformed PEM parsing off the UI isolate. Some TLS runtimes retain
    // native parser errors on the calling thread after a rejected key.
    await Isolate.run(() {
      identity.context(null);
    });
    return identity;
  }

  SecurityContext context(List<int>? roots) {
    // Dart's PEM parser can leave a native error queued after malformed input.
    // Retry parsing identical bytes once in a fresh context to consume that
    // stale parser error. Both certificate and matching-key checks must still
    // succeed; this never retries RPCs or accepts an invalid certificate.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final context = SecurityContext(withTrustedRoots: roots == null);
        if (roots != null) context.setTrustedCertificatesBytes(roots);
        context.useCertificateChainBytes(certificate);
        context.usePrivateKeyBytes(privateKey);
        context.setAlpnProtocols(['h2'], false);
        return context;
      } on TlsException {
        if (attempt == 0) continue;
      } catch (_) {
        break;
      }
    }
    throw const FormatException(
      'Invalid client identity or CA: use a valid PEM certificate chain and matching unencrypted PEM private key, and a valid CA file.',
    );
  }
}
