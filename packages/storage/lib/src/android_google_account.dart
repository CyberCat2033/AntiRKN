import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'secret_vault.dart';

abstract interface class GoogleAuthorizationBridge {
  Future<String?> authorize({required bool interactive, String? email});
  Future<void> clearToken();
}

final class MethodChannelGoogleAuthorization
    implements GoogleAuthorizationBridge {
  const MethodChannelGoogleAuthorization();
  static const _channel = MethodChannel('org.antirkn/google_authorization');
  @override
  Future<String?> authorize({required bool interactive, String? email}) async {
    try {
      return await _channel.invokeMethod<String>('authorize', {
        'interactive': interactive,
        'email': email,
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
final class AndroidGoogleAccountService implements GoogleSyncAccountService {
  AndroidGoogleAccountService({
    this.projectId = const String.fromEnvironment('ANTIRKN_GOOGLE_PROJECT_ID'),
    VaultKeyStore keys = const PlatformVaultKeyStore(),
    GoogleAuthorizationBridge bridge = const MethodChannelGoogleAuthorization(),
    DriveHttp? http,
    bool? supported,
  }) : _keys = keys,
       _bridge = bridge,
       _http = http,
       supported = supported ?? Platform.isAndroid;
  final String projectId;
  final VaultKeyStore _keys;
  final GoogleAuthorizationBridge _bridge;
  final DriveHttp? _http;
  @override
  final bool supported;
  static const _storageId = 'google-drive-account-v1';
  GoogleDriveAccount? _account;
  String? _accountKey;
  bool _busy = false;

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
      await _remember(null);
      return null;
    }
    final value = jsonDecode(text) as Map<String, dynamic>;
    if (value['project'] != projectId) {
      await _remember(null);
      return null;
    }
    final account = GoogleDriveAccount.fromJson(
      value['account'] as Map<String, dynamic>,
    );
    await _remember(account);
    return account;
  });

  Future<GoogleDriveAccount> _identity(String token) =>
      GoogleDriveSyncStore(tokens: _Token(token), http: _http).readAccount();

  @override
  Future<GoogleDriveAccount?> signIn() => _operation(() async {
    _checkConfiguration();
    final token = await _bridge.authorize(interactive: true);
    if (token == null) return null;
    final account = await _identity(token);
    await _keys.write(
      _storageId,
      jsonEncode({'project': projectId, 'account': account.toJson()}),
    );
    await _remember(account);
    return account;
  });

  @override
  Future<String> accessToken() => _operation(() async {
    _checkConfiguration();
    final account = _account;
    if (account == null) {
      throw const GoogleAccountFailure(GoogleAccountIssue.reauthorize);
    }
    final token = await _bridge.authorize(
      interactive: false,
      email: account.email,
    );
    if (token == null) {
      throw const GoogleAccountFailure(GoogleAccountIssue.reauthorize);
    }
    if ((await _identity(token)).permissionId != account.permissionId) {
      throw const GoogleAccountFailure(GoogleAccountIssue.reauthorize);
    }
    return token;
  });

  @override
  Future<void> signOut() => _operation(() async {
    await _keys.delete(_storageId);
    await _remember(null);
    // Cache cleanup may fail offline. Local sign-out still disables all access.
    try {
      await _bridge.clearToken();
    } catch (_) {}
  });
}
