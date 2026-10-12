import 'ssh.dart';
import 'vault.dart';

final class SavedServer {
  const SavedServer(this.id, this.profile, this.revision);
  final String id;
  final SshProfile profile;
  final int revision;
}

abstract interface class SettingsStore {
  Future<String?> readSetting(String key);
  Future<void> writeSetting(String key, String value);
}

abstract interface class TemplateDraftStore {
  Future<String?> readDraft();
  Future<void> writeDraft(String source);
}

abstract interface class ServerRepository {
  Future<List<SavedServer>> listServers();

  /// Removes the reviewed revisions together, including their secret records.
  /// Explicit local forgetting may also detach remaining SSH jump references
  /// in the same transaction, without changing their credentials or host keys.
  Future<void> deleteServers(
    List<SavedServer> expected, {
    bool detachJumpReferences = false,
  });
  Future<SecretVault> openServer(String id);
  String newServerId();
  bool get needsLegacyPassword;
  Future<void> migrateLegacy({String? password});
}
