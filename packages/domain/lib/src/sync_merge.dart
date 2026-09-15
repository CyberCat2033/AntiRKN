import 'dart:typed_data';
import 'change_journal.dart';

enum SyncMergeIssue { invalid, changed, storage, conflict, limit }

final class SyncMergeFailure implements Exception {
  const SyncMergeFailure(this.issue);
  final SyncMergeIssue issue;
  @override
  String toString() => 'SyncMergeFailure(${issue.name})';
}

final class SyncConflict {
  SyncConflict({
    required this.kind,
    required this.entityId,
    required List<LocalChange> variants,
    this.ancestor,
  }) : variants = List.unmodifiable(variants);
  final ChangeEntityKind kind;
  final String entityId;
  final List<LocalChange> variants;
  final LocalChange? ancestor;
  List<String> get changeIds =>
      variants.map((v) => v.header.changeId).toList()..sort();
  @override
  String toString() => 'SyncConflict(<redacted>)';
}

final class SyncMergeStatus {
  SyncMergeStatus({
    required List<SyncConflict> conflicts,
    required List<String> missingChangeIds,
    required this.waitingGroups,
    required this.blockedGroups,
    this.rejectedGroups = 0,
    List<LocalChange> blockedChanges = const [],
  }) : blockedChanges = List.unmodifiable(blockedChanges),
       conflicts = List.unmodifiable(conflicts),
       missingChangeIds = List.unmodifiable(missingChangeIds);
  final List<SyncConflict> conflicts;
  final List<String> missingChangeIds;
  final int waitingGroups, blockedGroups, rejectedGroups;
  final List<LocalChange> blockedChanges;
}

/// Internal receive boundary for a workspace already authorized by its caller.
/// AEAD proves possession of the workspace key, not a device signature. The
/// caller must establish workspace membership before calling this. The owner
/// mode uses explicitly transferred workspace keys as membership credentials;
/// it does not claim per-device author signatures or revocation.
abstract interface class SyncMergeStore {
  Future<SyncMergeStatus> receiveSyncPackets(List<Uint8List> packets);
  Future<SyncMergeStatus> readSyncMergeStatus();
  Future<void> resolveSyncConflict(
    SyncConflict conflict,
    String selectedChangeId,
  );
  Future<SyncMergeStatus> retrySyncMerge();
}

/// Checked at the point an existing controller is about to contact the runner.
abstract interface class SyncEffectGuard {
  Future<void> checkSyncEffects();
}
