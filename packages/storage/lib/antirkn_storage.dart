export 'src/publication_picker.dart';
export 'src/android_google_account.dart';
export 'src/desktop_google_account.dart';
export 'src/google_account_factory.dart';
export 'src/google_session_store.dart';
export 'src/sync_transport_database.dart';
export 'src/profile_exporter.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'src/template_file_picker.dart';
export 'src/secret_vault.dart';
export 'src/private_key_file_picker.dart';
export 'src/workspace_database.dart';
export 'src/backup_file_store.dart';

/// Stores non-secret, per-device preferences only. This is NOT a SecretStore.
final class LocalLanguagePreferenceStore implements LanguagePreferenceStore {
  LocalLanguagePreferenceStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;
  static const _key = 'antirkn.language.v1';

  @override
  Future<AppLanguage> readLanguage() async {
    final value = await _preferences.getString(_key);
    return AppLanguage.values
            .where((language) => language.name == value)
            .firstOrNull ??
        AppLanguage.system;
  }

  @override
  Future<void> writeLanguage(AppLanguage language) =>
      _preferences.setString(_key, language.name);
}
