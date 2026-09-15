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

final class SyncRemoteFile {
  const SyncRemoteFile({
    required this.id,
    required this.name,
    required this.size,
    required this.version,
    required this.packet,
    this.removed = false,
  });
  final String id, name, version;
  final int size;
  final bool packet, removed;
}

final class SyncRemotePage {
  SyncRemotePage({
    required List<SyncRemoteFile> files,
    this.nextPageToken,
    this.newStartPageToken,
  }) : files = List.unmodifiable(files);
  final List<SyncRemoteFile> files;
  final String? nextPageToken, newStartPageToken;
}

/// Opaque immutable object delivery only; no merge, publication or device trust.
abstract interface class SyncRemoteStore {
  String get accountKey;
  Future<String> generateFileId();
  Future<void> createPacket(String fileId, String name, Uint8List bytes);
  Future<SyncRemoteFile> getFile(String fileId);
  Future<Uint8List> download(String fileId);
  Future<String> getStartPageToken();
  Future<SyncRemotePage> listFiles({String? pageToken});
  Future<SyncRemotePage> listChanges(String pageToken);
}

/// Capture startToken BEFORE enumeration. Then replay changes from that token.
final class SyncTransportCursor {
  const SyncTransportCursor({
    this.revision = 0,
    this.startToken,
    this.listing = true,
    this.pageToken,
    this.lastDownloadAt,
  });
  final int revision;
  final String? startToken, pageToken;
  final bool listing;
  final DateTime? lastDownloadAt;
}

final class SyncUploadReceipt {
  const SyncUploadReceipt({
    required this.changeId,
    required this.fileId,
    required this.digest,
    required this.size,
    this.confirmed = false,
  });
  final String changeId, fileId, digest;
  final int size;
  final bool confirmed;
}

/// Untrusted cloud bytes. Only the future device authorization layer may pass
/// them to SyncMergeStore. A removed object is NOT an entity tombstone.
final class StagedSyncObject {
  StagedSyncObject({
    required this.fileId,
    required this.version,
    required this.digest,
    required Uint8List bytes,
    this.removed = false,
    this.sequence = 0,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final String fileId, version, digest;
  final int sequence;
  final Uint8List bytes;
  final bool removed;
  @override
  String toString() => 'StagedSyncObject(<untrusted>)';
}

/// Device-local journal, separate from portable workspace backup. Binding must
/// include account, workspace AND device, and reject a different binding/key.
abstract interface class SyncTransportJournal {
  String get accountKey;
  String get workspaceId;
  String get deviceId;
  Future<SyncTransportCursor> readCursor();
  Future<void> saveCursor(
    SyncTransportCursor cursor, {
    required int expectedRevision,
  });
  Future<SyncUploadReceipt?> readUpload(String changeId);

  /// First durable reservation wins even between processes.
  Future<SyncUploadReceipt> reserveUpload(SyncUploadReceipt receipt);
  Future<void> confirmUpload(SyncUploadReceipt receipt);

  /// Durable before the page cursor advances. Exact duplicates are harmless.
  Future<void> stageObject(StagedSyncObject object);
  Future<List<StagedSyncObject>> readStagedObjects({
    int afterSequence = 0,
    int limit = 100,
  });
}

const syncTransportPacketLimit = 16 * 1024 * 1024;
const syncTransportNamePrefix = 'antirkn-packet-v1-';
