import 'change_contract.g.dart';

export 'change_contract.g.dart';

/// Local installation identity. Device keys and OAuth tokens are not part of it.
final class WorkspaceIdentity {
  const WorkspaceIdentity({required this.workspaceId, required this.deviceId});
  final String workspaceId, deviceId;
}

/// Decrypted local history. This is NOT an E2EE transport envelope or a command.
final class LocalChange {
  const LocalChange({required this.header, required this.source});
  final ChangeHeader header;
  final String? source;

  @override
  String toString() => 'LocalChange(<redacted>)';
}

abstract interface class ChangeJournalStore {
  Future<WorkspaceIdentity> readWorkspaceIdentity();
  Future<List<LocalChange>> readChanges({
    int afterSequence = 0,
    int limit = 100,
  });
  Future<List<LocalChange>> readPendingChanges({
    int afterSequence = 0,
    int limit = 100,
  });

  /// A future transport calls this only after a durable receipt for these IDs.
  /// Acknowledging an older change never acknowledges a newer entity revision.
  Future<void> acknowledgeChanges(List<String> changeIds);
}
