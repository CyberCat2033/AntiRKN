import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'secret_vault.dart';
import 'shared_access_token.dart';

abstract interface class GoogleAuthorizationBridge {
  Future<String?> authorize({required bool interactive, String? email});
  Future<void> clearToken();
}

abstract interface class PublicationGoogleAuthorizationBridge {
  Future<String?> authorizePublications({
    required bool interactive,
    String? email,
  });
}

final class MethodChannelGoogleAuthorization
    implements GoogleAuthorizationBridge, PublicationGoogleAuthorizationBridge {
  const MethodChannelGoogleAuthorization();
  static const _channel = MethodChannel('org.antirkn/google_authorization');
  @override
  Future<String?> authorize({required bool interactive, String? email}) =>
      _authorize(interactive: interactive, email: email);
  @override
  Future<String?> authorizePublications({
    required bool interactive,
    String? email,
  }) => _authorize(interactive: interactive, email: email, publications: true);
  Future<String?> _authorize({
    required bool interactive,
    String? email,
    bool publications = false,
  }) async {
    try {
      return await _channel.invokeMethod<String>('authorize', {
        'interactive': interactive,
        'email': email,
        if (publications) 'publications': true,
      });
    } on PlatformException catch (error) {
      throw GoogleAccountFailure(switch (error.code) {
        'google_configuration' => GoogleAccountIssue.configuration,
        'google_denied' => GoogleAccountIssue.denied,
        'google_network' => GoogleAccountIssue.network,
        'google_reauthorize' => GoogleAccountIssue.reauthorize,
        'google_busy' => GoogleAccountIssue.busy,
        _ => GoogleAccountIssue.unavailable,
      });
    } catch (_) {
      throw const GoogleAccountFailure(GoogleAccountIssue.unavailable);
    }
  }

  @override
  Future<void> clearToken() => _channel.invokeMethod<void>('clearToken');
}

final class _Token implements SyncAccessTokenProvider {
  const _Token(this.value);
  final String value;
  @override
  String get accountKey => 'authorization-identity-check';
  @override
  Future<String> accessToken() async => value;
}

