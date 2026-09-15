import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';
import 'drive_http.dart';

const googleAppDataScope = 'https://www.googleapis.com/auth/drive.appdata';
const googleDriveFileScope = 'https://www.googleapis.com/auth/drive.file';

/// Runtime configuration only; endpoints are never taken from a local file.
final class GoogleDesktopClient {
  GoogleDesktopClient._(this.projectId, this.clientId, this.clientSecret);
  final String projectId, clientId, clientSecret;

  factory GoogleDesktopClient.parse(String text) {
    try {
      if (utf8.encode(text).length > 65536) throw const FormatException();
      final value =
          (jsonDecode(text) as Map<String, dynamic>)['installed']
              as Map<String, dynamic>;
      final project = value['project_id'], id = value['client_id'];
      final secret = value['client_secret'];
      if (project is! String ||
          !RegExp(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$').hasMatch(project) ||
          id is! String ||
          !RegExp(
            r'^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$',
          ).hasMatch(id) ||
          id.length > 256 ||
          secret is! String ||
          !RegExp(r'^[\x21-\x7e]{1,512}$').hasMatch(secret) ||
          value['auth_uri'] != 'https://accounts.google.com/o/oauth2/auth' ||
          value['token_uri'] != 'https://oauth2.googleapis.com/token') {
        throw const FormatException();
      }
      return GoogleDesktopClient._(project, id, secret);
    } catch (_) {
      throw const GoogleAccountFailure(GoogleAccountIssue.configuration);
    }
  }

  String encode() => jsonEncode({
    'installed': {
      'project_id': projectId,
      'client_id': clientId,
      'client_secret': clientSecret,
      'auth_uri': 'https://accounts.google.com/o/oauth2/auth',
      'token_uri': 'https://oauth2.googleapis.com/token',
    },
  });
  @override
  String toString() => 'GoogleDesktopClient(<private>)';
}

final class GoogleOAuthTokens {
  const GoogleOAuthTokens(this.accessToken, this.refreshToken, this.expiresIn);
  final String accessToken;
  final String? refreshToken;
  final Duration expiresIn;
  @override
  String toString() => 'GoogleOAuthTokens(<private>)';
}

/// A separate cancellation per attempt also invalidates late HTTP responses.
final class GoogleOAuthCancellation {
  final _done = Completer<void>();
  bool get cancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!cancelled) _done.complete();
  }
}

abstract interface class GoogleDesktopOAuth {
  Future<GoogleOAuthTokens?> authorize(
    GoogleDesktopClient client,
    GoogleOAuthCancellation cancellation,
  );
  Future<GoogleOAuthTokens> refresh(GoogleDesktopClient client, String token);
}

abstract interface class GooglePublicationOAuth {
  Future<GoogleOAuthTokens?> authorizePublications(
    GoogleDesktopClient client,
    GoogleOAuthCancellation cancellation,
  );
}

