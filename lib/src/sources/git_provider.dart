import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'package:path/path.dart' as p;

import 'configuration.dart';
import 'discovery.dart';

/// Provider seam for future hosts and credential-store-backed authentication.
abstract interface class RepositoryProvider {
  Future<String> resolve(
    String url,
    String reference,
    SourceOperation operation,
  );
  Future<void> fetch(
    String url,
    String commit,
    Directory destination,
    SourceOperation operation,
  );
}

typedef RepositoryRequest = Future<Map<String, dynamic>> Function(
  List<String> path,
  SourceOperation operation,
);

class GitHubProvider implements RepositoryProvider {
  final RepositoryRequest request;
  final Future<List<int>> Function(Uri, SourceOperation) download;
  GitHubProvider({
    RepositoryRequest? request,
    Future<List<int>> Function(Uri, SourceOperation)? download,
  }) : request = request ?? _request,
       download = download ?? _download;

  static bool publicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (b.length == 4) {
      return !(b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          b[0] >= 224 ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 &&
              (b[1] == 168 || (b[1] == 0 && (b[2] == 0 || b[2] == 2)))) ||
          (b[0] == 198 &&
              (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) ||
          (b[0] == 203 && b[1] == 0 && b[2] == 113) ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127));
    }
    // GitHub API supports IPv4; avoid mapped/private/reserved IPv6 targets.
    return false;
  }

  // A custom HttpClient factory must supply TLS itself. Pin the resolved
  // address while retaining the original host for SNI and certificate checks.
  static Future<ConnectionTask<Socket>> _secureConnection(
    InternetAddress address,
    Uri uri,
  ) async {
    final task = await Socket.startConnect(address, uri.port);
    Socket? connected;
    var cancelled = false;
    final secured = task.socket.then((socket) async {
      connected = socket;
      final tls = await SecureSocket.secure(
        socket,
        host: uri.host,
        supportedProtocols: ['http/1.1'],
      );
      connected = tls;
      if (cancelled) {
        tls.destroy();
        throw const SocketException('Connection cancelled');
      }
      return tls as Socket;
    });
    return ConnectionTask.fromSocket(secured, () {
      cancelled = true;
      task.cancel();
      connected?.destroy();
    });
  }

  static Future<Map<String, dynamic>> _request(
    List<String> path,
    SourceOperation operation,
  ) async {
    operation.check();
    final uri = Uri(
      scheme: 'https',
      host: 'api.github.com',
      pathSegments: path,
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    void cancelNetwork() => client.close(force: true);
    operation.onCancel(cancelNetwork);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (uri.host != 'api.github.com' ||
          uri.scheme != 'https' ||
          proxyHost != null) {
        throw const FormatException('Unsafe repository network target');
      }
      final addresses = await InternetAddress.lookup(
        uri.host,
        type: InternetAddressType.IPv4,
      );
      if (addresses.isEmpty || addresses.any((a) => !publicAddress(a))) {
        throw const FormatException(
          'Repository host resolved to a private network',
        );
      }
      operation.check();
      return _secureConnection(addresses.first, uri);
    };
    try {
      final outgoing = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      outgoing.followRedirects = false;
      outgoing.headers.set('User-Agent', 'ProtoDesk');
      outgoing.headers.set('Accept', 'application/vnd.github+json');
      final response = await outgoing.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        throw FormatException(
          'GitHub fetch failed (HTTP ${response.statusCode}). Check repository/reference or API rate limits. Redirects are not allowed.',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        operation.check();
        if (bytes.length + chunk.length > 16 * 1024 * 1024) {
          throw const FormatException('Repository API response exceeds 16 MiB');
        }
        bytes.add(chunk);
      }
      return jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>;
    } finally {
      operation.removeCancel(cancelNetwork);
      client.close(force: true);
    }
  }

  @override
  Future<String> resolve(
    String url,
    String reference,
    SourceOperation operation,
  ) async {
    final (owner, name) = repository(url);
    if (reference.length > 256 || reference.contains('\u0000')) {
      throw const FormatException('Invalid repository reference');
    }
    final result = await request([
      'repos',
      owner,
      name,
      'commits',
      reference,
    ], operation);
    final sha = result['sha'];
    if (sha is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(sha)) {
      throw const FormatException('GitHub returned an invalid commit SHA');
    }
    return sha;
  }

  @override
  Future<void> fetch(
    String url,
    String commit,
    Directory destination,
    SourceOperation operation,
  ) async {
    final (owner, name) = repository(url);
    operation.progress('Downloading repository archive…');
    final bytes = await download(
      Uri(
        scheme: 'https',
        host: 'codeload.github.com',
        pathSegments: [owner, name, 'zip', commit],
      ),
      operation,
    );
    final port = ReceivePort();
    final isolate = await Isolate.spawn(_extractWorker, [
      port.sendPort,
      bytes,
      destination.path,
    ]);
    final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (operation.cancelled || operation.clock.elapsed.inSeconds >= 90) {
        isolate.kill(priority: Isolate.immediate);
        port.sendPort.send('Source operation cancelled or timed out');
      }
    });
    try {
      final result = await port.first.timeout(const Duration(seconds: 15));
      if (result != true) throw FormatException(result.toString());
      operation.check();
    } finally {
      timer.cancel();
      isolate.kill(priority: Isolate.immediate);
      port.close();
    }
  }

  static Future<List<int>> _download(Uri uri, SourceOperation operation) async {
    if (uri.scheme != 'https' ||
        uri.host != 'codeload.github.com' ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Unsafe repository archive URL');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    void cancelNetwork() => client.close(force: true);
    operation.onCancel(cancelNetwork);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (target, proxyHost, proxyPort) async {
      if (target.host != 'codeload.github.com' ||
          target.scheme != 'https' ||
          proxyHost != null) {
        throw const FormatException('Unsafe archive target');
      }
      final addresses = await InternetAddress.lookup(
        target.host,
        type: InternetAddressType.IPv4,
      );
      if (addresses.isEmpty || addresses.any((a) => !publicAddress(a))) {
        throw const FormatException('Unsafe repository network address');
      }
      operation.check();
      return _secureConnection(addresses.first, target);
    };
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set('User-Agent', 'ProtoDesk');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        throw FormatException(
          'Repository archive fetch failed (HTTP ${response.statusCode}); redirects are forbidden',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        operation.check();
        if (bytes.length + chunk.length > 64 * 1024 * 1024) {
          throw const FormatException('Repository download exceeds 64 MiB');
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      operation.removeCancel(cancelNetwork);
      client.close(force: true);
    }
  }

  static void _extractWorker(List<Object> args) {
    final port = args[0] as SendPort;
    try {
      extractArchive(args[1] as List<int>, args[2] as String);
      port.send(true);
    } catch (_) {
      port.send('Unsafe, oversized or invalid repository archive');
    }
  }

  /// Validate central-directory metadata before decompressing anything.
  static void extractArchive(List<int> bytes, String destination) {
    if (bytes.length > 64 * 1024 * 1024) {
      throw const FormatException('Download limit');
    }
    final raw = Uint8List.fromList(bytes);
    final header = ByteData.sublistView(raw);
    var end = raw.length - 22;
    while (end >= 0 &&
        end >= raw.length - 65557 &&
        header.getUint32(end, Endian.little) != 0x06054b50) {
      end--;
    }
    if (end < 0 ||
        end < raw.length - 65557 ||
        header.getUint16(end + 10, Endian.little) >= 60000 ||
        header.getUint32(end + 12, Endian.little) == 0xffffffff) {
      throw const FormatException(
        'Invalid, oversized or unsupported ZIP64 repository archive',
      );
    }
    final zip = ZipDirectory()..read(InputMemoryStream(bytes));
    if (zip.fileHeaders.length > SourceLimits.scanned) {
      throw const FormatException('File count limit');
    }
    var total = 0, protoBytes = 0, protoCount = 0;
    String? prefix;
    final names = <String>{};
    for (final header in zip.fileHeaders) {
      final name = relativePath(header.filename, allowEmpty: false);
      final parts = name.split('/');
      prefix ??= parts.first;
      if (parts.first != prefix || !names.add(name.toLowerCase())) {
        throw const FormatException('Conflicting archive paths');
      }
      final mode = header.externalFileAttributes >> 16;
      final kind = mode & 0xf000;
      if (kind != 0 && kind != 0x8000 && kind != 0x4000) {
        throw const FormatException('Unsafe repository file type');
      }
      if ((header.generalPurposeBitFlag & 1) != 0 ||
          ![0, 8].contains(header.compressionMethod)) {
        throw const FormatException('Unsupported archive encoding');
      }
      total += header.uncompressedSize;
      if (total > 256 * 1024 * 1024) {
        throw const FormatException('Repository tree size limit');
      }
      if (!name.endsWith('.proto')) continue;
      protoBytes += header.uncompressedSize;
      if (++protoCount > SourceLimits.files ||
          header.uncompressedSize > SourceLimits.fileBytes ||
          protoBytes > SourceLimits.totalBytes) {
        throw const FormatException('Proto size limit');
      }
      if (parts.length < 2 || parts.any((part) => part.isEmpty)) {
        throw const FormatException('Invalid archive path');
      }
      final content = header.file!.getStream().toUint8List();
      if (content.length != header.uncompressedSize ||
          getCrc32(content) != header.crc32) {
        throw const FormatException('Repository archive checksum mismatch');
      }
      final file = File(p.join(destination, parts.skip(1).join('/')));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(content, flush: true);
    }
    if (protoCount == 0) {
      throw const FormatException('Repository contains no .proto files');
    }
  }
}

class RepositoryCache {
  final Directory directory;
  final RepositoryProvider provider;
  RepositoryCache(this.directory, {RepositoryProvider? provider})
    : provider = provider ?? GitHubProvider();
  Future<Map<String, String>> _manifest(
    Directory revision,
    SourceOperation operation,
  ) async {
    final root = await safePath(revision.path, directory: true);
    final hashes = <String, String>{};
    for (final name in await FileDiscovery().discover(root, operation)) {
      operation.check();
      final path = await safePath(p.join(root, name), directory: false);
      if (!p.isWithin(root, path)) {
        throw const FormatException('Cache file escapes its revision');
      }
      hashes[name] = sha256.convert(await File(path).readAsBytes()).toString();
    }
    return hashes;
  }

  Future<void> _verify(
    Directory revision,
    String commit,
    SourceOperation operation,
  ) async {
    await safePath(p.join(revision.path, '.complete'), directory: false);
    if (await File(p.join(revision.path, '.complete')).readAsString() !=
        commit) {
      throw const FormatException('Corrupted cached revision marker');
    }
    final metadata = File(
      await safePath(p.join(revision.path, '.manifest.json'), directory: false),
    );
    if (await metadata.length() > 2 * 1024 * 1024) {
      throw const FormatException('Cache metadata exceeds resource limits');
    }
    final expected = Map<String, String>.from(
      jsonDecode(await metadata.readAsString()) as Map,
    );
    final actual = await _manifest(revision, operation);
    if (expected.length != actual.length ||
        expected.entries.any((e) => actual[e.key] != e.value)) {
      throw const FormatException(
        'Cached repository content changed; remove this revision and fetch it again.',
      );
    }
  }

  Future<(Directory, String)> acquire(
    Map<String, Object?> source,
    SourceOperation operation, {
    bool refresh = false,
  }) async {
    final url = source['url'] as String;
    final (owner, name) = repository(url);
    String? commit = source['commit'] as String?;
    if (refresh || commit == null) {
      operation.progress('Resolving repository revision…');
      commit = await operation.wait(
        provider.resolve(url, source['ref'] as String, operation),
      );
    }
    if (commit == null || !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
      throw const FormatException('Invalid revision');
    }
    await directory.create(recursive: true);
    final cacheRoot = await safePath(directory.path, directory: true);
    final parent = Directory(
      p.join(cacheRoot, '${owner.toLowerCase()}--${name.toLowerCase()}'),
    );
    await parent.create(recursive: true);
    final parentPath = await safePath(parent.path, directory: true);
    if (!p.isWithin(cacheRoot, parentPath)) {
      throw const FormatException('Repository cache escapes its managed root');
    }
    final target = Directory(p.join(parentPath, commit));
    if (await FileSystemEntity.type(target.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Unsafe cache revision symlink');
    }
    if (await File(p.join(target.path, '.complete')).exists()) {
      await _verify(target, commit, operation);
      return (target, commit);
    }
    var diskBytes = 0;
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      operation.check();
      if (entry is Link) throw const FormatException('Unsafe cache symlink');
      if (entry is File) diskBytes += await entry.length();
      if (diskBytes > 221 * 1024 * 1024) {
        throw const FormatException(
          'Schema cache is full (256 MiB limit). Remove unused cached revisions before downloading.',
        );
      }
    }
    final temp = await parent.createTemp('.fetch-');
    try {
      await provider.fetch(url, commit, temp, operation);
      operation.check();
      final metadata = jsonEncode(await _manifest(temp, operation));
      if (metadata.length > 2 * 1024 * 1024) {
        throw const FormatException('Cache metadata exceeds resource limits');
      }
      await File(p.join(temp.path, '.manifest.json'))
          .writeAsString(metadata, flush: true);
      operation.check();
      await File(p.join(temp.path, '.complete'))
          .writeAsString(commit, flush: true);
      if (await target.exists()) {
        if (!await File(p.join(target.path, '.complete')).exists()) {
          throw const FormatException(
            'Incomplete cache revision; remove it before retrying',
          );
        }
      } else {
        operation.check();
        await temp.rename(target.path);
      }
      await _verify(target, commit, operation);
      return (target, commit);
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }
  }
}
