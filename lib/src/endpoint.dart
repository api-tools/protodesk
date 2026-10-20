/// Parse an explicit gRPC host:port without URI default-port normalization.
/// Using an HTTP scheme here would incorrectly erase an explicit port 80.
(String, int) parseServerAddress(String address) {
  try {
    final uri = Uri.tryParse('grpc://$address');
    if (address.contains('://') ||
        address.codeUnits.any((c) => c <= 32 || c == 127) ||
        uri == null ||
        uri.host.isEmpty ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.path.isNotEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException();
    }
    return (uri.host, uri.port);
  } catch (_) {
    throw const FormatException(
      'Server address must be host:port (port 1–65535), without credentials, paths or URL parameters',
    );
  }
}

String grpcAuthority(String host, int port) {
  final name = host.contains(':') && !host.startsWith('[') ? '[$host]' : host;
  return port == 443 ? name : '$name:$port';
}

void validateGrpcAuthority(String authority) {
  if (authority.isEmpty) return;
  try {
    final uri = Uri.tryParse('grpc://$authority');
    if (authority.length > 1024 ||
        authority.codeUnits.any((c) => c <= 32 || c == 127) ||
        uri == null ||
        uri.host.isEmpty ||
        uri.path.isNotEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException();
    }
  } catch (_) {
    throw const FormatException(
      'HTTP/2 authority must be a host or host:port, without credentials, paths or URL parameters',
    );
  }
}
