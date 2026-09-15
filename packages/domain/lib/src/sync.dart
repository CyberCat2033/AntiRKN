import 'dart:typed_data';
import 'change_journal.dart';

enum SyncPacketIssue {
  invalid,
  version,
  keyVersion,
  workspace,
  tooLarge,
  storage,
}

final class SyncPacketFailure implements Exception {
  const SyncPacketFailure(this.issue);
  final SyncPacketIssue issue;
  @override
  String toString() => 'SyncPacketFailure(${issue.name})';
}

/// Immutable ciphertext for a future transport, with a local paging cursor.
final class EncryptedChangePacket {
  EncryptedChangePacket({
    required this.changeId,
    required this.sequence,
    required Uint8List bytes,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final String changeId;
  final int sequence;
  final Uint8List bytes;
  @override
  String toString() => 'EncryptedChangePacket(<redacted>)';
}

abstract interface class SyncPacketStore {
  /// Persists packets before returning them. Does not acknowledge delivery.
  /// A page can be shorter than limit because of its total byte limit.
  Future<List<EncryptedChangePacket>> preparePendingPackets({
    int afterSequence = 0,
    int limit = 100,
  });

  /// Checks AEAD and the event format only. No merge, receipt, database write,
  /// device authorization, server operation or publication is performed.
  Future<LocalChange> verifySyncPacket(Uint8List bytes);
}
