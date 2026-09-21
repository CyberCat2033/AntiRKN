import '../sync/guarded_runner_transport.dart';
import 'dart:async';
import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';

import '../network/network_controller.dart';
import '../runner/runner_controller.dart';

enum SshStage {
  idle,
  connecting,
  verifying,
  reading,
  checkingPrivileges,
  connected,
}

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
    this.serverId = SshProfile.serverId,
    this.agentAvailable = false,
    this.repository,
  }) {
    runner = RunnerController(
      serverId: serverId,
      store: repository is RunnerJournalStore
          ? repository as RunnerJournalStore
          : null,
      transport: () =>
          stage == SshStage.connected &&
              !settingsExpanded &&
              !vaultBusy &&
              !needsPrivilegeInput
          ? _guardRunner(_connection?.runner)
          : null,
      identity: () => unlocked && _vault!.profile?.hostKey != null
          ? '${_vault!.profile!.host}|${_vault!.profile!.hostKey!.fingerprint}'
          : null,
      password: () => isRoot ? null : _effectiveSudoPassword,
      accessFailure: recordPrivilegeFailure,
      software: () => software,
      refreshSoftware: () => unawaited(refresh()),
      connectForAction: ensureConnected,
    );
    runner.addListener(_notify);
    for (final field in fields) {
      field.addListener(_edited);
    }
    sudoPassword.addListener(() {
      if (_lastSudoDraft != sudoPassword.text) {
        _lastSudoDraft = sudoPassword.text;
        privileges = null;
        _notify();
      }
    });
    _clock = Timer.periodic(const Duration(seconds: 10), (_) => network.tick());
  }
  RunnerTransport? _guardRunner(RunnerTransport? transport) =>
      transport != null && repository is SyncEffectGuard
      ? GuardedRunnerTransport(transport, repository as SyncEffectGuard)
      : transport;
  final Future<SecretVault> Function() openVault;
  final SshConnector connector;
  final PrivateKeyFilePicker picker;
  final NetworkController network;
  final String serverId;
  final ServerRepository? repository;
  late final RunnerController runner;
  List<SavedServer> jumpCandidates = [];
  String? jumpServerId;
  SshProfile? verifyingProfile;
  List<SavedServer> get jumpOptions =>
      jumpCandidates.where((s) => s.id != serverId).toList();
  bool get showJumpPicker =>
      jumpCandidates.length > 1 ||
      (hasSavedProfile && jumpOptions.isNotEmpty) ||
      jumpServerId != null;
  String? get jumpName => jumpCandidates
      .where((s) => s.id == jumpServerId)
      .firstOrNull
      ?.profile
      .displayName;
  void updateJumpCandidates(List<SavedServer> servers) {
    jumpCandidates = servers;
    _notify();
  }

  final bool agentAvailable;
  final serverName = TextEditingController();
  final host = TextEditingController();
  final port = TextEditingController(text: '22');
  final username = TextEditingController(text: 'root');
  final password = TextEditingController();
  final passphrase = TextEditingController();
  final sudoPassword = TextEditingController();
  PrivilegeCheck? privileges;
  bool needsPrivilegeInput = false;
  bool get showPrivilegePrompt => needsPrivilegeInput && !isRoot;

  void _acceptPrivileges(PrivilegeCheck checked) {
    privileges = checked;
    needsPrivilegeInput = !checked.granted;
    _notify();
  }

  void recordPrivilegeFailure(SshIssue issue) {
    final status = switch (issue) {
      SshIssue.sudoPasswordRequired => PrivilegeStatus.passwordRequired,
      SshIssue.sudoAuthenticationFailed => PrivilegeStatus.authenticationFailed,
      SshIssue.sudoDenied => PrivilegeStatus.denied,
      SshIssue.sudoUnavailable => PrivilegeStatus.unavailable,
      SshIssue.sudoTerminalRequired => PrivilegeStatus.terminalRequired,
      SshIssue.invalidSudoPassword => PrivilegeStatus.invalidPassword,
      _ => null,
    };
    if (status != null) _acceptPrivileges(PrivilegeCheck(status));
  }

  Future<void> _automaticPrivileges(
    SshConnection connection,
    CancellationToken cancellation,
  ) async {
    // A rejected credential is retried only after the user submits the form.
    if (needsPrivilegeInput) return;
    stage = SshStage.checkingPrivileges;
    _notify();
    final checked = await connection.checkPrivileges(
      cancellation,
      sudoPassword: isRoot ? null : _effectiveSudoPassword,
    );
    cancellation.check();
    if (_disposed || _connection != connection) return;
    _acceptPrivileges(checked);
  }

  String _lastSudoDraft = '';
  bool get isRoot =>
      observation?.software?.facts[ServerFact.uid]?.value == '0' ||
      privileges?.status == PrivilegeStatus.root;
  bool get canCheckPrivileges =>
      stage == SshStage.connected &&
      !runner.busy &&
      !vaultBusy;
  String? get _effectiveSudoPassword {
    if (sudoPassword.text.isNotEmpty) return sudoPassword.text;
    if (password.text.isNotEmpty && authMethod == SshAuthMethod.password) {
      return password.text;
    }
    final profile = _vault?.profile;
    return profile?.authMethod == SshAuthMethod.password
        ? profile?.secrets[ServerSecret.sshPassword]
        : null;
  }

  List<TextEditingController> get fields => [
    serverName,
    host,
    port,
    username,
    password,
    passphrase,
    sudoPassword,
  ];
  SecretVault? _vault;
  bool initialised = false;
  bool vaultBusy = false;
  bool picking = false;
  bool get saved {
    final profile = unlocked ? _vault!.profile : null;
    if (profile == null) return false;
    final draft = _draft();
    return profile.name == draft.name &&
        profile.host == draft.host &&
        profile.port == draft.port &&
        profile.username == draft.username &&
        profile.authMethod == draft.authMethod &&
        profile.keyName == draft.keyName &&
        profile.jumpServerId == draft.jumpServerId &&
        ServerSecret.values.every(
          (key) => (profile.secrets[key] ?? '') == (draft.secrets[key] ?? ''),
        );
  }

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
  CancellationToken? _keyImport;
  Timer? _clock;
  int _generation = 0;
  bool _disposed = false;
  bool get unlocked => _vault?.isUnlocked ?? false;
  bool get busy =>
      stage == SshStage.connecting ||
      stage == SshStage.verifying ||
      stage == SshStage.reading ||
      stage == SshStage.checkingPrivileges;
  bool get editing =>
      unlocked && !busy && !runner.busy && !vaultBusy && !picking;
  bool get hasSavedProfile => unlocked && _vault!.profile != null;
  SshProfile? get profile => unlocked ? _vault?.profile : null;
  String get displayName =>
      unlocked ? _vault!.profile?.displayName ?? host.text : '';
  bool get hasKey => _pem != null;
  ServerInfo? get lastInfo => unlocked ? _vault!.profile?.lastInfo : null;
  String? get os => observation?.os ?? lastInfo?.os;
  ServerSoftwareInventory? get software =>
      observation?.software ?? lastInfo?.software;
  Map<String, dynamic>? _trafficBaseline;
  bool trafficStorageFailed = false;
  bool resettingTraffic = false;
  SettingsStore? get _trafficStore =>
      repository is SettingsStore ? repository as SettingsStore : null;
  bool get canResetTraffic => _trafficStore != null;
  ServerTrafficSnapshot? get trafficSample {
    final raw = software?.facts[ServerFact.networkTraffic]?.value;
    if (raw == null) return null;
    try {
      return ServerTrafficSnapshot.parse(raw);
    } on FormatException {
      return null;
    }
  }

  ServerTrafficSnapshot? get _matchingTrafficBaseline {
    final current = trafficSample, stored = _trafficBaseline;
    if (current == null ||
        stored == null ||
        stored['identity'] != runner.identity()) {
      return null;
    }
    try {
      final baseline = ServerTrafficSnapshot.parse(stored['sample'] as String);
      if (baseline.bootId != current.bootId ||
          baseline.interfaces != current.interfaces ||
          current.counters.entries.any(
            (e) =>
                e.value.$1 < baseline.counters[e.key]!.$1 ||
                e.value.$2 < baseline.counters[e.key]!.$2,
          )) {
        return null;
      }
      return baseline;
    } catch (_) {
      return null;
    }
  }

  (int, int)? get trafficBytes {
    final current = trafficSample;
    if (current == null || trafficStorageFailed) return null;
    final baseline = _matchingTrafficBaseline;
    return (
      current.received - (baseline?.received ?? 0),
      current.sent - (baseline?.sent ?? 0),
    );
  }

  DateTime? get trafficResetAt => _matchingTrafficBaseline == null
      ? null
      : DateTime.tryParse(_trafficBaseline?['resetAt'] as String? ?? '');

  Future<void> resetTraffic() async {
    if (resettingTraffic ||
        stage != SshStage.connected ||
        busy ||
        runner.busy ||
        _trafficStore == null) {
      return;
    }
    resettingTraffic = true;
    _notify();
    try {
      await refresh();
      if (_disposed || stage != SshStage.connected || trafficSample == null) {
        return;
      }
      final next = <String, dynamic>{
        'identity': runner.identity(),
        'sample':
            observation!.software!.facts[ServerFact.networkTraffic]!.value!,
        'resetAt': DateTime.now().toUtc().toIso8601String(),
      };
      await _trafficStore!.writeSetting(
        'serverTrafficBaseline:$serverId',
        jsonEncode(next),
      );
      if (!_disposed) {
        _trafficBaseline = next;
        trafficStorageFailed = false;
      }
    } catch (_) {
      if (!_disposed) trafficStorageFailed = true;
    } finally {
      resettingTraffic = false;
      _notify();
    }
  }

  TrustedHostKey? get trustedKey =>
      unlocked && _vault!.profile?.host == host.text.trim()
      ? _vault!.profile?.hostKey
      : null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _edited() {
    _notify();
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
      final mode = await vault.inspect();
      if (!_disposed && generation == _generation) {
        if (!vault.isUnlocked) {
          if (mode == null) {
            await vault.create(VaultMode.system);
          } else {
            await vault.unlock();
          }
        }
        if (_disposed || generation != _generation) {
          vault.lock();
          return;
        }
        _restore();
        try {
          final value = await _trafficStore?.readSetting(
            'serverTrafficBaseline:$serverId',
          );
          _trafficBaseline = value == null
              ? null
              : Map<String, dynamic>.from(jsonDecode(value) as Map);
          if (_trafficBaseline != null) {
            ServerTrafficSnapshot.parse(_trafficBaseline!['sample'] as String);
          }
          trafficStorageFailed = false;
        } catch (_) {
          trafficStorageFailed = true;
        }
        await runner.restoreLocal();
        jumpCandidates = await repository?.listServers() ?? [];
        initialised = true;
      }
    } on VaultFailure catch (e) {
      if (!_disposed) vaultError = e.issue;
    } catch (_) {
      if (!_disposed) vaultError = VaultIssue.unavailable;
    } finally {
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
    sudoPassword.text = profile?.secrets[ServerSecret.sudoPassword] ?? '';
    _pem = profile?.secrets[ServerSecret.privateKey];
    keyName = profile?.keyName;
    jumpServerId = profile?.jumpServerId;
    authMethod =
        profile?.authMethod ??
        (agentAvailable ? SshAuthMethod.agent : SshAuthMethod.password);
    settingsExpanded = profile == null;
  }

  void editSettings() {
    // Opening the form is independent from whether its fields are writable.
    if (!unlocked) return;
    settingsExpanded = true;
    _notify();
  }

  void closeSettings() {
    if (!unlocked || !saved) return;
    settingsExpanded = false;
    _notify();
  }

  void cancelEditing() {
    if (!editing || !hasSavedProfile) return;
    _restore();
    error = null;
    vaultError = null;
    _notify();
  }

  void setAuth(SshAuthMethod method) {
    if (!editing) return;
    authMethod = method;
    _notify();
  }

  void setJump(String? id) {
    if (!editing) return;
    jumpServerId = id;
    _notify();
  }

  Future<void> importKey() async {
    if (!editing) return;
    picking = true;
    error = null;
    final generation = _generation;
    final cancellation = CancellationToken();
    _keyImport = cancellation;
    _notify();
    ImportedPrivateKey? imported;
    try {
      final selection = picker.pick();
      unawaited(
        selection.then((late) {
          if (cancellation.isCancelled) late?.dispose();
        }, onError: (Object _) {}),
      );
      imported = await cancellation.bind(selection);
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
    } catch (_) {
      if (!_disposed &&
          generation == _generation &&
          !cancellation.isCancelled) {
        error = SshIssue.invalidKey;
      }
    } finally {
      try {
        imported?.dispose();
      } finally {
        if (_keyImport == cancellation) {
          _keyImport = null;
          picking = false;
        }
        _notify();
      }
    }
  }

  void cancelKeyImport() {
    _keyImport?.cancel();
    _keyImport = null;
    picking = false;
    unawaited(picker.cancel().catchError((Object _) {}));
    _notify();
  }

  SshProfile _draft() => SshProfile(
    id: serverId,
    name: serverName.text.trim(),
    host: host.text.trim(),
    port: int.tryParse(port.text) ?? 0,
    username: username.text.trim(),
    authMethod: authMethod,
    keyName: keyName,
    jumpServerId: jumpServerId,
    hostKey: trustedKey,
    lastInfo: _vault!.profile?.host == host.text.trim() ? lastInfo : null,
    secrets: {
      ...?_vault!.profile?.secrets,
      ServerSecret.sshPassword: password.text,
      ServerSecret.keyPassphrase: passphrase.text,
      ServerSecret.sudoPassword: sudoPassword.text,
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
    _notify();
    return true;
  }

  /// Persist both recovery routes before any server mutation or final commit.
  Future<void> persistHardenProfile(SshProfile updated) async {
    final current = _vault?.profile;
    if (current == null ||
        current.id != updated.id ||
        current.host != updated.host ||
        current.hostKey == null ||
        updated.hostKey == null ||
        !current.hostKey!.matches(updated.hostKey!)) {
      throw const VaultFailure(VaultIssue.writeFailed);
    }
    vaultBusy = true;
    _notify();
    try {
      await _vault!.saveProfile(updated);
      _restore();
      settingsExpanded = false;
    } on VaultFailure catch (e) {
      vaultError = e.issue;
      rethrow;
    } finally {
      vaultBusy = false;
      _notify();
    }
  }

  /// The same saved route and pinned keys apply to both verification connections.
  Future<SshConnection> openHardenConnection(
    SshProfile target,
    CancellationToken cancellation,
  ) async {
    if (target.hostKey == null) {
      throw const SshFailure(SshIssue.hostKeyRejected);
    }
    final candidates = await repository?.listServers() ?? jumpCandidates;
    final route = resolveSshRoute(target, candidates.map((s) => s.profile));
    final vaults = <SecretVault>[];
    try {
      final jumps = <SshProfile>[];
      for (final hop in route.take(route.length - 1)) {
        final vault = await repository!.openServer(hop.id);
        vaults.add(vault);
        if (!vault.isUnlocked) await vault.unlock();
        final profile = vault.profile;
        if (profile == null ||
            profile.id != hop.id ||
            profile.jumpServerId != hop.jumpServerId ||
            profile.hostKey == null) {
          throw const SshFailure(SshIssue.invalidJumpRoute);
        }
        jumps.add(profile);
      }
      cancellation.check();
      return await connector.connect(
        target,
        cancellation: cancellation,
        jumpHosts: jumps,
        verifyHostKey: (key) async => target.hostKey!.matches(key),
        verifyJumpHostKey: (hop, key) async => hop.hostKey!.matches(key),
      );
    } finally {
      for (final vault in vaults) {
        vault.lock();
      }
    }
  }

  Future<RunnerResponse> hardenRequest(
    RunnerRequest request,
    CancellationToken cancellation, {
    SshConnection? connection,
    String? password,
  }) async {
    final remote = _guardRunner((connection ?? _connection)?.runner);
    if (remote == null) throw const RunnerFailure(RunnerIssue.unavailable);
    return remote.request(
      request,
      cancellation,
      sudoPassword: password ?? _effectiveSudoPassword,
    );
  }

  /// A lost commit reply or process death must leave both access routes usable.
  Future<void> _recoverHardenedAccess(CancellationToken cancellation) async {
    final current = _vault!.profile!;
    final recovery = current.hardenRecovery;
    if (recovery == null) return;
    Object? failure;
    final old = current.recoveredAccess(hardened: false);
    final next = current.recoveredAccess(hardened: true);
    final candidates = current.username == next.username
        ? [next, old]
        : [old, next];
    for (final candidate in candidates) {
      SshConnection? connection;
      try {
        connection = await openHardenConnection(candidate, cancellation);
        final response = await hardenRequest(
          RunnerRequest.sshHardenStatus(recovery['jobId'] as String),
          cancellation,
          connection: connection,
          password:
              candidate.secrets[ServerSecret.sudoPassword] ??
              candidate.secrets[ServerSecret.sshPassword],
        );
        final result = response.sshHardenResult;
        if (response.code != 'ok' || result == null) {
          throw const RunnerFailure(RunnerIssue.unavailable);
        }
        final SshProfile selected;
        if (result.confirmed) {
          selected = current.recoveredAccess(hardened: true, clear: true);
        } else if (result.aborted ||
            result.phase == 'failed' ||
            result.phase == 'cancelled' ||
            result.phase == 'missing') {
          selected = current.recoveredAccess(hardened: false, clear: true);
        } else {
          selected = candidate;
        }
        if (selected.hardenRecovery == null) {
          await runner.clearHardenPending(recovery['jobId'] as String);
        }
        await persistHardenProfile(selected);
        return;
      } catch (e) {
        cancellation.check();
        failure = e;
      } finally {
        connection?.close();
      }
    }
    if (failure is SshFailure) throw failure;
    throw const SshFailure(SshIssue.network);
  }

  Future<bool> _saveDraft() async {
    if (saved) return true;
    final profile = _draft();
    if (!validSudoPassword(sudoPassword.text)) {
      error = SshIssue.invalidSudoPassword;
      _notify();
      return false;
    }
    if (!profile.valid) {
      error = SshIssue.invalidSettings;
      _notify();
      return false;
    }
    vaultBusy = true;
    vaultError = null;
    _notify();
    final generation = _generation;
    try {
      jumpCandidates = await repository?.listServers() ?? [];
      resolveSshRoute(profile, jumpCandidates.map((s) => s.profile));
      await _vault!.saveProfile(profile);
      if (_disposed || generation != _generation) return false;
      return true;
    } on SshFailure catch (e) {
      if (!_disposed && generation == _generation) error = e.issue;
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

  Future<bool> ensureConnected() async {
    if (_disposed || vaultBusy || picking) return false;
    if (stage != SshStage.connected) {
      if (!hasSavedProfile || !saved || busy) return false;
      await _connect();
    }
    if (_disposed || stage != SshStage.connected) return false;
    closeSettings();
    await runner.waitUntilIdle();
    return runner.connected;
  }

  Future<bool?> connectForDeletion() async {
    if (_disposed || busy || vaultBusy || picking || runner.busy) return null;
    if (stage == SshStage.connected) return true;
    if (!hasSavedProfile || !saved) return false;
    try {
      await _connect(interactive: false).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          disconnect();
        },
      );
      return !_disposed && stage == SshStage.connected;
    } catch (_) {
      return false;
    }
  }

  /// An explicit server replacement still requires fingerprint confirmation.
  Future<void> replaceServer() async {
    if (error != SshIssue.hostKeyChanged) return;
    await _connect(replaceServer: true);
  }

  Future<void> _connect({
    bool replaceServer = false,
    bool interactive = true,
  }) async {
    if (!editing || _connection != null) return;
    error = null;
    needsPrivilegeInput = false;
    replacingServer = replaceServer;
    stage = SshStage.connecting;
    final generation = _generation;
    _notify();
    final cancellation = CancellationToken();
    _cancellation = cancellation;
    final jumpVaults = <String, SecretVault>{};
    try {
      if (!replaceServer && _vault!.profile?.hardenRecovery != null) {
        await _recoverHardenedAccess(cancellation);
      }
      final previous = _vault!.profile;
      if (!await _saveDraft()) return;
      cancellation.check();
      final profile = _vault!.profile!;
      jumpCandidates = await repository?.listServers() ?? [];
      final route = resolveSshRoute(
        profile,
        jumpCandidates.map((s) => s.profile),
      );
      final jumps = <SshProfile>[];
      for (final jump in route.take(route.length - 1)) {
        final vault = await repository!.openServer(jump.id);
        jumpVaults[jump.id] = vault;
        if (!vault.isUnlocked) await vault.unlock();
        if (vault.profile == null) {
          throw const SshFailure(SshIssue.invalidJumpRoute);
        }
        final current = vault.profile!;
        if (current.id != jump.id ||
            current.jumpServerId != jump.jumpServerId) {
          throw const SshFailure(SshIssue.invalidJumpRoute);
        }
        jumps.add(current);
      }
      cancellation.check();
      if (previous != null && !previous.hasSameConnectionSettings(profile)) {
        observation = null;
        network.clear();
      }
      final connection = await connector.connect(
        replaceServer ? profile.withHostKey(null) : profile,
        cancellation: cancellation,
        jumpHosts: jumps,
        verifyJumpHostKey: (jump, key) => _verifyKey(
          jump,
          key,
          jumpVaults[jump.id]!,
          cancellation,
          isJump: true,
          interactive: interactive,
        ),
        verifyHostKey: (key) => _verifyKey(
          profile,
          key,
          _vault!,
          cancellation,
          replaceServer: replaceServer,
          interactive: interactive,
        ),
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
      await _automaticPrivileges(connection, cancellation);
      stage = SshStage.reading;
      _notify();
      final next = await connection.observe(
        cancellation,
        useSudo: privileges?.granted == true && !isRoot,
        sudoPassword: _effectiveSudoPassword,
      );
      if (_disposed || generation != _generation || cancellation.isCancelled) {
        return;
      }
      observation = next;
      if (next.privilegeIssue case final issue?) recordPrivilegeFailure(issue);
      network.accept(next.network);
      stage = SshStage.connected;
      settingsExpanded = false;
      await _remember(next);
      runner.connectionReady();
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
      for (final vault in jumpVaults.values) {
        vault.lock();
      }
      if (!_disposed && generation == _generation) {
        if (_connection == null) {
          stage = SshStage.idle;
          settingsExpanded = true;
        }
        challenge = null;
        verifyingProfile = null;
        _decision = null;
        replacingServer = false;
        _notify();
      }
    }
  }

  Future<bool> _verifyKey(
    SshProfile profile,
    TrustedHostKey key,
    SecretVault vault,
    CancellationToken cancellation, {
    bool replaceServer = false,
    bool isJump = false,
    bool interactive = true,
  }) async {
    cancellation.check();
    if (profile.hostKey != null && !replaceServer) {
      if (!profile.hostKey!.matches(key)) {
        throw SshFailure(
          isJump ? SshIssue.jumpHostKeyChanged : SshIssue.hostKeyChanged,
        );
      }
      return true;
    }
    if (!interactive) throw const SshFailure(SshIssue.hostKeyRejected);
    stage = SshStage.verifying;
    verifyingProfile = profile;
    challenge = key;
    _decision = Completer<bool>();
    _notify();
    final accepted = await cancellation.bind(_decision!.future);
    cancellation.check();
    challenge = null;
    verifyingProfile = null;
    _decision = null;
    if (!accepted) return false;
    try {
      await vault.saveProfile(profile.withHostKey(key));
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
  }

  void _ended(SshConnection connection) {
    if (_disposed || _connection != connection) return;
    _connection = null;
    runner.disconnected();
    privileges = null;
    if (!busy) {
      stage = SshStage.idle;
      error = SshIssue.disconnected;
      _notify();
    }
  }

  void decide(bool accept) {
    if (_decision?.isCompleted == false) _decision!.complete(accept);
  }

  Future<void> checkPrivileges() async {
    final connection = _connection;
    if (!canCheckPrivileges || connection == null) return;
    if (!validSudoPassword(_effectiveSudoPassword)) {
      _acceptPrivileges(const PrivilegeCheck(PrivilegeStatus.invalidPassword));
      _notify();
      return;
    }
    // Persist the separate password using the same encrypted profile store.
    // Connection fields are restored in the collapsed card, so this cannot
    // apply an unsaved address while an old SSH session remains open.
    final generation = _generation;
    stage = SshStage.checkingPrivileges;
    privileges = null;
    error = null;
    _notify();
    if (!await _saveDraft()) {
      if (!_disposed && generation == _generation) {
        stage = _connection == connection ? SshStage.connected : SshStage.idle;
        _notify();
      }
      return;
    }
    if (_disposed || generation != _generation) return;
    if (_connection != connection) {
      stage = SshStage.idle;
      error = SshIssue.disconnected;
      _notify();
      return;
    }
    final cancellation = CancellationToken();
    _cancellation = cancellation;
    final secret = _effectiveSudoPassword;
    stage = SshStage.checkingPrivileges;
    privileges = null;
    error = null;
    _notify();
    try {
      final checked = await connection.checkPrivileges(
        cancellation,
        sudoPassword: isRoot ? null : secret,
      );
      if (_disposed || generation != _generation) return;
      _acceptPrivileges(checked);
      if (checked.granted) {
        stage = SshStage.reading;
        _notify();
        final next = await connection.observe(
          cancellation,
          useSudo: checked.status != PrivilegeStatus.root,
          sudoPassword: secret,
        );
        if (_disposed || generation != _generation) return;
        observation = next;
        if (next.privilegeIssue case final issue?) {
          recordPrivilegeFailure(issue);
        }
        network.accept(next.network);
        await _remember(next);
      }
      if (!_disposed && generation == _generation) {
        stage = SshStage.connected;
        runner.connectionReady();
      }
    } on SshFailure catch (e) {
      if (!_disposed && generation == _generation) error = e.issue;
      connection.close();
      if (_connection == connection) _connection = null;
      privileges = null;
    } catch (_) {
      if (!_disposed && generation == _generation) error = SshIssue.network;
      connection.close();
      if (_connection == connection) _connection = null;
      privileges = null;
    } finally {
      if (!_disposed && generation == _generation) {
        if (_connection == null) stage = SshStage.idle;
        _notify();
      }
    }
  }

  Future<void> refresh() async {
    final connection = _connection;
    if (busy || runner.busy || vaultBusy || connection == null || !unlocked) {
      return;
    }
    final generation = _generation;
    final cancellation = CancellationToken();
    _cancellation = cancellation;
    stage = SshStage.reading;
    error = null;
    _notify();
    try {
      await _automaticPrivileges(connection, cancellation);
      stage = SshStage.reading;
      _notify();
      final next = await connection.observe(
        cancellation,
        useSudo: privileges?.granted == true && !isRoot,
        sudoPassword: _effectiveSudoPassword,
      );
      if (!_disposed &&
          generation == _generation &&
          !cancellation.isCancelled) {
        observation = next;
        if (next.privilegeIssue case final issue?) {
          recordPrivilegeFailure(issue);
        }
        network.accept(next.network);
        stage = SshStage.connected;
        await _remember(next);
        runner.connectionReady();
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
    runner.disconnected();
    _generation++;
    _cancellation?.cancel();
    _connection?.close();
    _connection = null;
    privileges = null;
    needsPrivilegeInput = false;
    decide(false);
    _decision = null;
    challenge = null;
    verifyingProfile = null;
    replacingServer = false;
    stage = SshStage.idle;
    error = null;
    _notify();
  }

  Future<void> _remember(ServerObservation next) async {
    final profile = _vault!.profile;
    if (profile == null) return;
    vaultBusy = true;
    _notify();
    try {
      await _vault!.saveProfile(
        profile.withInfo(
          ServerInfo(
            os: next.os,
            architecture: next.architecture,
            observedAt: next.network.observedAt,
            software: next.software,
            publicAddresses: List.unmodifiable(
              next.network.addresses
                  .where(
                    (address) => address.addressClass == AddressClass.external,
                  )
                  .map((address) => address.address),
            ),
          ),
        ),
      );
    } on VaultFailure catch (e) {
      if (!_disposed) vaultError = e.issue;
    } catch (_) {
      if (!_disposed) vaultError = VaultIssue.writeFailed;
    } finally {
      vaultBusy = false;
      _notify();
    }
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
    if (picking) cancelKeyImport();
    disconnect();
    _vault?.lock();
    _pem = null;
    keyName = null;
    observation = null;
    for (final field in fields) {
      field.clear();
    }
    network.clear();
    _notify();
  }

  @override
  void dispose() {
    runner.removeListener(_notify);
    runner.dispose();
    _disposed = true;
    lock();
    _clock?.cancel();
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }
}
