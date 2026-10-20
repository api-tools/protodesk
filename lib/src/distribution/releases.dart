import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ReleaseCheckFailure implements Exception {
  final String message;
  const ReleaseCheckFailure(this.message);
  @override
  String toString() => message;
}

/// Stable production versions only; build metadata does not affect precedence.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  final int major, minor, patch;
  const ReleaseVersion(this.major, this.minor, this.patch);
  static ReleaseVersion? parse(String value, {bool tag = false}) {
    final match = RegExp(
      tag
          ? r'^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
          : r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\+\d+)?$',
    ).firstMatch(value);
    if (match == null || value.length > 64) return null;
    try {
      return ReleaseVersion(
        int.parse(match[1]!),
        int.parse(match[2]!),
        int.parse(match[3]!),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  int compareTo(ReleaseVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final result = pair.$1.compareTo(pair.$2);
      if (result != 0) return result;
    }
    return 0;
  }
}

class OfficialRelease {
  static const assetNames = {
    'ProtoDesk-macos-universal.zip',
    'ProtoDesk-windows-x64.zip',
    'ProtoDesk-linux-x64.tar.gz',
    'SHA256SUMS.txt',
  };
  final String tag, notes;
  final Uri page;
  final Map<String, Uri> downloads;
  final ReleaseVersion version;
  const OfficialRelease(
    this.tag,
    this.notes,
    this.page,
    this.downloads,
    this.version,
  );
  factory OfficialRelease.decode(List<int> bytes) {
    try {
      if (bytes.length > ReleaseCheck.maximumBytes) {
        throw const FormatException();
      }
      final value = jsonDecode(utf8.decode(bytes)) as Map;
      final tag = value['tag_name'] as String;
      final version = ReleaseVersion.parse(tag, tag: true);
      if (version == null ||
          value['draft'] != false ||
          value['prerelease'] != false) {
        throw const FormatException();
      }
      final page = Uri.parse(value['html_url'] as String);
      if (page.toString() !=
          'https://github.com/api-tools/protodesk/releases/tag/$tag') {
        throw const FormatException();
      }
      final notes = value['body'] as String? ?? '';
      if (notes.length > 65536) throw const FormatException();
      final downloads = <String, Uri>{};
      final assets = value['assets'] as List;
      if (assets.length > 64) throw const FormatException();
      for (final asset in assets) {
        final item = asset as Map, name = item['name'] as String;
        if (!assetNames.contains(name)) continue;
        final url = Uri.parse(item['browser_download_url'] as String);
        if (downloads.containsKey(name) ||
            url.toString() !=
                'https://github.com/api-tools/protodesk/releases/download/$tag/$name') {
          throw const FormatException();
        }
        downloads[name] = url;
      }
      if (downloads.isEmpty) throw const FormatException();
      return OfficialRelease(
        tag,
        notes,
        page,
        Map.unmodifiable(downloads),
        version,
      );
    } catch (_) {
      throw const ReleaseCheckFailure(
        'The official release response is invalid or unsupported. No download was opened.',
      );
    }
  }
  bool permits(Uri uri) => uri == page || downloads.values.contains(uri);
}

/// A single explicit check. No tokens, user source data, redirects or downloads.
/// Injection is limited to tests; production always uses the fixed endpoint.
class ReleaseCheck {
  static final endpoint = Uri.parse(
    'https://api.github.com/repos/api-tools/protodesk/releases/latest',
  );
  static const maximumBytes = 1024 * 1024;
  final HttpClient Function() clientFactory;
  final Duration deadline;
  HttpClient? _client;
  bool _cancelled = false;
  final _cancellation = Completer<void>();
  ReleaseCheck({
    HttpClient Function()? clientFactory,
    this.deadline = const Duration(seconds: 15),
  }) : clientFactory = clientFactory ?? HttpClient.new;
  void cancel() {
    _cancelled = true;
    if (!_cancellation.isCompleted) _cancellation.complete();
    _client?.close(force: true);
  }

  Future<OfficialRelease> run() async {
    if (_cancelled || _client != null) {
      throw const ReleaseCheckFailure(
        'Release check cancelled or already used.',
      );
    }
    final client = _client = clientFactory();
    client.connectionTimeout = deadline;
    client.autoUncompress = true;
    final timer = Timer(deadline, () => client.close(force: true));
    try {
      final release = await Future.any<OfficialRelease>([
        (() async {
          final request = await client.getUrl(endpoint);
          if (_cancelled) {
            throw const ReleaseCheckFailure('Release check cancelled.');
          }
          request.followRedirects = false;
          request.headers.set(
            HttpHeaders.acceptHeader,
            'application/vnd.github+json',
          );
          request.headers.set(
            HttpHeaders.userAgentHeader,
            'ProtoDesk-release-check',
          );
          request.headers.set('X-GitHub-Api-Version', '2022-11-28');
          final response = await request.close();
          if (response.statusCode != HttpStatus.ok) {
            throw ReleaseCheckFailure(
              response.statusCode == 403 || response.statusCode == 429
                  ? 'GitHub temporarily limited release checks. Try again later.'
                  : 'The official release service is unavailable. Try again later.',
            );
          }
          if (response.contentLength > maximumBytes) {
            throw const ReleaseCheckFailure(
              'Release response exceeds its size limit.',
            );
          }
          final bytes = <int>[];
          await for (final chunk in response) {
            if (_cancelled) {
              throw const ReleaseCheckFailure('Release check cancelled.');
            }
            if (bytes.length + chunk.length > maximumBytes) {
              throw const ReleaseCheckFailure(
                'Release response exceeds its size limit.',
              );
            }
            bytes.addAll(chunk);
          }
          if (_cancelled) {
            throw const ReleaseCheckFailure('Release check cancelled.');
          }
          return OfficialRelease.decode(bytes);
        })(),
        _cancellation.future.then<OfficialRelease>(
          (_) => throw const ReleaseCheckFailure('Release check cancelled.'),
        ),
      ]).timeout(deadline);
      return release;
    } on ReleaseCheckFailure {
      rethrow;
    } catch (_) {
      throw ReleaseCheckFailure(
        _cancelled ? 'Release check cancelled.' : 'Could not check releases securely. Check your connection and try again.',
      );
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }
}
