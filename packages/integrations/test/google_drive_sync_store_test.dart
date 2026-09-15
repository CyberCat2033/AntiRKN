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
  test(
    'real HTTP fixture: IDs, resumable upload, duplicate, metadata/media, list and changes',
    () async {
      final fixture = DriveFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final store = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: fixture,
      );
      final start = await store.getStartPageToken();
      final id = await store.generateFileId();
      final name = '$syncTransportNamePrefix${'a' * 64}';
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      await store.createPacket(id, name, bytes);
      expect(await store.download(id), bytes);
      expect((await store.getFile(id)).packet, isTrue);
      expect((await store.listFiles()).files.single.id, id);
      expect((await store.listChanges(start)).files.single.id, id);
      await expectLater(
        store.createPacket(id, name, bytes),
        throwsA(issue(SyncTransportIssue.conflict)),
      );
      fixture.remove(id);
      expect((await store.listChanges('1')).files.single.removed, isTrue);
    },
  );

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
            requests++;
            return reply(200, {}, {'location': location});
          }),
        );
        await expectLater(
          store.createPacket(
            'file',
            '$syncTransportNamePrefix${'a' * 64}',
            Uint8List(4),
          ),
          throwsA(issue(SyncTransportIssue.invalid)),
        );
        expect(requests, 1);
      }
    },
  );

  test('safe error mapping, backoff and rejected cursors', () async {
    for (final entry in {
      401: SyncTransportIssue.unauthorized,
      403: SyncTransportIssue.forbidden,
      404: SyncTransportIssue.notFound,
      409: SyncTransportIssue.conflict,
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
        await store.getFile('file');
        fail('expected failure');
      } on SyncTransportFailure catch (e) {
        expect(e.issue, entry.value);
        expect(e.toString(), isNot(contains('DO_NOT_LEAK')));
        expect(e.retryAfter, const Duration(seconds: 15));
      }
    }
    final store = GoogleDriveSyncStore(
      tokens: FixtureTokens(),
      http: FakeHttp((m, u, h, b) async => reply(410)),
    );
    await expectLater(
      store.listChanges('old'),
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
        rate.generateFileId(),
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
          store.generateFileId(),
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
        incomplete.listFiles(),
        throwsA(issue(SyncTransportIssue.unavailable)),
      );
      final big = GoogleDriveSyncStore(
        tokens: FixtureTokens(),
        http: FakeHttp(
          (m, u, h, b) async => reply(200, {
            'id': 'x',
            'name': '$syncTransportNamePrefix${'a' * 64}',
            'mimeType': 'application/octet-stream',
            'spaces': ['appDataFolder'],
            'size': '${syncTransportPacketLimit + 1}',
          }),
        ),
      );
      await expectLater(
        big.getFile('x'),
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
      store.download('../x'),
      throwsA(issue(SyncTransportIssue.invalid)),
    );
    tokens.accountKey = 'other';
    await expectLater(
      store.generateFileId(),
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
}
