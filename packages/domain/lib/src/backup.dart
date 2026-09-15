import 'dart:typed_data';

const maxWorkspaceBackupBytes = 64 * 1024 * 1024;

enum BackupIssue {
  password,
  invalid,
  version,
  tooLarge,
  changed,
  storage,
  file,
}

final class BackupFailure implements Exception {
  const BackupFailure(this.issue);
  final BackupIssue issue;
  @override
  String toString() => 'BackupFailure(${issue.name})';
}

final class BackupSummary {
  const BackupSummary({
    required this.createdAt,
    required this.workspaceId,
    required this.servers,
    required this.users,
    required this.changes,
    required this.pending,
  });
  final DateTime createdAt;
  final String workspaceId;
  final int servers, users, changes, pending;
}

/// An authenticated preview bound to the destination revision. Release it on
/// cancellation; restoring a changed destination requires another preview.
abstract interface class WorkspaceRestorePlan {
  BackupSummary get summary;
  void dispose();
}

abstract interface class WorkspaceBackupStore {
  Future<Uint8List> createBackup(String password);
  Future<WorkspaceRestorePlan> prepareRestore(Uint8List bytes, String password);

  /// Replaces local data atomically. Callers must reload their repositories and
  /// controllers afterwards. Does not execute server or publication operations.
  Future<void> restoreBackup(WorkspaceRestorePlan plan);
}

abstract interface class BackupFileStore {
  Future<Uint8List?> pick();
  Future<bool> save(Uint8List bytes);
}

/// Restored intentions require a new explicit decision before remote execution.
abstract interface class WorkspaceRecoveryStore {
  Future<Set<String>> readRestoredTargets();
  Future<void> approveRestoredTargets(Iterable<String> targets);
}
