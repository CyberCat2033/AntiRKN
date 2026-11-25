import 'sync_transport.dart';

/// A gate owns the UI lock until receive and the model refresh finish. Returning
/// false keeps the downloaded snapshot until the user finishes editing.
typedef SyncApplyGate = Future<bool> Function(Future<void> Function() receive);

/// One side of a divergence: when it was saved and by which device.
final class SyncVersionInfo {
  const SyncVersionInfo({this.savedAt, this.deviceName});
  final DateTime? savedAt;

  /// Readable name of the device that saved it, if it told.
  final String? deviceName;
}

/// Rare case of devices working in turn: this device has edits the cloud
/// does not have, and the cloud has a newer snapshot of the same workspace.
/// Nothing is merged or overwritten until the user chooses a side.
final class SyncDivergence {
  const SyncDivergence({required this.local, required this.cloud});
  final SyncVersionInfo local, cloud;
}

enum SyncDivergenceChoice {
  /// Upload this device's data over the cloud version.
  keepLocal,

  /// Replace this device's unsent edits with the cloud version.
  takeCloud,
}

final class AutoSyncResult {
  const AutoSyncResult({
    this.waitingForEditor = false,
    this.remoteNewer = false,
    this.received = false,
    this.divergence,
  });

  /// A newer cloud snapshot is downloaded and waits for editors and
  /// operations to finish; it is kept, not downloaded again.
  final bool waitingForEditor;

  /// The cloud holds a newer snapshot and this device has no unsent edits.
  /// Nothing was uploaded; the newer snapshot is received at the next pull.
  final bool remoteNewer;

  /// A newer cloud snapshot replaced local data: the owner reopens it.
  final bool received;

  /// Automatic exchange is paused until the user chooses a version.
  final SyncDivergence? divergence;
}

abstract interface class AutoSyncSession {
  /// Uploads unsent edits. With [forceRecovery] an unsent snapshot left by an
  /// earlier launch is retried first. With [enter] (launch, return to the
  /// app) a device with nothing to send then asks the cloud for its version
  /// and receives a newer one through [apply].
  Future<AutoSyncResult> exchange({
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
    bool forceRecovery = false,
    bool enter = false,
  });

  /// The user's explicit answer to a divergence. The result is confirmed by
  /// reading the cloud version or the local settings back.
  Future<AutoSyncResult> resolve(
    SyncDivergenceChoice choice, {
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
  });
  Future<void> close();
}
