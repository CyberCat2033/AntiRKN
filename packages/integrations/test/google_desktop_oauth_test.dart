import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

final fixtureClientJson = jsonEncode({
  'installed': {
    'project_id': 'public-project',
    'client_id': '123-desktop.apps.googleusercontent.com',
    'client_secret': 'public-test-client-secret',
    'auth_uri': 'https://accounts.google.com/o/oauth2/auth',
    'token_uri': 'https://oauth2.googleapis.com/token',
  },
});

class TokenHttp implements DriveHttp {
  final requests = <Map<String, String>>[];
  int status = 200;
  Map<String, Object?> response = {
    'access_token': 'public-test-access',
    'refresh_token': 'public-test-refresh',
    'expires_in': 3600,
    'token_type': 'Bearer',
    'scope': googleAppDataScope,
  };
  Future<void> Function()? beforeResponse;
  @override
  Future<DriveHttpResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    required int responseLimit,
  }) async {
    expect(method, 'POST');
    expect(uri.toString(), 'https://oauth2.googleapis.com/token');
    expect(headers, {'Content-Type': 'application/x-www-form-urlencoded'});
    requests.add(Uri.splitQueryString(utf8.decode(body!)));
    await beforeResponse?.call();
    return DriveHttpResponse(
      status,
      {},
      Uint8List.fromList(utf8.encode(jsonEncode(response))),
    );
  }
}

Future<(int, String)> callback(
  Uri url,
  Map<String, dynamic> params, {
  String? path,
  String method = 'GET',
  String? host,
}) async {
  final http = HttpClient();
  try {
    final uri = Uri.parse(
      url.queryParameters['redirect_uri']!,
    ).replace(path: path, queryParameters: params);
    final request = await http.openUrl(method, uri);
    if (host != null) request.headers.set('Host', host);
    final response = await request.close();
    expect(response.headers.value('cache-control'), 'no-store');
    return (response.statusCode, await utf8.decoder.bind(response).join());
  } finally {
    http.close(force: true);
  }
}

Matcher issue(GoogleAccountIssue value) =>
    isA<GoogleAccountFailure>().having((e) => e.issue, 'issue', value);

