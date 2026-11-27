import 'dart:async';
import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/widgets.dart';

/// The update record in the workspace settings: one small JSON value.
final class SettingsAppUpdateStateStore implements AppUpdateStateStore {
  const SettingsAppUpdateStateStore(this.settings);
  final SettingsStore settings;
  static const key = 'appUpdateState';

  @override
  Future<AppUpdateRecord> read() async {
    try {
      final value = await settings.readSetting(key);
      return value == null
          ? const AppUpdateRecord()
          : AppUpdateRecord.fromJson(jsonDecode(value));
    } catch (_) {
      return const AppUpdateRecord();
    }
  }

  @override
  Future<void> write(AppUpdateRecord record) async {
    try {
      await settings.writeSetting(key, jsonEncode(record.toJson()));
    } catch (_) {
      throw const AppUpdateFailure(AppUpdateCode.storage);
    }
  }
}

/// The one view model of the app update for the settings card and the home
/// banner: preferences, the skipped version and the coordinator's state.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    this.coordinator,
    this.settings,
    this.backgroundChecks = true,
    this.openUrl,
    this.interval = const Duration(hours: 6),
  });

  /// Null when this platform or build cannot update itself.
  final AppUpdateCoordinator? coordinator;
  final SettingsStore? settings;

  /// Automatic checks at start and periodically; off in widget tests.
  final bool backgroundChecks;
  final Future<void> Function(Uri uri)? openUrl;
  final Duration interval;

  static const automaticKey = 'appUpdatesAutomatic';
  static const suggestionsKey = 'appUpdatesSuggestions';
  static const skippedKey = 'appUpdatesSkipped';

  /// The two switches used to govern server component checks; their saved
  /// values move to the app updater once (UI-61).
  static const legacyKeys = {
    automaticKey: 'componentUpdatesAutomatic',
    suggestionsKey: 'componentUpdatesSuggestions',
  };

  bool automatic = true, suggestions = true, storageFailed = false;
  String? skippedVersion;
  DateTime? checkedAt;
  StreamSubscription<AppUpdateState>? _subscription;
  Timer? _timer;
  bool _disposed = false;

  AppUpdateState get state =>
      coordinator?.state ?? const AppUpdateUnavailable();
  InstalledApp? get installed => coordinator?.installed;
  bool get busy => coordinator?.busy ?? false;

  /// The offered update behind the current state, if any.
  UpdateOffered? get offer => switch (state) {
    AppUpdateAvailable(:final offer) ||
    AppUpdateDownloading(:final offer) ||
    AppUpdateVerifying(:final offer) ||
    AppUpdateReadyToInstall(:final offer) ||
    AppUpdateInstalling(:final offer) => offer,
    AppUpdateFailed(:final offer) => offer,
    _ => null,
  };

  /// The home screen notice: suggestions on, something to act on, and not
  /// a version the person chose to skip (a started download still shows).
  bool get showOnHome {
    final current = offer;
    if (!suggestions || current == null) return false;
    return state is! AppUpdateAvailable ||
        current.payload.version != skippedVersion;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    _subscription = coordinator?.states.listen((state) {
      if (state is AppUpdateUpToDate || state is AppUpdateAvailable) {
        checkedAt = DateTime.now();
      }
      _notify();
    });
    try {
      automatic = await _preference(automaticKey);
      suggestions = await _preference(suggestionsKey);
      skippedVersion = await settings?.readSetting(skippedKey);
    } catch (_) {
      storageFailed = true;
    }
    await coordinator?.confirmStartup();
    if (_disposed) return;
    _notify();
    if (backgroundChecks) {
      _timer = Timer.periodic(const Duration(minutes: 30), (_) => maybeCheck());
      maybeCheck();
    }
  }

  Future<bool> _preference(String key) async {
    final store = settings;
    if (store == null) return true;
    var value = await store.readSetting(key);
    if (value == null) {
      value = await store.readSetting(legacyKeys[key]!) == 'false'
          ? 'false'
          : 'true';
      await store.writeSetting(key, value);
    }
    return value != 'false';
  }

  /// A cheap manifest check at most every [interval] while automatic.
  void maybeCheck() {
    if (!automatic || !backgroundChecks || _disposed || busy) return;
    final current = state;
    if (current is! AppUpdateIdle &&
        current is! AppUpdateUpToDate &&
        current is! AppUpdateFailed) {
      return;
    }
    final at = checkedAt;
    if (at == null || DateTime.now().difference(at) >= interval) {
      unawaited(check());
    }
  }

  Future<void> setPreference({bool? automatic, bool? suggestions}) async {
    try {
      if (automatic != null) {
        await settings?.writeSetting(automaticKey, '$automatic');
      }
      if (suggestions != null) {
        await settings?.writeSetting(suggestionsKey, '$suggestions');
      }
      this.automatic = automatic ?? this.automatic;
      this.suggestions = suggestions ?? this.suggestions;
      storageFailed = false;
    } catch (_) {
      storageFailed = true;
    }
    _notify();
    maybeCheck();
  }

  Future<void> check() async => coordinator?.check();
  Future<void> download() async => coordinator?.download();
  Future<void> install() async => coordinator?.install();
  void cancel() => coordinator?.cancel();

  /// Hides the offered version until a newer one is released.
  Future<void> skip() async {
    final version = offer?.payload.version;
    if (version == null) return;
    try {
      await settings?.writeSetting(skippedKey, version);
      skippedVersion = version;
      storageFailed = false;
    } catch (_) {
      storageFailed = true;
    }
    _notify();
  }

  Future<void> openReleasePage() async {
    final url = offer?.payload.notesUrl;
    if (url != null) await openUrl?.call(Uri.parse(url));
  }

  /// What is new since the installed version, in [languageCode].
  List<AppUpdateChangelogEntry> changes(String languageCode) {
    final current = offer;
    final app = installed;
    if (current == null || app == null) return const [];
    return appUpdateChangesSince(
      current.payload.changelog,
      installedVersion: app.version,
      languageCode: languageCode,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

class AppUpdateScope extends InheritedNotifier<AppUpdateController> {
  const AppUpdateScope({
    required AppUpdateController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
  static AppUpdateController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUpdateScope>()?.notifier;
}
