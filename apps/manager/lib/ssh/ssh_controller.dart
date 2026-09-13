import 'dart:async';
import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';

import '../network/network_controller.dart';

enum SshStage { idle, connecting, verifying, reading, connected }

final class SshDependencies {
  const SshDependencies({
    required this.openVault,
    required this.connector,
    required this.picker,
    this.agentAvailable = false,
  });
  final Future<SecretVault> Function() openVault;
  final SshConnector connector;
  final PrivateKeyFilePicker picker;
  final bool agentAvailable;
}

class SshController extends ChangeNotifier {
  SshController({
    required this.openVault,
    required this.connector,
    required this.picker,
    required this.network,
    this.agentAvailable = false,
    this.idleTimeout = const Duration(minutes: 5),
  }) {
    for (final field in fields) {
      field.addListener(
        field == masterPassword || field == masterConfirmation
            ? touch
            : _edited,
      );
    }
    _clock = Timer.periodic(const Duration(seconds: 10), (_) => network.tick());
  }
  final Future<SecretVault> Function() openVault;
  final SshConnector connector;
  final PrivateKeyFilePicker picker;
  final NetworkController network;
  final bool agentAvailable;
  final Duration idleTimeout;
  final serverName = TextEditingController();
  final host = TextEditingController();
  final port = TextEditingController(text: '22');
  final username = TextEditingController(text: 'root');
  final password = TextEditingController();
  final passphrase = TextEditingController();
  final masterPassword = TextEditingController();
  final masterConfirmation = TextEditingController();
  List<TextEditingController> get fields => [
    serverName,
    host,
    port,
    username,
    password,
    passphrase,
    masterPassword,
    masterConfirmation,
  ];
  SecretVault? _vault;
  VaultMode? mode;
  bool initialised = false;
  bool vaultBusy = false;
  bool picking = false;
  bool saved = false;
  bool settingsExpanded = true;
  bool replacingServer = false;
  VaultIssue? vaultError;
  SshIssue? error;
  String? keyName;
  String? _pem;
  SshAuthMethod authMethod = SshAuthMethod.password;
  SshStage stage = SshStage.idle;
  ServerObservation? observation;
  TrustedHostKey? challenge;
  Completer<bool>? _decision;
  SshConnection? _connection;
  CancellationToken? _cancellation;
  Timer? _idle;
  Timer? _clock;
  int _generation = 0;
  bool _disposed = false;
  bool get unlocked => _vault?.isUnlocked ?? false;
  bool get busy =>
      stage == SshStage.connecting ||
      stage == SshStage.verifying ||
      stage == SshStage.reading;
  bool get editing => unlocked && !busy && !vaultBusy && !picking;
  bool get hasSavedProfile => unlocked && _vault!.profile != null;
  String get displayName =>
      unlocked ? _vault!.profile?.displayName ?? host.text : '';
  bool get hasKey => _pem != null;
  TrustedHostKey? get trustedKey =>
      unlocked && _vault!.profile?.host == host.text.trim()
      ? _vault!.profile?.hostKey
      : null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _edited() {
    saved = false;
    touch();
    _notify();
  }

  void touch() {
    if (_disposed || !unlocked) return;
    _idle?.cancel();
    _idle = Timer(idleTimeout, lock);
  }

  Future<void> initialise() async {
    if (vaultBusy || _disposed) return;
    vaultBusy = true;
    vaultError = null;
    final generation = _generation;
    _notify();
    try {
      final vault = _vault ?? await openVault();
      if (_disposed || generation != _generation) {
        vault.lock();
        return;
      }
      _vault = vault;
      mode = await vault.inspect();
      if (!_disposed && generation == _generation) initialised = true;
    } on VaultFailure catch (e) {
      if (!_disposed) vaultError = e.issue;
    } catch (_) {
      if (!_disposed) vaultError = VaultIssue.unavailable;
    } finally {
      vaultBusy = false;
      _notify();
    }
  }

  Future<void> open({VaultMode? createMode}) async {
    if (!initialised || vaultBusy || _disposed) return;
    vaultBusy = true;
    vaultError = null;
    final generation = _generation;
    _notify();
    final secret = masterPassword.text;
    try {
      if (createMode == VaultMode.masterPassword &&
          secret != masterConfirmation.text) {
        throw const VaultFailure(VaultIssue.weakPassword);
      }
      if (createMode == null) {
        await _vault!.unlock(password: secret);
      } else {
        await _vault!.create(createMode, password: secret);
      }
      if (_disposed || generation != _generation) {
        _vault!.lock();
        return;
      }
      mode = await _vault!.inspect();
      if (_disposed || generation != _generation) {
        _vault!.lock();
        return;
      }
      _restore();
      touch();
    } on VaultFailure catch (e) {
      if (!_disposed) vaultError = e.issue;
    } catch (_) {
      if (!_disposed) vaultError = VaultIssue.unavailable;
    } finally {
      if (!_disposed) {
        masterPassword.clear();
        masterConfirmation.clear();
      }
      vaultBusy = false;
      _notify();
    }
  }

