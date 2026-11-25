import 'sync_transport.dart';

/// A gate owns the UI lock until receive and the model refresh finish. Returning
/// false keeps downloaded packets durable until the user finishes editing.
typedef SyncApplyGate = Future<bool> Function(Future<void> Function() receive);

final class AutoSyncResult {
  const AutoSyncResult({
    this.more = false,
    this.waitingForEditor = false,
    this.conflicts = 0,
    this.waitingGroups = 0,
    this.rejected = 0,
    this.otherWorkspaces = 0,
    this.lastSuccess,
    this.remoteNewer = false,
  });
  final bool more, waitingForEditor;

  /// The cloud holds a newer snapshot and this device has no unsent edits.
  /// Nothing was uploaded; the newer snapshot is received at the next pull.
  final bool remoteNewer;
  final int conflicts, waitingGroups, rejected, otherWorkspaces;
  final DateTime? lastSuccess;
}

abstract interface class AutoSyncSession {
  Future<AutoSyncResult> exchange({
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
    bool forceRecovery = false,
  });
  Future<void> close();
}
