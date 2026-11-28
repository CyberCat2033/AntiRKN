import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:cryptography/cryptography.dart';
import 'package:file_selector/file_selector.dart';
import 'package:url_launcher/url_launcher.dart';
import 'google_session_store.dart';
import 'shared_access_token.dart';

/// Existing private configuration is reused. Otherwise import it once through
/// the system picker; the session stores its contents encrypted, never its path.
Future<GoogleDesktopClient?> loadDesktopGoogleClient() async {
  try {
    final environment = Platform.environment;
    final root = Platform.isWindows
        ? environment['APPDATA']
        : environment['XDG_CONFIG_HOME'] ??
              (environment['HOME'] == null
                  ? null
                  : '${environment['HOME']}/.config');
    if (root != null) {
      final file = File('$root/antirkn/google/desktop-client.json');
      if (await file.exists()) {
        if (await file.length() > 65536) throw const FormatException();
        return GoogleDesktopClient.parse(await file.readAsString());
      }
    }
    final picked = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Google Desktop OAuth JSON',
          extensions: ['json'],
        ),
      ],
    );
    if (picked == null) return null;
    if (await picked.length() > 65536) throw const FormatException();
    return GoogleDesktopClient.parse(utf8.decode(await picked.readAsBytes()));
  } on GoogleAccountFailure {
    rethrow;
  } catch (_) {
    throw const GoogleAccountFailure(GoogleAccountIssue.configuration);
  }
}

final class _IdentityToken implements SyncAccessTokenProvider {
  const _IdentityToken(this.value);
  final String value;
  @override
  String get accountKey => 'desktop-identity-readback';
  @override
  Future<String> accessToken() async => value;
}

final class _Session {
  const _Session(
    this.client,
    this.account,
    this.refresh, {
    required this.id,
    this.reauthorize = false,
    this.publications = false,
  });
  final GoogleDesktopClient client;
  final GoogleDriveAccount account;
  final String refresh;
  final String id;
  final bool reauthorize, publications;
  String encode() => jsonEncode({
    'version': 1,
    'id': id,
    'client': client.encode(),
    'account': account.toJson(),
    'refresh': refresh,
    'reauthorize': reauthorize,
    'publications': publications,
  });
  factory _Session.decode(String text) {
    final value = jsonDecode(text) as Map<String, dynamic>;
    final refresh = value['refresh'], reauthorize = value['reauthorize'];
    final id = value['id'] ?? '0' * 64;
    if (value['version'] != 1 ||
        id is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        refresh is! String ||
        !RegExp(r'^[\x21-\x7e]{1,8192}$').hasMatch(refresh) ||
        reauthorize is! bool) {
      throw const FormatException();
    }
    return _Session(
      GoogleDesktopClient.parse(value['client'] as String),
      GoogleDriveAccount.fromJson(value['account'] as Map<String, dynamic>),
      refresh,
      id: id,
      reauthorize: reauthorize,
      publications: value['publications'] == true,
    );
  }
}