  void _restore() {
    final profile = _vault!.profile;
    serverName.text = profile?.name ?? '';
    host.text = profile?.host ?? '';
    port.text = '${profile?.port ?? 22}';
    username.text = profile?.username ?? 'root';
    password.text = profile?.secrets[ServerSecret.sshPassword] ?? '';
    passphrase.text = profile?.secrets[ServerSecret.keyPassphrase] ?? '';
    _pem = profile?.secrets[ServerSecret.privateKey];
    keyName = profile?.keyName;
    authMethod =
        profile?.authMethod ??
        (agentAvailable ? SshAuthMethod.agent : SshAuthMethod.password);
    saved = profile != null;
    settingsExpanded = profile == null;
  }

  void editSettings() {
    if (!editing) return;
    settingsExpanded = true;
    touch();
    _notify();
  }

  void cancelEditing() {
    if (!editing || !hasSavedProfile) return;
    _restore();
    error = null;
    vaultError = null;
    touch();
    _notify();
  }

  void setAuth(SshAuthMethod method) {
    if (!editing) return;
    authMethod = method;
    saved = false;
    touch();
    _notify();
  }

  Future<void> importKey() async {
    if (!editing) return;
    picking = true;
    error = null;
    final generation = _generation;
    _notify();
    ImportedPrivateKey? imported;
    try {
      imported = await picker.pick();
      if (_disposed || generation != _generation || imported == null) return;
      final pem = utf8.decode(imported.bytes);
      if (imported.name.toLowerCase().endsWith('.pub') ||
          pem.length > 262144 ||
          !RegExp(
            r'^-----BEGIN (OPENSSH |RSA |EC |ENCRYPTED )?PRIVATE KEY-----',
            multiLine: true,
          ).hasMatch(pem)) {
        throw const SshFailure(SshIssue.invalidKey);
      }
      _pem = pem;
      keyName = imported.name;
      passphrase.clear();
      authMethod = SshAuthMethod.privateKey;
      saved = false;
      touch();
    } catch (_) {
      if (!_disposed && generation == _generation) error = SshIssue.invalidKey;
    } finally {
      imported?.dispose();
      picking = false;
      _notify();
    }
  }

  SshProfile _draft() => SshProfile(
    name: serverName.text.trim(),
    host: host.text.trim(),
    port: int.tryParse(port.text) ?? 0,
    username: username.text.trim(),
    authMethod: authMethod,
    keyName: keyName,
    hostKey: trustedKey,
    secrets: {
      ...?_vault!.profile?.secrets,
      ServerSecret.sshPassword: password.text,
      ServerSecret.keyPassphrase: passphrase.text,
      ServerSecret.privateKey: ?_pem,
    },
  );

  Future<bool> save() async {
    if (!editing) return false;
    final previous = _vault!.profile;
    error = null;
    if (!await _saveDraft()) return false;
    final profile = _vault!.profile!;
    if (previous != null && !previous.hasSameConnectionSettings(profile)) {
      disconnect();
      observation = null;
      network.clear();
    }
    settingsExpanded = false;
    touch();
    _notify();
    return true;
  }

  Future<bool> _saveDraft() async {
    final profile = _draft();
    if (!profile.valid) {
      error = SshIssue.invalidSettings;
      _notify();
      return false;
    }
    vaultBusy = true;
    vaultError = null;
    saved = false;
    _notify();
    final generation = _generation;
    try {
      await _vault!.saveProfile(profile);
      if (_disposed || generation != _generation) return false;
      saved = true;
      return true;
    } on VaultFailure catch (e) {
      if (!_disposed && generation == _generation) vaultError = e.issue;
    } catch (_) {
      if (!_disposed && generation == _generation) {
        vaultError = VaultIssue.writeFailed;
      }
    } finally {
      vaultBusy = false;
      _notify();
    }
    return false;
  }

  Future<void> connect() => _connect();

  /// An explicit server replacement still requires fingerprint confirmation.
  Future<void> replaceServer() async {
    if (error != SshIssue.hostKeyChanged) return;
    await _connect(replaceServer: true);
  }

