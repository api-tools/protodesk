import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/persistence/store.dart';
import 'package:protodesk/src/security/catalog.dart';
import 'package:protodesk/src/security/credentials.dart';
import 'package:protodesk/src/sources/configuration.dart';
import 'package:protodesk/src/sources/git_provider.dart';

import 'fixtures/credential_vault.dart';

const sha = '1111111111111111111111111111111111111111';
void main() {
  late Directory directory;
  late WorkspaceStore store;
  late MemoryVault vault;
  late CredentialService credentials;
  late String id;
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('protodesk-private-test-');
    store = WorkspaceStore.open('${directory.path}/data.sqlite');
    vault = MemoryVault();
    credentials = CredentialService(vault, SqliteCredentialCatalog(store));
    id = await credentials.create(
      'Repository PAT',
      CredentialValue(CredentialScope.github('owner', 'repo'), 'synthetic-PAT'),
    );
  });
  tearDown(() {
    credentials.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });

  test('token stays on intended API path; signed redirect has no authorization; offline cache requires no vault access', () async {
    final requests = <Uri>[];
    final archive = ZipEncoder().encode(
      Archive()..add(
        ArchiveFile.string(
          'repo-$sha/proto/a.proto',
          'syntax="proto3"; message Empty {}',
        ),
      ),
    );
    final provider = AuthenticatedGitHubProvider(
      credentials,
      id,
      'owner',
      'repo',
      send: (uri, headers, op) async {
        requests.add(uri);
        if (uri.host == 'api.github.com') {
          expect(headers['Authorization'], 'Bearer synthetic-PAT');
          expect(uri.path, startsWith('/repos/owner/repo/'));
          if (uri.path.contains('/commits/')) {
            return RepositoryHttpResponse(
              200,
              utf8.encode(jsonEncode({'sha': sha})),
            );
          }
          return RepositoryHttpResponse(
            302,
            [],
            location:
                'https://codeload.github.com/owner/repo/legacy.zip/$sha?token=temporary',
          );
        }
        expect(uri.host, 'codeload.github.com');
        expect(headers, isEmpty);
        return RepositoryHttpResponse(200, archive);
      },
    );
    final cache = RepositoryCache(
      Directory('${directory.path}/cache'),
      providerForSource: (_) => provider,
    );
    final source = <String, Object?>{
      'url': 'https://github.com/owner/repo',
      'ref': 'main',
      'credentialRef': id,
    };
    final (revision, commit) = await cache.acquire(source, SourceOperation());
    expect(commit, sha);
    expect(File('${revision.path}/proto/a.proto').existsSync(), true);
    expect(requests.length, 3);
    final reads = vault.reads;
    vault.locked = true;
    final (offline, _) = await cache.acquire({
      ...source,
      'commit': sha,
    }, SourceOperation());
    expect(offline.path, revision.path);
    expect(vault.reads, reads);
    await expectLater(
      cache.acquire(
        {...source, 'commit': sha},
        SourceOperation(),
        refresh: true,
      ),
      throwsA(same(CredentialFailure.unavailable)),
    );
    expect(File('${revision.path}/proto/a.proto').existsSync(), true);
    final noResolver = RepositoryCache(Directory('${directory.path}/cache'));
    await noResolver.acquire({...source, 'commit': sha}, SourceOperation());
    await expectLater(
      noResolver.acquire(source, SourceOperation()),
      throwsA(same(CredentialFailure.missing)),
    );
  });

  test('rejects malicious redirects without forwarding a token or disclosing signed URLs', () async {
    for (final target in [
      'http://codeload.github.com/owner/repo/legacy.zip/$sha',
      'https://127.0.0.1/archive?synthetic-secret',
      'https://codeload.github.com/other/repo/legacy.zip/$sha',
      'https://user:synthetic-secret@codeload.github.com/owner/repo/legacy.zip/$sha',
      'https://codeload.github.com:443/owner/repo/legacy.zip/$sha',
      'https://codeload.github.com/owner/repo/legacy.zip/$sha#synthetic-secret',
    ]) {
      var calls = 0;
      final provider = AuthenticatedGitHubProvider(
        credentials,
        id,
        'owner',
        'repo',
        send: (uri, headers, op) async {
          calls++;
          return RepositoryHttpResponse(302, [], location: target);
        },
      );
      await expectLater(
        provider.fetch(
          'https://github.com/owner/repo',
          sha,
          directory,
          SourceOperation(),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.toString(),
            'redacted',
            isNot(contains('synthetic-secret')),
          ),
        ),
      );
      expect(calls, 1);
    }
  });

  test(
    'rebind attack and traversal reference rejected before reading credentials',
    () async {
      final before = vault.reads;
      final provider = AuthenticatedGitHubProvider(
        credentials,
        id,
        'owner',
        'repo',
        send: (_, _, _) async => throw StateError('must not send'),
      );
      await expectLater(
        provider.resolve(
          'https://github.com/other/repo',
          'main',
          SourceOperation(),
        ),
        throwsA(same(CredentialFailure.wrongScope)),
      );
      await expectLater(
        provider.resolve(
          'https://github.com/owner/repo',
          '../elsewhere',
          SourceOperation(),
        ),
        throwsA(same(CredentialFailure.wrongScope)),
      );
      expect(vault.reads, before);
    },
  );

  test(
    'revocation and exceptions omit token and sensitive remote contents',
    () async {
      for (final crash in [false, true]) {
        final provider = AuthenticatedGitHubProvider(
          credentials,
          id,
          'owner',
          'repo',
          send: (_, _, _) async {
            if (crash) throw StateError('synthetic-PAT token=private');
            return RepositoryHttpResponse(
              401,
              utf8.encode('synthetic-PAT private contents'),
            );
          },
        );
        await expectLater(
          provider.resolve(
            'https://github.com/owner/repo',
            sha,
            SourceOperation(),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.toString(),
              'redacted',
              allOf(
                isNot(contains('synthetic-PAT')),
                isNot(contains('private contents')),
              ),
            ),
          ),
        );
      }
    },
  );
}
