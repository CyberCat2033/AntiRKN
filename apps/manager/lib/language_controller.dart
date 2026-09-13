import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

final class LanguageController extends ChangeNotifier {
  LanguageController(this.store);
  final LanguagePreferenceStore store;
  AppLanguage language = AppLanguage.system;
  bool loadingFailed = false;
  bool savingFailed = false;
  bool saving = false;
  bool _disposed = false;

  Future<void> load() async {
    try {
      language = await store.readLanguage();
    } catch (_) {
      loadingFailed = true;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> select(AppLanguage next) async {
    if (saving) return;
    saving = true;
    savingFailed = false;
    notifyListeners();
    try {
      await store.writeLanguage(next);
      if (!_disposed) {
        language = next;
        loadingFailed = false;
      }
    } catch (_) {
      if (!_disposed) savingFailed = true;
    } finally {
      if (!_disposed) {
        saving = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