void main() {
  final client = GoogleDesktopClient.parse(fixtureClientJson);
  test(
    'client import rejects web type, malicious endpoints, oversized or malformed content',
    () {
      for (final text in [
        '{}',
        '{',
        'x' * 65537,
        fixtureClientJson.replaceFirst('installed', 'web'),
        fixtureClientJson.replaceFirst(
          'oauth2.googleapis.com',
          'attacker.invalid',
        ),
        fixtureClientJson.replaceFirst('123-desktop', 'bad\nclient'),
      ]) {
        expect(
          () => GoogleDesktopClient.parse(text),
          throwsA(issue(GoogleAccountIssue.configuration)),
        );
      }
      expect(
        GoogleDesktopClient.parse(client.encode()).clientId,
        client.clientId,
      );
      expect(client.toString(), isNot(contains('public-test-client-secret')));
    },
  );

  test(
    'real loopback: reject forgery/duplicates/host/path/method; single code bound to PKCE',
    () async {
      final http = TokenHttp();
      late Uri launched;
      final oauth = LoopbackGoogleOAuth(
        http: http,
        openBrowser: (url) async {
          launched = url;
          final state = url.queryParameters['state']!;
          expect(url.scheme, 'https');
          expect(url.host, 'accounts.google.com');
          expect(url.queryParameters['access_type'], 'offline');
          expect(url.queryParameters['scope'], googleAppDataScope);
          expect(url.toString(), isNot(contains(client.clientSecret)));
          final good = {'state': state, 'code': 'public-code-fixture'};
          for (final params in <Map<String, dynamic>>[
            {...good, 'state': 'forged'},
            {
              ...good,
              'state': [state, state],
            },
            {
              ...good,
              'code': ['one', 'two'],
            },
            {...good, 'error': 'access_denied'},
          ]) {
            expect((await callback(url, params)).$1, 400);
          }
          expect((await callback(url, good, path: '/wrong')).$1, 400);
          expect((await callback(url, good, method: 'POST')).$1, 400);
          expect((await callback(url, good, host: 'attacker.invalid')).$1, 400);
          final accepted = await callback(url, good);
          expect(accepted.$1, 200);
          expect(accepted.$2, isNot(contains(good['code'])));
          expect((await callback(url, good)).$1, 400);
          return true;
        },
      );
      final tokens = await oauth.authorize(client, GoogleOAuthCancellation());
      expect(tokens!.refreshToken, 'public-test-refresh');
      expect(http.requests, hasLength(1));
      final exchange = http.requests.single;
      expect(exchange['code'], 'public-code-fixture');
      expect(
        exchange['redirect_uri'],
        launched.queryParameters['redirect_uri'],
      );
      expect(exchange['client_secret'], client.clientSecret);
      expect(exchange['code_verifier']!.length, inInclusiveRange(43, 128));
      final challenge = base64UrlEncode(
        (await Sha256().hash(ascii.encode(exchange['code_verifier']!))).bytes,
      ).replaceAll('=', '');
      expect(challenge, launched.queryParameters['code_challenge']);
      expect(launched.queryParameters['code_challenge_method'], 'S256');
      final socket = HttpClient();
      addTearDown(() => socket.close(force: true));
      await expectLater(
        socket.getUrl(Uri.parse(exchange['redirect_uri']!)),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test(
    'denial, cancellation, timeout and browser failure close listener without token exchange',
    () async {
      for (final kind in [
        'deny',
        'cancel',
        'timeout',
        'browser',
        'configuration',
      ]) {
        final http = TokenHttp(), cancellation = GoogleOAuthCancellation();
        final oauth = LoopbackGoogleOAuth(
          http: http,
          timeout: const Duration(milliseconds: 50),
          openBrowser: (url) async {
            if (kind == 'deny' || kind == 'configuration') {
              await callback(url, {
                'state': url.queryParameters['state']!,
                'error': kind == 'deny' ? 'access_denied' : 'invalid_request',
              });
            }
            if (kind == 'cancel') cancellation.cancel();
            return kind != 'browser';
          },
        );
        final result = oauth.authorize(client, cancellation);
        if (kind == 'browser' || kind == 'configuration') {
          await expectLater(
            result,
            throwsA(
              issue(
                kind == 'browser'
                    ? GoogleAccountIssue.unavailable
                    : GoogleAccountIssue.configuration,
              ),
            ),
          );
        } else {
          expect(await result, isNull);
        }
        expect(http.requests, isEmpty);
      }
    },
  );

  test(
    'cancel during HTTP exchange discards late tokens; each attempt gets fresh state and verifier',
    () async {
      final http = TokenHttp();
      final states = <String>[];
      late GoogleOAuthCancellation cancel;
      http.beforeResponse = () async => cancel.cancel();
      final oauth = LoopbackGoogleOAuth(
        http: http,
        openBrowser: (url) async {
          states.add(url.queryParameters['state']!);
          await callback(url, {'state': states.last, 'code': 'public-code'});
          return true;
        },
      );
      for (var i = 0; i < 2; i++) {
        cancel = GoogleOAuthCancellation();
        expect(await oauth.authorize(client, cancel), isNull);
      }
      expect(states.toSet(), hasLength(2));
      expect(
        http.requests.map((v) => v['code_verifier']).toSet(),
        hasLength(2),
      );
    },
  );

  test(
    'incremental consent requests both scopes and rejects partial grant',
    () async {
      final http = TokenHttp();
      final oauth = LoopbackGoogleOAuth(
        http: http,
        openBrowser: (url) async {
          expect(url.queryParameters['scope']!.split(' ').toSet(), {
            googleAppDataScope,
            googleDriveFileScope,
          });
          await callback(url, {
            'state': url.queryParameters['state']!,
            'code': 'fixture',
          });
          return true;
        },
      );
      await expectLater(
        oauth.authorizePublications(client, GoogleOAuthCancellation()),
        throwsA(issue(GoogleAccountIssue.denied)),
      );
      http.response['scope'] = '$googleAppDataScope $googleDriveFileScope';
      expect(
        await oauth.authorizePublications(client, GoogleOAuthCancellation()),
        isNotNull,
      );
    },
  );
  test(
    'refresh body, token rotation, scope checks and sanitized provider errors',
    () async {
      final http = TokenHttp();
      final oauth = LoopbackGoogleOAuth(
        http: http,
        openBrowser: (_) async => throw StateError('must not open browser'),
      );
      expect(
        (await oauth.refresh(client, 'public-old-refresh')).refreshToken,
        'public-test-refresh',
      );
      expect(http.requests.single['grant_type'], 'refresh_token');
      expect(http.requests.single['refresh_token'], 'public-old-refresh');
      http.response.remove('refresh_token');
      http.response.remove('scope');
      expect(
        (await oauth.refresh(client, 'public-old-refresh')).refreshToken,
        isNull,
      );
      http.response['scope'] = 'https://www.googleapis.com/auth/drive.file';
      await expectLater(
        oauth.refresh(client, 'fixture'),
        throwsA(issue(GoogleAccountIssue.denied)),
      );
      for (final entry in {
        'invalid_grant': GoogleAccountIssue.reauthorize,
        'invalid_client': GoogleAccountIssue.configuration,
        'access_denied': GoogleAccountIssue.denied,
      }.entries) {
        http.status = 400;
        http.response = {
          'error': entry.key,
          'error_description': 'private-provider-content',
        };
        try {
          await oauth.refresh(client, 'fixture');
          fail('expected error');
        } on GoogleAccountFailure catch (error) {
          expect(error.issue, entry.value);
          expect(error.toString(), isNot(contains('private-provider-content')));
        }
      }
    },
  );
}
