import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'runner.dart';

import 'network/network_inventory.dart';
import 'server_inventory.dart';
import 'privileges.dart';

enum SshAuthMethod { password, privateKey, agent }

/// Separate slots: a sudo/root password is never used for SSH authentication.
enum ServerSecret {
  sshPassword,
  privateKey,
  keyPassphrase,
  sudoPassword,
  rootPassword,
  sshHardenRecovery,
}

final class SshProfile {
  SshProfile({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    this.name = '',
    this.id = serverId,
    Map<ServerSecret, String> secrets = const {},
    this.keyName,
    this.hostKey,
    this.lastInfo,
    this.jumpServerId,
  }) : secrets = Map.unmodifiable(secrets);
  static const serverId = 'primary-vps';
  final String id;
  final String name;
  String get displayName => name.trim().isEmpty ? host : name.trim();
  final String host;
  final int port;
  final String username;
  final SshAuthMethod authMethod;
  final Map<ServerSecret, String> secrets;
  final String? keyName;
  final TrustedHostKey? hostKey;
  final ServerInfo? lastInfo;
  final String? jumpServerId;

  bool get valid =>
      name.length <= 253 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) &&
      host.isNotEmpty &&
      host.length <= 253 &&
      !RegExp(r'[\s/\\\x00-\x1f]').hasMatch(host) &&
      port >= 1 &&
      port <= 65535 &&
      username.isNotEmpty &&
      username.length <= 128 &&
      !RegExp(r'[\s\x00-\x1f]').hasMatch(username) &&
      (authMethod == SshAuthMethod.agent ||
          (authMethod == SshAuthMethod.password
              ? (secrets[ServerSecret.sshPassword]?.isNotEmpty ?? false)
              : (secrets[ServerSecret.privateKey]?.isNotEmpty ?? false)));

  SshProfile withJumpServer(String? value) => SshProfile(
    id: id,
    name: name,
    host: host,
    port: port,
    username: username,
    authMethod: authMethod,
    secrets: secrets,
    keyName: keyName,
    hostKey: hostKey,
    lastInfo: lastInfo,
    jumpServerId: value,
  );

  SshProfile withHostKey(TrustedHostKey? value) => SshProfile(
    id: id,
    name: name,
    host: host,
    port: port,
    username: username,
    authMethod: authMethod,
    secrets: secrets,
    keyName: keyName,
    hostKey: value,
    lastInfo: value != null && (hostKey == null || hostKey!.matches(value))
        ? lastInfo
        : null,
    jumpServerId: jumpServerId,
  );

  SshProfile withInfo(ServerInfo value) => SshProfile(
    id: id,
    name: name,
    host: host,
    port: port,
    username: username,
    authMethod: authMethod,
    secrets: secrets,
    keyName: keyName,
    hostKey: hostKey,
    lastInfo: value,
    jumpServerId: jumpServerId,
  );

  SshProfile withHardenedAccess({
    required String user,
    required int port,
    required String sudoPassword,
  }) {
    final nextSecrets = Map<ServerSecret, String>.from(secrets);
    nextSecrets[ServerSecret.sudoPassword] = sudoPassword;
    if (authMethod == SshAuthMethod.password) {
      nextSecrets[ServerSecret.sshPassword] = sudoPassword;
    }
    return SshProfile(
      id: id,
      name: name,
      host: host,
      port: port,
      username: user,
      authMethod: authMethod,
      secrets: nextSecrets,
      keyName: keyName,
      hostKey: hostKey,
      lastInfo: lastInfo,
      jumpServerId: jumpServerId,
    );
  }

  /// Recovery credentials live inside the encrypted vault, never in UI settings.
  Map<String, dynamic>? get hardenRecovery {
    final source = secrets[ServerSecret.sshHardenRecovery];
    if (source == null) return null;
    final value = jsonDecode(source) as Map<String, dynamic>;
    if (value['version'] != 1 ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['jobId'] as String) ||
        value['host'] != host ||
        value['hostKey'] != hostKey?.fingerprint) {
      throw const FormatException('invalid_ssh_recovery');
    }
    return value;
  }

  SshProfile withHardenRecovery({
    required String jobId,
    required String user,
    required int port,
    required String password,
  }) {
    if (hardenRecovery != null || hostKey == null) {
      throw const FormatException('pending_ssh_recovery');
    }
    return _withAccessSecrets(username, this.port, {
      ...secrets,
      ServerSecret.sshHardenRecovery: jsonEncode({
        'version': 1,
        'jobId': jobId,
        'host': host,
        'hostKey': hostKey!.fingerprint,
        'oldUser': username,
        'oldPort': this.port,
        'oldSshPassword': secrets[ServerSecret.sshPassword],
        'oldSudoPassword': secrets[ServerSecret.sudoPassword],
        'user': user,
        'port': port,
        'password': password,
      }),
    });
  }

  SshProfile recoveredAccess({required bool hardened, bool clear = false}) {
    final recovery = hardenRecovery;
    if (recovery == null) throw const FormatException('missing_ssh_recovery');
    final values = Map<ServerSecret, String>.from(secrets);
    if (clear) values.remove(ServerSecret.sshHardenRecovery);
    if (hardened) {
      values[ServerSecret.sudoPassword] = recovery['password'] as String;
      if (authMethod == SshAuthMethod.password) {
        values[ServerSecret.sshPassword] = recovery['password'] as String;
      }
    } else {
      for (final entry in {
        ServerSecret.sshPassword: 'oldSshPassword',
        ServerSecret.sudoPassword: 'oldSudoPassword',
      }.entries) {
        values.remove(entry.key);
        if (recovery[entry.value] case final String value) {
          values[entry.key] = value;
        }
      }
    }
    return _withAccessSecrets(
      recovery[hardened ? 'user' : 'oldUser'] as String,
      recovery[hardened ? 'port' : 'oldPort'] as int,
      values,
    );
  }

  SshProfile _withAccessSecrets(
    String user,
    int nextPort,
    Map<ServerSecret, String> values,
  ) => SshProfile(
    id: id,
    name: name,
    host: host,
    port: nextPort,
    username: user,
    authMethod: authMethod,
    secrets: values,
    keyName: keyName,
    hostKey: hostKey,
    lastInfo: lastInfo,
    jumpServerId: jumpServerId,
  );

  /// Display metadata and inactive credentials do not affect a live session.
  bool hasSameConnectionSettings(SshProfile other) =>
      host == other.host &&
      port == other.port &&
      username == other.username &&
      authMethod == other.authMethod &&
      jumpServerId == other.jumpServerId &&
      switch (authMethod) {
        SshAuthMethod.agent => true,
        SshAuthMethod.password =>
          secrets[ServerSecret.sshPassword] ==
              other.secrets[ServerSecret.sshPassword],
        SshAuthMethod.privateKey =>
          secrets[ServerSecret.privateKey] ==
                  other.secrets[ServerSecret.privateKey] &&
              secrets[ServerSecret.keyPassphrase] ==
                  other.secrets[ServerSecret.keyPassphrase],
      };
  @override
  String toString() => 'SshProfile(redacted)';
}