  Future<void> _connect({bool replaceServer = false}) async {
    if (!editing || _connection != null) return;
    error = null;
    replacingServer = replaceServer;
    stage = SshStage.connecting;
    final generation = _generation;
    touch();
    _notify();
    final cancellation = CancellationToken();
    _cancellation = cancellation;
    try {
      final previous = _vault!.profile;
      if (!await _saveDraft()) return;
      cancellation.check();
      final profile = _vault!.profile!;
      if (previous != null && !previous.hasSameConnectionSettings(profile)) {
        observation = null;
        network.clear();
      }
      final connection = await connector.connect(
        profile,
        cancellation: cancellation,
        verifyHostKey: (key) async {
          cancellation.check();
          if (profile.hostKey != null && !replaceServer) {
            if (!profile.hostKey!.matches(key)) {
              throw const SshFailure(SshIssue.hostKeyChanged);
            }
            return true;
          }
          stage = SshStage.verifying;
          challenge = key;
          _decision = Completer<bool>();
          _notify();
          final accepted = await cancellation.bind(_decision!.future);
          cancellation.check();
          challenge = null;
          _decision = null;
          if (!accepted) return false;
          try {
            await _vault!.saveProfile(profile.withHostKey(key));
          } catch (_) {
            throw const SshFailure(SshIssue.trustSaveFailed);
          }
          cancellation.check();
          if (replaceServer) {
            observation = null;
            network.clear();
          }
          stage = SshStage.connecting;
          _notify();
          return true;
        },
      );
      if (_disposed || generation != _generation || cancellation.isCancelled) {
        connection.close();
        return;
      }
      _connection = connection;
      unawaited(
        connection.done.then(
          (_) => _ended(connection),
          onError: (Object _) => _ended(connection),
        ),
      );
      stage = SshStage.reading;
      _notify();
      final next = await connection.observe(cancellation);
      if (_disposed || generation != _generation || cancellation.isCancelled) {
        return;
      }
      observation = next;
      network.accept(next.network);
      stage = SshStage.connected;
      settingsExpanded = false;
    } on SshFailure catch (e) {
      if (!_disposed && generation == _generation) {
        error = e.issue;
        _connection?.close();
        _connection = null;
      }
    } catch (_) {
      if (!_disposed && generation == _generation) {
        error = SshIssue.network;
        _connection?.close();
        _connection = null;
      }
    } finally {
      if (!_disposed && generation == _generation) {
        if (_connection == null) {
          stage = SshStage.idle;
          settingsExpanded = true;
        }
        challenge = null;
        _decision = null;
        replacingServer = false;
        _notify();
      }
    }
  }

  void _ended(SshConnection connection) {
    if (_disposed || _connection != connection) return;
    _connection = null;
    if (!busy) {
      stage = SshStage.idle;
      error = SshIssue.disconnected;
      _notify();
    }
  }

  void decide(bool accept) {
    touch();
    if (_decision?.isCompleted == false) _decision!.complete(accept);
  }

  Future<void> refresh() async {
    final connection = _connection;
    if (busy || connection == null || !unlocked) return;
    final generation = _generation;
    final cancellation = CancellationToken();
    _cancellation = cancellation;
    stage = SshStage.reading;
    error = null;
    touch();
    _notify();
    try {
      final next = await connection.observe(cancellation);
      if (!_disposed &&
          generation == _generation &&
          !cancellation.isCancelled) {
        observation = next;
        network.accept(next.network);
        stage = SshStage.connected;
      }
    } on SshFailure catch (e) {
      if (!_disposed && generation == _generation) error = e.issue;
      connection.close();
      if (_connection == connection) _connection = null;
    } catch (_) {
      if (!_disposed && generation == _generation) error = SshIssue.network;
      connection.close();
      if (_connection == connection) _connection = null;
    } finally {
      if (!_disposed && generation == _generation) {
        if (_connection == null) stage = SshStage.idle;
        _notify();
      }
    }
  }

  void disconnect() {
    _generation++;
    _cancellation?.cancel();
    _connection?.close();
    _connection = null;
    decide(false);
    _decision = null;
    challenge = null;
    replacingServer = false;
    stage = SshStage.idle;
    error = null;
    _notify();
  }

  Future<void> deleteProfile() async {
    if (!editing || _connection != null) return;
    vaultBusy = true;
    vaultError = null;
    final generation = _generation;
    _notify();
    try {
      await _vault!.saveProfile(null);
      if (!_disposed && generation == _generation) {
        _restore();
        network.clear();
        observation = null;
      }
    } on VaultFailure catch (e) {
      if (!_disposed) vaultError = e.issue;
    } finally {
      vaultBusy = false;
      _notify();
    }
  }

  void lock() {
    disconnect();
    _vault?.lock();
    _idle?.cancel();
    _pem = null;
    keyName = null;
    saved = false;
    observation = null;
    for (final field in fields) {
      field.clear();
    }
    network.clear();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    lock();
    _clock?.cancel();
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }
}
