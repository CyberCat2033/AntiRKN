import 'ssh.dart';

enum VaultMode { system, masterPassword }

enum VaultIssue {
  locked,
  unavailable,
  missingKey,
  incorrectPasswordOrDamaged,
  corrupt,
  writeFailed,
  busy,
  alreadyExists,
  weakPassword,
}

final class VaultFailure implements Exception {
  const VaultFailure(this.issue);
  final VaultIssue issue;
  @override
  String toString() => 'VaultFailure(${issue.name})';
}

abstract interface class SecretVault {
  bool get isUnlocked;
  Future<VaultMode?> inspect();
  Future<void> create(VaultMode mode, {String? password});
  Future<void> unlock({String? password});
  SshProfile? get profile;
  Future<void> saveProfile(SshProfile? profile);
  void lock();
}
