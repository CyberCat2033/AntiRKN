import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:test/test.dart';

class Tokens
    implements SyncAccessTokenProvider, RefreshableSyncAccessTokenProvider {
  @override
  String accountKey = 'fixture-account';
  int rejected = 0;
  @override
  Future<String> accessToken() async => 'private-fixture-token';
  @override
  Future<void> invalidateAccessToken(String value) async {
    rejected++;
  }
}

class Http implements DriveHttp {
  final requests =
      <({String method, Uri uri, Map<String, String> headers, String? body})>[];
  late Future<DriveHttpResponse> Function(Uri) reply;
  @override
  Future<DriveHttpResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    required int responseLimit,
  }) async {
    requests.add((
      method: method,
      uri: uri,
      headers: headers,
      body: body == null ? null : utf8.decode(body),
    ));
    return reply(uri);
  }
}

DriveHttpResponse response(
  int status,
  Object body, [
  Map<String, String> headers = const {},
]) => DriveHttpResponse(
  status,
  headers,
  Uint8List.fromList(utf8.encode(body is String ? body : jsonEncode(body))),
);
Matcher issue(PublicationIssue value) =>
    isA<PublicationFailure>().having((e) => e.issue, 'issue', value);
void main() {
  late Tokens tokens;
  late Http http;
  late GoogleDrivePublisher drive;
  const file = PublicationFile(
    id: 'fixture',
    name: 'a.yml',
    mimeType: 'application/yaml',
    version: '7',
    etag: '"actual-etag"',
    editable: true,
    properties: {'retained': 'value'},
  );
  setUp(() {
    tokens = Tokens();
    http = Http()..reply = (_) async => response(200, {});
    drive = GoogleDrivePublisher(tokens: tokens, http: http);
  });
  test(
    'metadata and bytes use v2 real ETag; stale write never falls back',
    () async {
      await drive.updateFile(
        file,
        Uint8List.fromList(utf8.encode('mode: rule\n')),
        properties: {'antirknHead': 'new-head'},
      );
      final request = http.requests.single;
      expect(request.method, 'PUT');
      expect(request.uri.path, '/upload/drive/v2/files/fixture');
      expect(request.uri.queryParameters['uploadType'], 'multipart');
      expect(request.headers['If-Match'], '"actual-etag"');
      expect(request.body, contains('new-head'));
      expect(request.body, contains('retained'));
      expect(request.body, contains('antirknHash'));
      http.reply = (_) async =>
          response(412, {'error': 'private-provider-text'});
      await expectLater(
        drive.updateProperties(file, {'x': 'y'}),
        throwsA(issue(PublicationIssue.conflict)),
      );
      expect(http.requests, hasLength(2));
      expect(http.requests.last.uri.path, '/drive/v2/files/fixture');
    },
  );
  test('missing validators and oversized bytes fail before network', () async {
    const missing = PublicationFile(
      id: 'fixture',
      name: '',
      mimeType: '',
      version: '',
      etag: '',
      editable: true,
      properties: {},
    );
    await expectLater(
      drive.updateProperties(missing, {}),
      throwsA(issue(PublicationIssue.invalid)),
    );
    await expectLater(
      drive.updateFile(
        file,
        Uint8List(publicationProfileLimit + 1),
        properties: {},
      ),
      throwsA(issue(PublicationIssue.size)),
    );
    expect(http.requests, isEmpty);
  });
  test(
    'public redirects carry no credentials; foreign hosts and login HTML rejected',
    () async {
      final yaml = Uint8List.fromList(utf8.encode('mode: rule\n'));
      http.reply = (uri) async => uri.host == 'drive.google.com'
          ? response(302, '', {
              'location':
                  'https://drive.usercontent.google.com/download?id=fixture',
            })
          : response(200, 'mode: rule\n');
      await drive.verifyPublicLink(
        'https://drive.google.com/uc?id=fixture',
        yaml,
      );
      expect(http.requests.every((r) => r.headers.isEmpty), isTrue);
      http.reply = (_) async =>
          response(302, '', {'location': 'https://attacker.invalid/steal'});
      await expectLater(
        drive.verifyPublicLink('https://drive.google.com/uc?id=fixture', yaml),
        throwsA(issue(PublicationIssue.linkUnavailable)),
      );
      expect(http.requests.last.uri.host, 'drive.google.com');
      http.reply = (_) async => response(200, '<html>Sign in</html>');
      await expectLater(
        drive.verifyPublicLink('https://drive.google.com/uc?id=fixture', yaml),
        throwsA(issue(PublicationIssue.linkUnavailable)),
      );
    },
  );
  test(
    'permission recovery reuses link; private policy refuses anonymous file',
    () async {
      http.reply = (_) async => response(200, {
        'permissions': [
          {
            'id': 'anyoneWithLink',
            'type': 'anyone',
            'role': 'reader',
            'allowFileDiscovery': false,
          },
        ],
      });
      expect(await drive.enableLink('fixture'), 'anyoneWithLink');
      expect(http.requests.every((r) => r.method == 'GET'), isTrue);
      await expectLater(
        drive.checkPrivate('fixture'),
        throwsA(issue(PublicationIssue.conflict)),
      );
      http.reply = (_) async => response(200, {
        'permissions': [
          {'id': 'owner', 'type': 'user', 'role': 'owner'},
        ],
      });
      await drive.checkPrivate('fixture');
      await expectLater(
        drive.removeLink('fixture', 'owner'),
        throwsA(issue(PublicationIssue.conflict)),
      );
    },
  );
  test(
    '401 invalidates token; retry delay and changed account remain typed',
    () async {
      http.reply = (_) async => response(401, 'private-server-text');
      await expectLater(
        drive.getFile('fixture'),
        throwsA(issue(PublicationIssue.unauthorized)),
      );
      expect(tokens.rejected, 1);
      http.reply = (_) async => response(429, {}, {'retry-after': '120'});
      await expectLater(
        drive.getFile('fixture'),
        throwsA(
          isA<PublicationFailure>().having(
            (e) => e.retryAfter,
            'retry',
            const Duration(seconds: 120),
          ),
        ),
      );
      http.reply = (_) async => response(403, {
        'error': {
          'errors': [
            {'reason': 'userRateLimitExceeded'},
          ],
        },
      });
      await expectLater(
        drive.getFile('fixture'),
        throwsA(issue(PublicationIssue.rateLimited)),
      );
      tokens.accountKey = 'other';
      await expectLater(
        drive.getFile('fixture'),
        throwsA(issue(PublicationIssue.accountChanged)),
      );
      expect(http.requests, hasLength(3));
    },
  );
}