/// Only account metadata is persisted in the platform's encrypted SecretStore.
/// Google Play services obtains/renews access tokens; our tokens stay in memory.
final class AndroidGoogleAccountService
    implements
        GoogleSyncAccountService,
        GooglePublicationAuthorization,
        RefreshableSyncAccessTokenProvider {
  AndroidGoogleAccountService({
    this.projectId = const String.fromEnvironment('ANTIRKN_GOOGLE_PROJECT_ID'),
    VaultKeyStore keys = const PlatformVaultKeyStore(),
    GoogleAuthorizationBridge bridge = const MethodChannelGoogleAuthorization(),
    DriveHttp? http,
    bool? supported,
    this.authorizationTimeout = const Duration(seconds: 25),
    this.tokenLifetime = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _keys = keys,
       _bridge = bridge,
       _http = http,
       _now = now ?? DateTime.now,
       supported = supported ?? Platform.isAndroid;
  final String projectId;
  final VaultKeyStore _keys;
  final GoogleAuthorizationBridge _bridge;
  final DriveHttp? _http;
  final DateTime Function() _now;

  /// A silent renewal that Play services never answers fails as a temporary
  /// network issue instead of stalling startup or sync.
  final Duration authorizationTimeout;

  /// Play services renews tokens but does not report their expiry. A token
  /// is reused this long (minus the cache margin), far below Google's hour,
  /// so bursts of requests share one renewal.
  final Duration tokenLifetime;
  late final _token = SharedAccessToken(now: _now);
  @override
  final bool supported;
  static const _storageId = 'google-drive-account-v1';
  GoogleDriveAccount? _account;
  String? _accountKey;
  bool _busy = false;
  @override
  bool publicationAuthorized = false;

  @override
  String get accountKey =>
      _accountKey ??
      (throw const SyncTransportFailure(SyncTransportIssue.unauthorized));

  Future<T> _operation<T>(Future<T> Function() action) async {
    if (_busy) throw const GoogleAccountFailure(GoogleAccountIssue.busy);
    _busy = true;
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
      _busy = false;
    }
  }

  void _checkConfiguration() {
    if (!supported) {
      throw const GoogleAccountFailure(GoogleAccountIssue.unavailable);
    }
    if (!RegExp(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$').hasMatch(projectId)) {
      throw const GoogleAccountFailure(GoogleAccountIssue.configuration);
    }
  }

  Future<void> _remember(GoogleDriveAccount? account) async {
    _token.clear();
    _account = account;
    _accountKey = account == null
        ? null
        : (await Sha256().hash(
            utf8.encode(
              jsonEncode([
                'drive-appdata-account-v1',
                projectId,
                account.permissionId,
              ]),
            ),
          )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  Future<GoogleDriveAccount?> restore() => _operation(() async {
    if (!supported) return null;
    final text = await _keys.read(_storageId);
    if (text == null) {
      publicationAuthorized = false;
      await _remember(null);
      return null;
    }
    final value = jsonDecode(text) as Map<String, dynamic>;
    if (value['project'] != projectId) {
      publicationAuthorized = false;
      await _remember(null);
      return null;
    }
    publicationAuthorized = value['publications'] == true;
    final account = GoogleDriveAccount.fromJson(
      value['account'] as Map<String, dynamic>,
    );
    await _remember(account);
    return account;
  });

  Future<GoogleDriveAccount> _identity(String token) =>
      GoogleDriveSyncStore(tokens: _Token(token), http: _http).readAccount();

  @override
  Future<GoogleDriveAccount?> signIn() => _signIn(true);
  @override
  Future<GoogleDriveAccount?> authorizePublications() => _signIn(true);
  Future<GoogleDriveAccount?> _signIn(bool publications) =>
      _operation(() async {
        _checkConfiguration();
        final token = publications
            ? await (_bridge as PublicationGoogleAuthorizationBridge)
                  .authorizePublications(interactive: true)
            : await _bridge.authorize(interactive: true);
        if (token == null) return null;
        final account = await _identity(token);
        await _keys.write(
          _storageId,
          jsonEncode({
            'project': projectId,
            'account': account.toJson(),
            'publications': publications,
          }),
        );
        await _remember(account);
        publicationAuthorized = publications;
        return account;
      });

  /// Concurrent callers share one silent renewal and one identity check.
  @override
  Future<String> accessToken() => _token.get(
    () => _operation(() async {
      _checkConfiguration();
      final account = _account;
      if (account == null) {
        throw const GoogleAccountFailure(GoogleAccountIssue.reauthorize);
      }
      final started = _now();
      final token =
          await (publicationAuthorized
                  ? (_bridge as PublicationGoogleAuthorizationBridge)
                        .authorizePublications(
                          interactive: false,
                          email: account.email,
                        )
                  : _bridge.authorize(interactive: false, email: account.email))
              .timeout(
                authorizationTimeout,
                onTimeout: () => throw const GoogleAccountFailure(
                  GoogleAccountIssue.network,
                ),
              );
      if (token == null) {
        throw const GoogleAccountFailure(GoogleAccountIssue.reauthorize);
      }
      if ((await _identity(token)).permissionId != account.permissionId) {
        throw const GoogleAccountFailure(GoogleAccountIssue.reauthorize);
      }
      return (token, started.add(tokenLifetime));
    }),
  );

  @override
  Future<void> invalidateAccessToken(String rejected) {
    _token.invalidate(rejected);
    return _bridge.clearToken();
  }

  @override
  Future<void> signOut() => _operation(() async {
    await _keys.delete(_storageId);
    await _remember(null);
    publicationAuthorized = false;
    // Cache cleanup may fail offline. Local sign-out still disables all access.
    try {
      await _bridge.clearToken();
    } catch (_) {}
  });
}
