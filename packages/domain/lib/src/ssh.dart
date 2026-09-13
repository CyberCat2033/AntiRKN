import 'dart:async';
import 'dart:typed_data';

import 'network/network_inventory.dart';

enum SshAuthMethod { password, privateKey, agent }

/// Separate slots: a sudo/root password is never used for SSH authentication.
enum ServerSecret {
  sshPassword,
  privateKey,
  keyPassphrase,
  sudoPassword,
  rootPassword,
}

final class SshProfile {
  SshProfile({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    this.name = '',
    Map<ServerSecret, String> secrets = const {},
    this.keyName,
    this.hostKey,
  }) : secrets = Map.unmodifiable(secrets);
  static const serverId = 'primary-vps';
  final String name;
  String get displayName => name.trim().isEmpty ? host : name.trim();
  final String host;
  final int port;
  final String username;
  final SshAuthMethod authMethod;
  final Map<ServerSecret, String> secrets;
  final String? keyName;
  final TrustedHostKey? hostKey;

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

  SshProfile withHostKey(TrustedHostKey value) => SshProfile(
    name: name,
    host: host,
    port: port,
    username: username,
    authMethod: authMethod,
    secrets: secrets,
    keyName: keyName,
    hostKey: value,
  );

  /// Display metadata and inactive credentials do not affect a live session.
  bool hasSameConnectionSettings(SshProfile other) =>
      host == other.host &&
      port == other.port &&
      username == other.username &&
      authMethod == other.authMethod &&
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
  ImportedPrivateKey({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
  void dispose() => bytes.fillRange(0, bytes.length, 0);
  @override
  String toString() => 'ImportedPrivateKey(redacted)';
}

abstract interface class PrivateKeyFilePicker {
  Future<ImportedPrivateKey?> pick();
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
  });
}

final class ServerObservation {
  const ServerObservation({
    required this.os,
    required this.architecture,
    required this.network,
  });
  final String os;
  final String architecture;
  final ServerNetworkInventory network;
}

abstract interface class SshConnection {
  Future<ServerObservation> observe(CancellationToken cancellation);
  Future<void> get done;
  void close();
}
