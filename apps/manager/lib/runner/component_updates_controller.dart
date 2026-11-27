import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/widgets.dart';

/// Server component release checks: always on, and their offers always
/// shown on the server cards. The two update switches in Settings govern
/// the app updater since UI-61; [automatic] is only a test seam.
class ComponentUpdatesController extends ChangeNotifier {
  ComponentUpdatesController({
    required this.source,
    this.settings,
    this.automatic = true,
  });
  final ComponentReleaseSource source;
  final SettingsStore? settings;
  final bool automatic;
  bool busy = false, failed = false, storageFailed = false;
  bool diagnosticsPaused = false;
  bool _disposed = false;
  Timer? _timer;
  DateTime? checkedAt, _attemptedAt;
  Map<String, String> latest = {};
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    try {
      final cache = await settings?.readSetting('componentUpdatesCache');
      if (cache != null) {
        final data = jsonDecode(cache) as Map;
        checkedAt = DateTime.parse(data['checkedAt'] as String);
        latest = Map<String, String>.from(data['latest'] as Map);
        if (!latest.containsKey('panel') || !latest.containsKey('xray')) {
          checkedAt = null;
        }
      }
    } catch (_) {
      storageFailed = true;
    }
    if (_disposed) return;
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => maybeCheck());
    _notify();
    if (settings != null) maybeCheck();
  }

  void maybeCheck() {
    if (!automatic || busy || _disposed || diagnosticsPaused) return;
    final now = DateTime.now();
    if (_attemptedAt != null &&
        now.difference(_attemptedAt!) < const Duration(minutes: 15)) {
      return;
    }
    if (checkedAt == null ||
        now.difference(checkedAt!) >= const Duration(hours: 6)) {
      unawaited(check(automaticRequest: true));
    }
  }

  /// A repeated check within 30 seconds is skipped; [throttled] tells the
  /// person the shown result is that fresh one instead of doing nothing.
  bool throttled = false;

  Future<void> check({bool automaticRequest = false}) async {
    if (busy || _disposed || diagnosticsPaused) return;
    final now = DateTime.now();
    if (_attemptedAt != null &&
        now.difference(_attemptedAt!) < const Duration(seconds: 30)) {
      if (!automaticRequest && !throttled) {
        throttled = true;
        _notify();
      }
      return;
    }
    throttled = false;
    _attemptedAt = now;
    busy = true;
    failed = false;
    _notify();
    try {
      final result = await source.check();
      if (_disposed) return;
      latest = result;
      checkedAt = DateTime.now();
      try {
        await settings?.writeSetting(
          'componentUpdatesCache',
          jsonEncode({
            'latest': latest,
            'checkedAt': checkedAt!.toUtc().toIso8601String(),
          }),
        );
      } catch (_) {
        storageFailed = true;
      }
    } catch (_) {
      failed = true;
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

class ComponentUpdatesScope
    extends InheritedNotifier<ComponentUpdatesController> {
  const ComponentUpdatesScope({
    required ComponentUpdatesController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
  static ComponentUpdatesController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ComponentUpdatesScope>()
      ?.notifier;
}
