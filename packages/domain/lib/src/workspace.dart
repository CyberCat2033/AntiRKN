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
  Future<void> deleteServers(List<SavedServer> expected);
  Future<SecretVault> openServer(String id);
  String newServerId();
  bool get needsLegacyPassword;
  Future<void> migrateLegacy({String? password});
}
