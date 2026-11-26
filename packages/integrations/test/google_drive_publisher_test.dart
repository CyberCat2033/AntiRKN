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
      http.reply = (_) async => response(200, {
        'id': 'fixture',
        'title': 'a.yml',
        'mimeType': 'application/yaml',
        'etag': '"next-etag"',
      });
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
  test(
    'created YAML is read back through v2 instead of trusting the v3 reply',
    () async {
      http.reply = (uri) async => uri.path == '/upload/drive/v3/files'
          // The real v3 create reply: no ETag, properties or capabilities.
          ? response(200, {
              'kind': 'drive#file',
              'id': 'fixture',
              'name': 'alice.yml',
              'mimeType': 'application/yaml',
            })
          : response(200, {
              'id': 'fixture',
              'title': 'alice.yml',
              'mimeType': 'application/yaml',
              'version': '2',
              'etag': '"created-etag"',
              'labels': {'trashed': false},
              'webContentLink': 'https://drive.google.com/uc?id=fixture',
              'capabilities': {'canEdit': true},
              'properties': [
                for (final p in {
                  'antirknWorkspace': 'w',
                  'antirknUser': 'u',
                  'antirknHead': 'h',
                  'antirknExecutor': 'e',
                  'antirknHash': 'x',
                }.entries)
                  {'key': p.key, 'value': p.value, 'visibility': 'PRIVATE'},
                {'key': 'foreign', 'value': 'v', 'visibility': 'PUBLIC'},
              ],
            });
      final created = await drive.createYaml(
        fileId: 'fixture',
        folderId: 'folder',
        name: 'alice.yml',
        workspaceId: 'w',
        userId: 'u',
        headId: 'h',
        executorId: 'e',
        bytes: Uint8List.fromList(utf8.encode('mode: rule\n')),
      );
      expect(http.requests.map((r) => '${r.method} ${r.uri.path}'), [
        'POST /upload/drive/v3/files',
        'GET /drive/v2/files/fixture',
      ]);
      expect(
        http.requests.last.uri.queryParameters['fields'],
        contains('etag'),
      );
      expect(created.editable, isTrue);
      expect(created.etag, '"created-etag"');
      expect(created.properties['antirknUser'], 'u');
      expect(created.properties['antirknHash'], 'x');
      expect(created.properties.containsKey('foreign'), isFalse);

      http.requests.clear();
      await drive.createRegistry(
        'fixture',
        'folder',
        'w',
        Uint8List.fromList(utf8.encode('{}')),
      );
      expect(http.requests.single.method, 'POST');

      http.reply = (_) async => response(200, {'kind': 'drive#file'});
      await expectLater(
        drive.createYaml(
          fileId: 'fixture',
          folderId: 'folder',
          name: 'alice.yml',
          workspaceId: 'w',
          userId: 'u',
          headId: 'h',
          executorId: 'e',
          bytes: Uint8List(1),
        ),
        throwsA(issue(PublicationIssue.invalid)),
      );
    },
  );
  test('update returns the stored file and never a guessed one', () async {
    http.reply = (_) async => response(200, {
      'id': 'fixture',
      'title': 'a.yml',
      'mimeType': 'application/yaml',
      'etag': '"next-etag"',
      'capabilities': {'canEdit': true},
      'properties': [
        {'key': 'antirknHash', 'value': 'stored', 'visibility': 'PRIVATE'},
      ],
    });
    final written = await drive.updateFile(
      file,
      Uint8List.fromList(utf8.encode('mode: rule\n')),
      properties: const {},
    );
    expect(written.etag, '"next-etag"');
    expect(written.properties['antirknHash'], 'stored');
    expect(
      http.requests.single.uri.queryParameters['fields'],
      contains('properties'),
    );
    http.reply = (_) async => response(200, {});
    await expectLater(
      drive.updateFile(file, Uint8List(1), properties: const {}),
      throwsA(issue(PublicationIssue.invalid)),
    );
  });
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
    'trash marks exactly the bound file using its ETag; stale delete has no fallback',
    () async {
      await drive.trashFile(file, 'd' * 32);
      final request = http.requests.single;
      expect(request.method, 'PATCH');
      expect(request.uri.path, '/drive/v2/files/fixture');
      expect(request.headers['If-Match'], file.etag);
      final body = jsonDecode(request.body!) as Map;
      expect(body['labels'], {'trashed': true});
      expect(
        body['properties'],
        contains(
          equals({
            'key': 'antirknDeleted',
            'value': 'd' * 32,
            'visibility': 'PRIVATE',
          }),
        ),
      );
      expect(
        body['properties'],
        contains(
          equals({
            'key': 'retained',
            'value': 'value',
            'visibility': 'PRIVATE',
          }),
        ),
      );
      http.reply = (_) async => response(412, {});
      await expectLater(
        drive.trashFile(file, 'd' * 32),
        throwsA(issue(PublicationIssue.conflict)),
      );
      expect(http.requests, hasLength(2));
      expect(
        http.requests.every(
          (r) => r.method == 'PATCH' && r.uri.path.endsWith('/fixture'),
        ),
        isTrue,
      );
    },
  );
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
