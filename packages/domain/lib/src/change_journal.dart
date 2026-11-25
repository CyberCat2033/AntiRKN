export 'change_contract.g.dart';

/// Local installation identity. Device keys and OAuth tokens are not part of it.
final class WorkspaceIdentity {
  const WorkspaceIdentity({required this.workspaceId, required this.deviceId});
  final String workspaceId, deviceId;
}

/// The executor of server operations and client deletions on this device.
abstract interface class WorkspaceIdentityStore {
  Future<WorkspaceIdentity> readWorkspaceIdentity();
}