final class TrustedHostKey {
  const TrustedHostKey(this.algorithm, this.fingerprint);
  final String algorithm;
  final String fingerprint;
  bool matches(TrustedHostKey other) =>
      algorithm == other.algorithm && fingerprint == other.fingerprint;
}

final class ImportedPrivateKey {
  // Platform channels may return an unmodifiable typed-data view. Own a
  // writable copy so cleanup cannot throw and leave the importer busy forever.
  ImportedPrivateKey({required this.name, required Uint8List bytes})
    : bytes = Uint8List.fromList(bytes);
  final String name;
  final Uint8List bytes;
  void dispose() => bytes.fillRange(0, bytes.length, 0);
  @override
  String toString() => 'ImportedPrivateKey(redacted)';
}

abstract interface class PrivateKeyFilePicker {
  Future<ImportedPrivateKey?> pick();
  Future<void> cancel();
}

enum SshIssue {
  invalidSettings,
  invalidKey,
  authentication,
  hostKeyChanged,
  hostKeyRejected,
  network,
  timeout,
  cancelled,
  commandFailed,
  outputLimit,
  invalidInventory,
  unsupportedOs,
  disconnected,
  trustSaveFailed,
  agentUnavailable,
  invalidJumpRoute,
  jumpHostKeyChanged,
  sudoPasswordRequired,
  sudoAuthenticationFailed,
  sudoDenied,
  sudoUnavailable,
  sudoTerminalRequired,
  invalidSudoPassword,
}

final class SshFailure implements Exception {
  const SshFailure(this.issue);
  final SshIssue issue;
  @override
  String toString() => 'SshFailure(${issue.name})';
}

final class CancellationToken {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled;
  void cancel() {
    if (isCancelled) return;
    _cancelled = true;
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void check() {
    if (isCancelled) throw const SshFailure(SshIssue.cancelled);
  }

  Future<T> bind<T>(Future<T> work) {
    final result = Completer<T>();
    void cancel() {
      if (!result.isCompleted) {
        result.completeError(const SshFailure(SshIssue.cancelled));
      }
    }

    if (isCancelled) {
      cancel();
    } else {
      _listeners.add(cancel);
    }
    // Remove completed operations so the token does not retain key material,
    // sockets or old inventories until the whole SSH session ends.
    unawaited(
      work.then(
        (value) {
          _listeners.remove(cancel);
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          _listeners.remove(cancel);
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    return result.future;
  }
}

abstract interface class SshConnector {
  Future<SshConnection> connect(
    SshProfile profile, {
    required Future<bool> Function(TrustedHostKey) verifyHostKey,
    required CancellationToken cancellation,
    List<SshProfile> jumpHosts = const [],
    Future<bool> Function(SshProfile, TrustedHostKey)? verifyJumpHostKey,
  });
}

/// Resolve saved references before any connection. Never fall back to direct
/// SSH when a configured intermediary is missing or cyclic.
List<SshProfile> resolveSshRoute(
  SshProfile target,
  Iterable<SshProfile> servers,
) {
  final catalog = {for (final profile in servers) profile.id: profile};
  final route = <SshProfile>[target];
  final visited = {target.id};
  var next = target.jumpServerId;
  while (next != null) {
    final profile = catalog[next];
    if (profile == null || !profile.valid || !visited.add(next)) {
      throw const SshFailure(SshIssue.invalidJumpRoute);
    }
    route.insert(0, profile);
    next = profile.jumpServerId;
  }
  return List.unmodifiable(route);
}

final class ServerObservation {
  const ServerObservation({
    required this.os,
    required this.architecture,
    required this.network,
    this.software,
    this.privilegeIssue,
  });
  final String os;
  final String architecture;
  final ServerNetworkInventory network;
  final ServerSoftwareInventory? software;
  final SshIssue? privilegeIssue;
}

abstract interface class SshConnection {
  RunnerTransport? get runner;

  /// [fresh] re-reads installed program versions instead of reusing the
  /// ones read earlier on this connection (needed after an install/update).
  Future<ServerObservation> observe(
    CancellationToken cancellation, {
    bool useSudo = false,
    String? sudoPassword,
    bool fresh = false,
  });
  Future<PrivilegeCheck> checkPrivileges(
    CancellationToken cancellation, {
    String? sudoPassword,
  });
  Future<void> get done;
  void close();
}