/// System browser + single-use IPv4 loopback callback, state and PKCE S256.
/// The browser sees neither client_secret nor the code verifier / tokens.
final class LoopbackGoogleOAuth
    implements GoogleDesktopOAuth, GooglePublicationOAuth {
  LoopbackGoogleOAuth({
    required this.openBrowser,
    DriveHttp? http,
    this.timeout = const Duration(minutes: 5),
  }) : _http = http ?? NativeDriveHttp();
  final Future<bool> Function(Uri) openBrowser;
  final DriveHttp _http;
  final Duration timeout;

  String _random() => base64UrlEncode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');

  @override
  Future<GoogleOAuthTokens?> authorize(
    GoogleDesktopClient client,
    GoogleOAuthCancellation cancellation,
  ) => _authorize(client, cancellation, false);
  @override
  Future<GoogleOAuthTokens?> authorizePublications(
    GoogleDesktopClient client,
    GoogleOAuthCancellation cancellation,
  ) => _authorize(client, cancellation, true);
  Future<GoogleOAuthTokens?> _authorize(
    GoogleDesktopClient client,
    GoogleOAuthCancellation cancellation,
    bool publications,
  ) async {
    if (cancellation.cancelled) return null;
    HttpServer? server;
    StreamSubscription<HttpRequest>? subscription;
    Timer? timer;
    final callback = Completer<String?>();
    GoogleAccountIssue? callbackIssue;
    try {
      final verifier = _random(), state = _random();
      final challenge = base64UrlEncode(
        (await Sha256().hash(ascii.encode(verifier))).bytes,
      ).replaceAll('=', '');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.autoCompress = false;
      server.idleTimeout = const Duration(seconds: 5);
      final redirect = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: '/oauth2/callback',
      );
      subscription = server.listen(
        (request) async {
          var valid = false;
          try {
            final uri = request.uri, params = uri.queryParametersAll;
            final states = params['state'], codes = params['code'];
            final errors = params['error'];
            final codeValid =
                codes?.length == 1 &&
                codes!.single.isNotEmpty &&
                codes.single.length <= 8192;
            final errorValid =
                errors?.length == 1 &&
                errors!.single.isNotEmpty &&
                errors.single.length <= 256;
            valid =
                !callback.isCompleted &&
                !cancellation.cancelled &&
                request.method == 'GET' &&
                uri.path == redirect.path &&
                uri.query.length <= 16384 &&
                request.headers.value(HttpHeaders.hostHeader) ==
                    redirect.authority &&
                states?.length == 1 &&
                states!.single == state &&
                ((codeValid && errors == null) ||
                    (errorValid && codes == null));
            // No reflected query, error, account or authorization code in HTML.
            request.response.statusCode = valid ? 200 : 400;
            request.response.headers
              ..contentType = ContentType.html
              ..set('Cache-Control', 'no-store')
              ..set('Referrer-Policy', 'no-referrer')
              ..set(
                'Content-Security-Policy',
                "default-src 'none'; frame-ancestors 'none'",
              )
              ..set('X-Content-Type-Options', 'nosniff');
            request.response.write(
              valid
                  ? '<!doctype html><meta charset="utf-8"><title>AntiRKN</title>'
                        '<p>Вернитесь в AntiRKN. Return to AntiRKN.</p>'
                  : '<!doctype html><meta charset="utf-8"><title>AntiRKN</title>'
                        '<p>Запрос отклонён. Request rejected.</p>',
            );
            if (valid) {
              if (codeValid) {
                callback.complete(codes.single);
              } else if (errors!.single == 'access_denied') {
                callback.complete(null);
              } else {
                callbackIssue = GoogleAccountIssue.configuration;
                callback.complete(null);
              }
            }
            await request.response.close();
          } catch (_) {
            try {
              await request.response.close();
            } catch (_) {}
          }
        },
        onError: (Object _) {
          if (!callback.isCompleted) {
            callbackIssue = GoogleAccountIssue.unavailable;
            callback.complete(null);
          }
        },
      );
      // Attach an error listener before launch, including synchronous callbacks.
      final result = Future.any<String?>([
        callback.future,
        cancellation.whenCancelled.then((_) => null),
      ]);
      timer = Timer(timeout, () {
        if (!callback.isCompleted) callback.complete(null);
      });
      final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': client.clientId,
        'redirect_uri': redirect.toString(),
        'response_type': 'code',
        'scope': publications
            ? '$googleAppDataScope $googleDriveFileScope'
            : googleAppDataScope,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'select_account consent',
      });
      if (cancellation.cancelled) return null;
      final opened = await openBrowser(
        uri,
      ).timeout(const Duration(seconds: 15));
      if (!opened) {
        throw const GoogleAccountFailure(GoogleAccountIssue.unavailable);
      }
      final code = await result;
      if (callbackIssue != null && !cancellation.cancelled) {
        throw GoogleAccountFailure(callbackIssue!);
      }
      if (code == null || cancellation.cancelled) return null;
      final tokens = await _tokens(
        client,
        {
          'grant_type': 'authorization_code',
          'code': code,
          'code_verifier': verifier,
          'redirect_uri': redirect.toString(),
        },
        requireRefresh: true,
        publications: publications,
      );
      return cancellation.cancelled ? null : tokens;
    } on GoogleAccountFailure {
      rethrow;
    } catch (_) {
      throw const GoogleAccountFailure(GoogleAccountIssue.unavailable);
    } finally {
      timer?.cancel();
      // Complete pending Futures even when opening the browser failed.
      if (!callback.isCompleted) callback.complete(null);
      await subscription?.cancel();
      await server?.close(force: true);
    }
  }

  @override
  Future<GoogleOAuthTokens> refresh(GoogleDesktopClient client, String token) =>
      _tokens(client, {'grant_type': 'refresh_token', 'refresh_token': token});

  Future<GoogleOAuthTokens> _tokens(
    GoogleDesktopClient client,
    Map<String, String> fields, {
    bool requireRefresh = false,
    bool publications = false,
  }) async {
    try {
      final response = await _http.send(
        'POST',
        Uri.https('oauth2.googleapis.com', '/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: Uint8List.fromList(
          utf8.encode(
            Uri(
              queryParameters: {
                'client_id': client.clientId,
                'client_secret': client.clientSecret,
                ...fields,
              },
            ).query,
          ),
        ),
        responseLimit: 65536,
      );
      if (response.bytes.length > 65536) throw const FormatException();
      if (response.status == 429 || response.status >= 500) {
        throw const GoogleAccountFailure(GoogleAccountIssue.network);
      }
      final value =
          jsonDecode(utf8.decode(response.bytes)) as Map<String, dynamic>;
      if (response.status != 200) {
        throw GoogleAccountFailure(switch (value['error']) {
          'invalid_grant' => GoogleAccountIssue.reauthorize,
          'access_denied' => GoogleAccountIssue.denied,
          'invalid_client' ||
          'unauthorized_client' ||
          'invalid_request' => GoogleAccountIssue.configuration,
          _ => GoogleAccountIssue.network,
        });
      }
      final token = value['access_token'], refresh = value['refresh_token'];
      final expiry = value['expires_in'], scope = value['scope'];
      bool valid(Object? value) =>
          value is String && RegExp(r'^[\x21-\x7e]{1,8192}$').hasMatch(value);
      if (!valid(token) ||
          value['token_type'] != 'Bearer' ||
          expiry is! int ||
          expiry < 1 ||
          expiry > 86400 ||
          (refresh != null && !valid(refresh))) {
        throw const FormatException();
      }
      if ((requireRefresh && (refresh == null || scope is! String)) ||
          (scope != null &&
              (scope is! String ||
                  (!scope.split(' ').contains(googleAppDataScope) ||
                      publications &&
                          !scope.split(' ').contains(googleDriveFileScope))))) {
        throw const GoogleAccountFailure(GoogleAccountIssue.denied);
      }
      return GoogleOAuthTokens(
        token as String,
        refresh as String?,
        Duration(seconds: expiry),
      );
    } on GoogleAccountFailure {
      rethrow;
    } catch (_) {
      throw const GoogleAccountFailure(GoogleAccountIssue.network);
    }
  }
}
