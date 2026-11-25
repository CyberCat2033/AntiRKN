import 'dart:typed_data';

/// Transport failures contain no tokens, URLs, response bodies or user data.
enum SyncTransportIssue {
  network,
  unauthorized,
  forbidden,
  rateLimited,
  unavailable,
  invalidCursor,
  notFound,
  conflict,
  invalid,
  limit,
  changed,
  storage,
  cancelled,

  /// The cloud snapshot was written by a newer app version: this device
  /// leaves it untouched until the app is updated.
  unsupportedVersion,
}

final class SyncTransportFailure implements Exception {
  const SyncTransportFailure(this.issue, {this.retryAfter});
  final SyncTransportIssue issue;
  final Duration? retryAfter;
  @override
  String toString() => 'SyncTransportFailure(${issue.name})';
}

final class SyncCancellation {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) {
      throw const SyncTransportFailure(SyncTransportIssue.cancelled);
    }
  }
}

/// OAuth adapter must pin these requests to one verified provider account.
/// The key binds the OAuth app namespace/project AND the provider account.
/// It is stable across platform clients in that project, never an email/token.
abstract interface class SyncAccessTokenProvider {
  String get accountKey;
  Future<String> accessToken();
}

/// A rejected cached token is refreshed on the next durable transport retry.
abstract interface class RefreshableSyncAccessTokenProvider {
  Future<void> invalidateAccessToken(String rejected);
}

/// A file in the private appDataFolder, as Drive reports it.
final class SyncRemoteFile {
  const SyncRemoteFile({
    required this.id,
    required this.name,
    required this.size,
    required this.version,
    this.removed = false,
    this.etag = '',
    this.createdAt,
  });
  final String id, name, version;
  final int size;
  final bool removed;

  /// Precondition for a conditional write; empty when the listing had none.
  final String etag;

  /// Orders duplicates created concurrently by several devices.
  final DateTime? createdAt;
}

/// One mutable workspace snapshot and one account-private encryption key.
/// Devices creating either at once may leave duplicates; every device picks
/// the same winner: the earliest created, then the smallest id.
abstract interface class SyncSnapshotStore {
  String get accountKey;
  Future<SyncRemoteFile?> findSnapshot();
  Future<Uint8List> readSnapshot(String fileId);

  /// Conditional write. [expected] (with its etag) is replaced only while it is
  /// still the current version; otherwise [SyncTransportIssue.conflict], and
  /// nothing is written. Null creates the snapshot; if another device's file
  /// wins, also conflict. Returns the written version as Drive reports it.
  Future<SyncRemoteFile> writeSnapshot(
    SyncRemoteFile? expected,
    Uint8List bytes,
  );
  Future<Uint8List?> readSnapshotKey();

  /// Creates the key unless one exists and returns the key every device uses,
  /// which may be another device's key created at the same time.
  Future<Uint8List> createSnapshotKey(Uint8List bytes);
}

const syncSnapshotName = 'antirkn-current-snapshot-v1';
const syncSnapshotKeyName = 'antirkn-current-snapshot-key-v1';
