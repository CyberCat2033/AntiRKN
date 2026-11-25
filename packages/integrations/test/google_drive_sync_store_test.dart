import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:test/test.dart';
import 'fixtures/drive_fixture.dart';

Matcher issue(SyncTransportIssue expected) =>
    isA<SyncTransportFailure>().having((e) => e.issue, 'issue', expected);

final class FakeHttp implements DriveHttp {
  FakeHttp(this.handler);
  final Future<DriveHttpResponse> Function(
    String,
    Uri,
    Map<String, String>,
    Uint8List?,
  )
  handler;
  @override
  Future<DriveHttpResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    required int responseLimit,
  }) => handler(method, uri, headers, body);
}

DriveHttpResponse reply(
  int status, [
  Object body = const {},
  Map<String, String> headers = const {},
]) => DriveHttpResponse(
  status,
  headers,
  Uint8List.fromList(utf8.encode(jsonEncode(body))),
);

void main() {
  test('one named snapshot is updated in place with its account key', () async {
    final fixture = DriveFixture();
    await fixture.start();
    addTearDown(fixture.close);
    final store = GoogleDriveSyncStore(tokens: FixtureTokens(), http: fixture);
    expect(await store.findSnapshot(), isNull);
    final key = Uint8List.fromList(List.filled(32, 7));
    expect(await store.createSnapshotKey(key), key);
    expect(await store.readSnapshotKey(), key);
    final created = await store.writeSnapshot(null, Uint8List.fromList([1, 2]));
    final first = (await store.findSnapshot())!;
    expect(created.id, first.id);
    expect(created.etag, first.etag);
    final paths = fixture.paths.length;
    final written = await store.writeSnapshot(
      first,
      Uint8List.fromList([3, 4, 5]),
    );
    // The ordinary write is one conditional request and reports the result.
    expect(fixture.paths.length, paths + 1);
    final next = (await store.findSnapshot())!;
    expect(next.id, first.id);
    expect(next.version, isNot(first.version));
    expect(written.version, next.version);
    expect(written.etag, next.etag);
    expect(await store.readSnapshot(next.id), [3, 4, 5]);
    expect(
      fixture.files.values.where((f) => f['name'] == syncSnapshotName),
      hasLength(1),
    );
  });

  test(
    'upload Location and redirects cannot leak the bearer to another origin',
    () async {
      for (final location in [
        'https://attacker.invalid/upload_id=x',
        'http://www.googleapis.com/upload/drive/v3/files?upload_id=x',
        'https://evil@www.googleapis.com/upload/drive/v3/files?upload_id=x',
        'https://www.googleapis.com:444/upload/drive/v3/files?upload_id=x',
        'https://www.googleapis.com/other?upload_id=x',
      ]) {
        var requests = 0;
        final store = GoogleDriveSyncStore(
          tokens: FixtureTokens(),
          http: FakeHttp((m, u, h, b) async {
            // The first request reserves the file ID, the second starts the
            // resumable upload; nothing goes to the returned Location.
            if (requests++ == 0) {
              return reply(200, {
                'ids': ['file'],
                'space': 'appDataFolder',
              });
            }
            return reply(200, {}, {'location': location});
          }),
        );
        await expectLater(
          store.writeSnapshot(null, Uint8List(4)),
          throwsA(issue(SyncTransportIssue.invalid)),
        );
        expect(requests, 2);
      }
    },
  );

  test('safe error mapping, backoff and rejected cursors', () async {
    for (final entry in {
      401: SyncTransportIssue.unauthorized,
      403: SyncTransportIssue.forbidden,
      404: SyncTransportIssue.notFound,
      409: SyncTransportIssue.conflict,
      412: SyncTransportIssue.conflict,
      429: SyncTransportIssue.rateLimited,
      503: SyncTransportIssue.unavailable,
      302: SyncTransportIssue.invalid,
    }.entries) {
      final store = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: FakeHttp(
          (m, u, h, b) async => reply(
            entry.key,
            {'secret': 'DO_NOT_LEAK'},
            {'retry-after': '15'},
          ),
        ),
      );
      try {
        await store.readSnapshot('file');
        fail('expected failure');
      } on SyncTransportFailure catch (e) {
        expect(e.issue, entry.value);
        expect(e.toString(), isNot(contains('DO_NOT_LEAK')));
        expect(e.retryAfter, const Duration(seconds: 15));
      }
    }
    // A rejected page token of a listing.
    var pages = 0;
    final store = GoogleDriveSyncStore(
      tokens: FixtureTokens(),
      http: FakeHttp(
        (m, u, h, b) async =>
            pages++ == 0 ? reply(200, {'nextPageToken': 'old'}) : reply(410),
      ),
    );
    await expectLater(
      store.findSnapshot(),
      throwsA(issue(SyncTransportIssue.invalidCursor)),
    );
  });

  test(
    'rate-limit reason, malformed data, incomplete search and size limits',
    () async {
      final rate = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: FakeHttp(
          (m, u, h, b) async => reply(403, {
            'error': {
              'errors': [
                {'reason': 'userRateLimitExceeded'},
              ],
            },
          }),
        ),
      );
      await expectLater(
        rate.writeSnapshot(null, Uint8List(4)),
        throwsA(issue(SyncTransportIssue.rateLimited)),
      );
      for (final value in <Object>[
        <Object>[],
        {
          'ids': ['one', 'two'],
        },
        {
          'ids': ['../evil'],
          'space': 'appDataFolder',
        },
      ]) {
        final store = GoogleDriveSyncStore(
          tokens: FixtureTokens(),
          http: FakeHttp((m, u, h, b) async => reply(200, value)),
        );
        await expectLater(
          store.writeSnapshot(null, Uint8List(4)),
          throwsA(issue(SyncTransportIssue.invalid)),
        );
      }
      final incomplete = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: FakeHttp(
          (m, u, h, b) async => reply(200, {'incompleteSearch': true}),
        ),
      );
      await expectLater(
        incomplete.findSnapshot(),
        throwsA(issue(SyncTransportIssue.unavailable)),
      );
      final big = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: FakeHttp(
          (m, u, h, b) async => reply(200, {
            'items': [
              {
                'id': 'x',
                'title': syncSnapshotKeyName,
                'fileSize': '4097',
                'version': '1',
                'etag': '"x"',
              },
            ],
          }),
        ),
      );
      await expectLater(
        big.readSnapshotKey(),
        throwsA(issue(SyncTransportIssue.limit)),
      );
    },
  );

  test('account switch and invalid file IDs fail before network', () async {
    final tokens = FixtureTokens();
    var requests = 0;
    final store = GoogleDriveSyncStore(
      tokens: tokens,
      http: FakeHttp((m, u, h, b) async {
        requests++;
        return reply(200);
      }),
    );
    await expectLater(
      store.readSnapshot('../x'),
      throwsA(issue(SyncTransportIssue.invalid)),
    );
    tokens.accountKey = 'other';
    await expectLater(
      store.findSnapshot(),
      throwsA(issue(SyncTransportIssue.changed)),
    );
    expect(requests, 0);
  });

  test(
    'native HTTP bounds streaming response, deadline and does not follow redirects',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((r) async {
        requests++;
        if (r.uri.path == '/slow') {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (r.uri.path == '/redirect') {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/target');
        } else {
          r.response.add(List.filled(200, 42));
        }
        await r.response.close();
      });
      final http = NativeDriveHttp(timeout: const Duration(milliseconds: 100));
      Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
      await expectLater(
        http.send('GET', uri('/big'), headers: {}, responseLimit: 100),
        throwsA(issue(SyncTransportIssue.limit)),
      );
      await expectLater(
        http.send('GET', uri('/slow'), headers: {}, responseLimit: 1000),
        throwsA(issue(SyncTransportIssue.network)),
      );
      expect(
        (await http.send(
          'GET',
          uri('/redirect'),
          headers: {},
          responseLimit: 1000,
        )).status,
        302,
      );
      expect(requests, 3);
    },
  );

  test(
    'devices creating the snapshot key at once converge on the earliest key',
    () async {
      final fixture = DriveFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final first = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: fixture,
      );
      final second = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: fixture,
      );
      final firstKey = Uint8List.fromList(List.filled(32, 1));
      final secondKey = Uint8List.fromList(List.filled(32, 2));
      // The second device creates its key while the first one is checking.
      fixture.duringFirstList = () => second.createSnapshotKey(secondKey);
      await first.createSnapshotKey(firstKey);
      expect(
        fixture.files.values.where((f) => f['name'] == syncSnapshotKeyName),
        hasLength(2),
      );
      expect(await first.readSnapshotKey(), secondKey);
      expect(await second.readSnapshotKey(), secondKey);
    },
  );

  test(
    'a duplicate snapshot does not break either device: the earliest wins',
    () async {
      final fixture = DriveFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final first = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: fixture,
      );
      final second = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: fixture,
      );
      await first.writeSnapshot(null, Uint8List.fromList([1]));
      // The second device did not see the first file before creating its own.
      await expectLater(
        second.writeSnapshot(null, Uint8List.fromList([2])),
        throwsA(issue(SyncTransportIssue.conflict)),
      );
      final winner = (await first.findSnapshot())!;
      expect((await second.findSnapshot())!.id, winner.id);
      expect(await second.readSnapshot(winner.id), [1]);
    },
  );

  test(
    'native HTTP times out on inactivity, not on a slow steady transfer',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        r.response.bufferOutput = false;
        for (var index = 0; index < 6; index++) {
          r.response.add(List.filled(10, index));
          await r.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        await r.response.close();
      });
      final http = NativeDriveHttp(timeout: const Duration(milliseconds: 150));
      final response = await http.send(
        'GET',
        Uri.parse('http://127.0.0.1:${server.port}/steady'),
        headers: {},
        responseLimit: 1000,
      );
      expect(response.bytes, hasLength(60));
    },
  );

  test(
    'one failed request does not abort others on the shared client',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final slowStarted = Completer<void>();
      server.listen((r) async {
        if (r.uri.path == '/broken') {
          await slowStarted.future;
          final socket = await r.response.detachSocket(writeHeaders: false);
          socket.destroy();
          return;
        }
        slowStarted.complete();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        r.response.add(List.filled(5, 1));
        await r.response.close();
      });
      final http = NativeDriveHttp(timeout: const Duration(seconds: 5));
      Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');
      final slow = http.send(
        'GET',
        uri('/slow'),
        headers: {},
        responseLimit: 100,
      );
      await slowStarted.future;
      await expectLater(
        http.send('GET', uri('/broken'), headers: {}, responseLimit: 100),
        throwsA(issue(SyncTransportIssue.network)),
      );
      expect((await slow).bytes, hasLength(5));
    },
  );

  test(
    'a stale conditional write is rejected and leaves the newer version',
    () async {
      final fixture = DriveFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final first = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: fixture,
      );
      final second = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: fixture,
      );
      await first.writeSnapshot(null, Uint8List.fromList([1]));
      final seen = (await first.findSnapshot())!;
      await second.writeSnapshot(
        (await second.findSnapshot())!,
        Uint8List.fromList([2]),
      );
      await expectLater(
        first.writeSnapshot(seen, Uint8List.fromList([3])),
        throwsA(issue(SyncTransportIssue.conflict)),
      );
      expect(await first.readSnapshot(seen.id), [2]);
      await expectLater(
        first.writeSnapshot(
          SyncRemoteFile(
            id: seen.id,
            name: syncSnapshotName,
            size: 0,
            version: seen.version,
          ),
          Uint8List.fromList([3]),
        ),
        throwsA(issue(SyncTransportIssue.invalid)),
      );
      expect(fixture.conditionalPuts, 2);
    },
  );
}
