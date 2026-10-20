import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk/src/distribution/releases.dart';
import 'package:protodesk/src/presentation/updates.dart';

Map<String, Object?> fixture() => {
  'tag_name': 'v1.0.14',
  'draft': false,
  'prerelease': false,
  'html_url': 'https://github.com/api-tools/protodesk/releases/tag/v1.0.14',
  'body': '<script>plain text only</script>\nRelease notes',
  'assets': [
    for (final name in OfficialRelease.assetNames)
      {
        'name': name,
        'browser_download_url':
            'https://github.com/api-tools/protodesk/releases/download/v1.0.14/$name',
      },
  ],
};
List<int> encoded(Map<String, Object?> value) => utf8.encode(jsonEncode(value));

class Headers implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Response extends Stream<List<int>> implements HttpClientResponse {
  final Stream<List<int>> body;
  @override
  final int statusCode, contentLength;
  Response(this.body, {this.statusCode = 200, this.contentLength = -1});
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Request implements HttpClientRequest {
  final Future<HttpClientResponse> response;
  @override
  final headers = Headers();
  @override
  bool followRedirects = true;
  Request(this.response);
  @override
  Future<HttpClientResponse> close() => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Client implements HttpClient {
  final Request request;
  int calls = 0, closes = 0;
  Uri? uri;
  @override
  Duration? connectionTimeout;
  @override
  bool autoUncompress = false;
  Client(this.request);
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    calls++;
    uri = url;
    return request;
  }

  @override
  void close({bool force = false}) {
    closes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Client client([int status = 200]) => Client(
  Request(
    Future.value(
      Response(Stream.value(encoded(fixture())), statusCode: status),
    ),
  ),
);
void main() {
  test('stable version precedence handles build metadata and rejects ambiguous/development tags', () {
    expect(
      ReleaseVersion.parse('1.10.0+9')!
          .compareTo(ReleaseVersion.parse('1.9.99')!),
      greaterThan(0),
    );
    expect(
      ReleaseVersion.parse('1.0.14+15')!
          .compareTo(ReleaseVersion.parse('v1.0.14', tag: true)!),
      0,
    );
    for (final value in [
      'Development build',
      'v1.0.14',
      '1.0.14-beta',
      '01.0.1',
      '1.0',
    ]) {
      expect(ReleaseVersion.parse(value), isNull);
    }
    expect(ReleaseVersion.parse('v1.0.14-beta', tag: true), isNull);
  });
  test('release accepts only exact official URLs and stable assets', () {
    final release = OfficialRelease.decode(encoded(fixture()));
    expect(release.downloads.length, 4);
    expect(release.notes, contains('<script>'));
    expect(release.permits(Uri.parse('https://evil.example')), false);
    for (final mutation in <void Function(Map<String, Object?>)>[
      (v) => v['draft'] = true,
      (v) => v['prerelease'] = true,
      (v) => v['tag_name'] = 'v1.0.14-rc',
      (v) => v['html_url'] = 'https://github.com.evil.example/api-tools/protodesk/releases/tag/v1.0.14',
      (v) => v['html_url'] =
          'https://token@github.com/api-tools/protodesk/releases/tag/v1.0.14',
      (v) => v['body'] = 'x' * 65537,
      (v) => (v['assets'] as List).first['browser_download_url'] =
          'file:///tmp/payload',
      (v) => (v['assets'] as List).add((v['assets'] as List).first),
    ]) {
      final value = fixture();
      mutation(value);
      expect(
        () => OfficialRelease.decode(encoded(value)),
        throwsA(isA<ReleaseCheckFailure>()),
      );
    }
  });
  test('explicit request pins endpoint, sends no credentials and refuses redirects/status errors', () async {
    final c = client();
    final check = ReleaseCheck(clientFactory: () => c);
    expect(c.calls, 0);
    await check.run();
    expect(c.uri, ReleaseCheck.endpoint);
    expect(c.request.followRedirects, false);
    expect(
      (c.request.headers as Headers).values.keys,
      isNot(contains('authorization')),
    );
    expect(c.closes, greaterThan(0));
    for (final status in [301, 302, 403, 404, 429, 500]) {
      final c = client(status);
      expect(
        ReleaseCheck(clientFactory: () => c).run(),
        throwsA(isA<ReleaseCheckFailure>()),
      );
    }
  });
  test('chunked and declared oversized responses fail; total deadline and cancellation close client', () async {
    for (final response in [
      Response(Stream.value(List.filled(ReleaseCheck.maximumBytes + 1, 32))),
      Response(
        const Stream.empty(),
        contentLength: ReleaseCheck.maximumBytes + 1,
      ),
    ]) {
      final c = Client(Request(Future.value(response)));
      await expectLater(
        ReleaseCheck(clientFactory: () => c).run(),
        throwsA(isA<ReleaseCheckFailure>()),
      );
      expect(c.closes, greaterThan(0));
    }
    final c = Client(Request(Completer<HttpClientResponse>().future));
    await expectLater(
      ReleaseCheck(
        clientFactory: () => c,
        deadline: const Duration(milliseconds: 10),
      ).run(),
      throwsA(isA<ReleaseCheckFailure>()),
    );
    expect(c.closes, greaterThan(0));
    final stream = StreamController<List<int>>();
    final cancelledClient = Client(
      Request(Future.value(Response(stream.stream))),
    );
    final check = ReleaseCheck(clientFactory: () => cancelledClient);
    final run = expectLater(check.run(), throwsA(isA<ReleaseCheckFailure>()));
    await Future<void>.delayed(Duration.zero);
    check.cancel();
    stream.add(encoded(fixture()));
    await stream.close();
    await run;
  });
  testWidgets(
    'no background check; explicit result, plain notes and verified links fit narrow About surface',
    (tester) async {
      tester.view.physicalSize = const Size(600, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = client();
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReleaseAvailability(
                currentVersion: '1.0.13+14',
                checkFactory: () => ReleaseCheck(clientFactory: () => c),
                openLink: (uri) async {
                  opened.add(uri);
                  return false;
                },
              ),
            ),
          ),
        ),
      );
      expect(c.calls, 0);
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(find.text('A newer stable release is available.'), findsOneWidget);
      expect(find.textContaining('<script>plain text'), findsOneWidget);
      await tester.ensureVisible(find.text('Official release page'));
      await tester.tap(find.text('Official release page'));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), fixture()['html_url']);
      expect(find.textContaining('Could not open the browser'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'About dialog remains usable at minimum width and unknown versions never claim up-to-date',
    (tester) async {
      tester.view.physicalSize = const Size(600, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAboutDialog(
                  context: context,
                  applicationName: 'ProtoDesk',
                  children: [
                    ReleaseAvailability(
                      checkFactory: () => ReleaseCheck(clientFactory: client),
                    ),
                  ],
                ),
                child: const Text('About'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Development version cannot be compared with stable releases.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('You are using the latest stable release.'),
        findsNothing,
      );
      expect(find.text('Close'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'same and newer installed stable builds are compared numerically',
    (tester) async {
      for (final entry in {
        '1.0.14+99': 'You are using the latest stable release.',
        '1.1.0': 'This build is newer than the latest stable release.',
      }.entries) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReleaseAvailability(
                key: ValueKey(entry.key),
                currentVersion: entry.key,
                checkFactory: () => ReleaseCheck(clientFactory: client),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Check for updates'));
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget);
      }
    },
  );
  testWidgets(
    'cancel and dispose discard late results without setState after unmount',
    (tester) async {
      final response = Completer<HttpClientResponse>();
      final c = Client(Request(response.future));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReleaseAvailability(
              checkFactory: () => ReleaseCheck(clientFactory: () => c),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Check for updates'));
      await tester.pump();
      await tester.tap(find.text('Cancel check'));
      await tester.pump();
      expect(find.text('Release check cancelled.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      response.complete(Response(Stream.value(encoded(fixture()))));
      await tester.pumpAndSettle();
      expect(c.closes, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );
}