final class DesktopGoogleAccountService
    implements
        GoogleSyncAccountService,
        GooglePublicationAuthorization,
        CancelableGoogleSignIn,
        GoogleAccountProfileSource,
        RefreshableSyncAccessTokenProvider {
  DesktopGoogleAccountService({
    required this.store,
    GoogleDesktopOAuth? oauth,
    this.loadClient = loadDesktopGoogleClient,
    DriveHttp? http,
    DateTime Function()? now,
  }) : _oauth =
           oauth ??
           LoopbackGoogleOAuth(
             openBrowser: (uri) =>
                 launchUrl(uri, mode: LaunchMode.externalApplication),
           ),
       _http = http,
       _now = now ?? DateTime.now;
  final GoogleSessionStore store;
  final Future<GoogleDesktopClient?> Function() loadClient;
  final GoogleDesktopOAuth _oauth;
  final DriveHttp? _http;
  final DateTime Function() _now;
  _Session? _session;
  String? _stored, _accountKey;
  late final _access = SharedAccessToken(now: _now);
  Future<void>? _pending;
  GoogleOAuthCancellation? _cancellation;
  bool _closed = false;
  @override
  bool get supported => true;
  @override
  GoogleDriveAccount? get account => _session?.account;
  @override
  String get accountKey =>
      _accountKey ??
      (throw const SyncTransportFailure(SyncTransportIssue.unauthorized));

  Future<T> _operation<T>(
    Future<T> Function() action, {
    bool interactive = false,
  }) async {
    if (_closed) {
      throw const GoogleAccountFailure(GoogleAccountIssue.unavailable);
    }
    if (interactive && _pending != null) {
      throw const GoogleAccountFailure(GoogleAccountIssue.busy);
    }
    final previous = _pending;
    final done = Completer<void>();
    _pending = done.future;
    if (previous != null) {
      try {
        await previous;
      } catch (_) {}
    }
    if (_closed) {
      if (identical(_pending, done.future)) {
        _pending = null;
      }
      done.complete();
      throw const GoogleAccountFailure(GoogleAccountIssue.unavailable);
    }
    try {
      return await action();
    } on GoogleAccountFailure {
      rethrow;
    } on SyncTransportFailure catch (error) {
      throw GoogleAccountFailure(switch (error.issue) {
        SyncTransportIssue.unauthorized => GoogleAccountIssue.reauthorize,
        SyncTransportIssue.forbidden => GoogleAccountIssue.denied,
        _ => GoogleAccountIssue.network,
      });
    } catch (_) {
      throw const GoogleAccountFailure(GoogleAccountIssue.storage);
    } finally {
      if (identical(_pending, done.future)) {
        _pending = null;
      }
      done.complete();
    }
  }

  Future<void> _remember(_Session? value, String? encoded) async {
    _session = value;
    _stored = encoded;
    _access.clear();
    _accountKey = value == null
        ? null
        : (await Sha256().hash(
            utf8.encode(
              jsonEncode([
                'drive-appdata-account-v1',
                value.client.projectId,
                value.account.permissionId,
              ]),
            ),
          )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  Future<GoogleDriveAccount?> restore() => _operation(() async {
    final stored = await store.read();
    final session = stored == null ? null : _Session.decode(stored);
    await _remember(session, stored);
    return session?.account;
  });

  Future<GoogleDriveAccount> _identity(String access) => GoogleDriveSyncStore(
    tokens: _IdentityToken(access),
    http: _http,
  ).readAccount();

  @override
  Future<GoogleDriveAccount?> signIn() => _signIn(true);
  @override
  bool get publicationAuthorized =>
      _session?.publications == true && _session?.reauthorize != true;
  @override
  Future<GoogleDriveAccount?> authorizePublications() => _signIn(true);
  Future<GoogleDriveAccount?> _signIn(
    bool publications,
  ) => _operation(() async {
    final cancellation = GoogleOAuthCancellation();
    _cancellation = cancellation;
    try {
      // Read first even after a failed restore. Corrupt records cannot be
      // silently replaced, and a second process cannot overwrite a newer login.
      final expected = await store.read();
      final old = expected == null ? null : _Session.decode(expected);
      final client = old?.client ?? await loadClient();
      if (client == null || cancellation.cancelled) return null;
      final started = _now();
      final tokens = publications
          ? await (_oauth as GooglePublicationOAuth).authorizePublications(
              client,
              cancellation,
            )
          : await _oauth.authorize(client, cancellation);
      if (tokens == null || cancellation.cancelled) return null;
      final account = await _identity(tokens.accessToken);
      if (cancellation.cancelled) return null;
      if (tokens.refreshToken == null) {
        throw const GoogleAccountFailure(GoogleAccountIssue.reauthorize);
      }
      final session = _Session(
        client,
        account,
        tokens.refreshToken!,
        publications: publications,
        id: List.generate(
          32,
          (_) => Random.secure().nextInt(256),
        ).map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
      );
      final encoded = session.encode();
      await store.replace(expected, encoded);
      await _remember(session, encoded);
      _access.remember(tokens.accessToken, started.add(tokens.expiresIn));
      return account;
    } finally {
      _cancellation = null;
    }
  }, interactive: true);

  Future<void> _stillCurrent() async {
    if (await store.read() != _stored) {
      _access.invalidate();
      throw const GoogleAccountFailure(GoogleAccountIssue.reauthorize);
    }
  }

  @override
  Future<String> accessToken() => _operation(() async {
    final session = _session;
    if (session == null || session.reauthorize) {
      throw const GoogleAccountFailure(GoogleAccountIssue.reauthorize);
    }
    await _stillCurrent();
    // Operations run one at a time, so callers queued behind a renewal
    // find its token here.
    if (_access.fresh case final cached?) return cached;
    final started = _now();
    try {
      final tokens = await _oauth.refresh(session.client, session.refresh);
      final identity = await _identity(tokens.accessToken);
      if (identity.permissionId != session.account.permissionId) {
        throw const GoogleAccountFailure(GoogleAccountIssue.reauthorize);
      }
      await _stillCurrent();
      final rotated =
          tokens.refreshToken != null && tokens.refreshToken != session.refresh;
      // The same account may come with a newer profile (one stored before
      // the picture was kept has none); it is stored with the session.
      if (rotated || identity != session.account) {
        final next = _Session(
          session.client,
          identity,
          rotated ? tokens.refreshToken! : session.refresh,
          id: session.id,
          publications: session.publications,
        );
        final encoded = next.encode();
        try {
          await store.replace(_stored, encoded);
          await _remember(next, encoded);
        } catch (_) {
          // A new refresh token must be kept; a profile is decoration and
          // is tried again at the next renewal.
          if (rotated) rethrow;
        }
      }
      _access.remember(tokens.accessToken, started.add(tokens.expiresIn));
      return tokens.accessToken;
    } on GoogleAccountFailure catch (error) {
      _access.invalidate();
      if (error.issue == GoogleAccountIssue.reauthorize &&
          await store.read() == _stored) {
        final next = _Session(
          session.client,
          session.account,
          session.refresh,
          id: session.id,
          publications: session.publications,
          reauthorize: true,
        );
        final encoded = next.encode();
        await store.replace(_stored, encoded);
        await _remember(next, encoded);
      }
      rethrow;
    }
  });

  @override
  Future<void> invalidateAccessToken(String rejected) =>
      _operation(() async => _access.invalidate(rejected));

  @override
  Future<void> signOut() => _operation(() async {
    await store.replace(_stored, null);
    await _remember(null, null);
  });

  @override
  void cancelSignIn() => _cancellation?.cancel();
  @override
  Future<void> close() async {
    _closed = true;
    cancelSignIn();
    await _pending;
    await _remember(null, null);
  }
}
