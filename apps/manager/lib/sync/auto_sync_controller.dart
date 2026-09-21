import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

enum AutoSyncPhase {
  disconnected,
  disabled,
  waiting,
  syncing,
  synced,
  editing,
  conflict,
  incomplete,
  error,
}

/// One foreground worker per open workspace. Timers only schedule work; a
/// canceled run is joined before changing the account or closing its database.
class AutoSyncController extends ChangeNotifier {
  AutoSyncController({
    required this.accountService,
    required this.settings,
    required this.openSession,
    required this.changes,
    required this.apply,
    this.interval = const Duration(seconds: 30),
    this.debounce = const Duration(seconds: 1),
  }) {
    ready = _initialize();
  }
  final GoogleAccountService accountService;
  final SettingsStore settings;
  final Future<AutoSyncSession> Function() openSession;
  final Stream<void> changes;
  SyncApplyGate apply;
  final Duration interval, debounce;
  late final Future<void> ready;
  GoogleDriveAccount? account;
  bool enabled = true;
  bool applying = false;
  AutoSyncPhase phase = AutoSyncPhase.disconnected;
  AutoSyncResult? result;
  GoogleAccountIssue? accountError;
  SyncTransportIssue? transportError;
  AutoSyncSession? _session;
  StreamSubscription<void>? _subscription;
  Timer? _timer;
  Future<void>? _running;
  Future<void>? _stopping;
  SyncCancellation? _cancel;
  bool _foreground = true,
      _suspended = false,
      _disposed = false,
      _again = false;
  int _failures = 0;
  Duration? _retryAfter;
  DateTime? _retryAt;

  bool _diagnosticsPaused = false;
  Future<void> pauseDiagnostics(bool value) async {
    _diagnosticsPaused = value;
    if (value) {
      await ready;
      _timer?.cancel();
      _cancel?.cancel();
      await _running;
    } else {
      request();
    }
  }

  bool get _allowed =>
      !_disposed &&
      !_suspended &&
      !_diagnosticsPaused &&
      _foreground &&
      enabled &&
      account != null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _initialize() async {
    _subscription = changes.listen((_) => request());
    try {
      enabled = await settings.readSetting('googleAutoSync') != 'false';
      account = await accountService.restore();
      if (_disposed) return;
      phase = account == null
          ? AutoSyncPhase.disconnected
          : enabled
          ? AutoSyncPhase.waiting
          : AutoSyncPhase.disabled;
      request(immediate: true);
    } on GoogleAccountFailure catch (error) {
      accountError = error.issue;
      phase = AutoSyncPhase.error;
    } catch (_) {
      transportError = SyncTransportIssue.storage;
      phase = AutoSyncPhase.error;
    }
    _notify();
  }

  bool _forceRecovery = false;

  void retryRecovery() => request(immediate: true, forceRecovery: true);

  void request({bool immediate = false, bool forceRecovery = false}) {
    if (!_allowed) return;
    if (forceRecovery) _forceRecovery = true;
    if (_running != null) {
      _again = true;
      return;
    }
    _timer?.cancel();
    final remaining = _retryAt?.difference(DateTime.now());
    _timer = Timer(
      remaining != null && remaining > Duration.zero && !forceRecovery
          ? remaining
          : immediate || forceRecovery
          ? Duration.zero
          : debounce,
      _start,
    );
  }

  void _start() {
    if (!_allowed || _running != null) return;
    _retryAt = null;
    _running = _run().whenComplete(() {
      _running = null;
      if (!_allowed) return;
      var retry = _failures == 0
          ? interval
          : Duration(
              seconds: (5 * (1 << (_failures - 1).clamp(0, 6))).clamp(5, 300),
            );
      if (_retryAfter != null && _retryAfter! > retry) retry = _retryAfter!;
      if (_failures > 0) _retryAt = DateTime.now().add(retry);
      final delay = _failures == 0 && (_again || (result?.more ?? false))
          ? (_again ? debounce : const Duration(milliseconds: 50))
          : retry;
      _again = false;
      _timer = Timer(delay, _start);
    });
  }

  Future<void> _run() async {
    final forceRecovery = _forceRecovery;
    _forceRecovery = false;
    _cancel = SyncCancellation();
    phase = AutoSyncPhase.syncing;
    accountError = null;
    transportError = null;
    _retryAfter = null;
    _notify();
    try {
      _session ??= await openSession();
      _cancel!.check();
      final next = await _session!.exchange(
        cancellation: _cancel!,
        forceRecovery: forceRecovery,
        apply: (receive) => apply(() async {
          _cancel!.check();
          applying = true;
          _notify();
          try {
            await receive();
          } finally {
            applying = false;
            _notify();
          }
        }),
      );
      _cancel!.check();
      result = next;
      _failures = 0;
      phase = next.waitingForEditor
          ? AutoSyncPhase.editing
          : next.conflicts > 0
          ? AutoSyncPhase.conflict
          : next.waitingGroups > 0 || next.rejected > 0
          ? AutoSyncPhase.incomplete
          : next.more
          ? AutoSyncPhase.waiting
          : AutoSyncPhase.synced;
    } on GoogleAccountFailure catch (error) {
      accountError = error.issue;
      phase = AutoSyncPhase.error;
      _failures++;
    } on SyncTransportFailure catch (error) {
      if (error.issue != SyncTransportIssue.cancelled) {
        transportError = error.issue;
        _retryAfter = error.retryAfter;
        phase = AutoSyncPhase.error;
        _failures++;
      }
    } catch (_) {
      transportError = SyncTransportIssue.storage;
      phase = AutoSyncPhase.error;
      _failures++;
    } finally {
      _cancel = null;
      _notify();
    }
  }

  void foreground(bool value) {
    _foreground = value;
    if (value) {
      request(immediate: true);
    } else {
      _timer?.cancel();
      if (_running == null) {
        _cancel?.cancel();
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    if (enabled == value) return;
    await settings.writeSetting('googleAutoSync', value.toString());
    enabled = value;
    if (!value) {
      _timer?.cancel();
      _cancel?.cancel();
      final pending = _running;
      if (pending != null) await pending;
    }
    phase = value ? AutoSyncPhase.waiting : AutoSyncPhase.disabled;
    _notify();
    request(immediate: true);
  }

  Future<void> suspendAccount() async {
    _suspended = true;
    _timer?.cancel();
    _cancel?.cancel();
    final pending = _running;
    if (pending != null) await pending;
    final session = _session;
    if (session != null) await session.close();
    _session = null;
  }

  Future<void> accountChanged(GoogleDriveAccount? value) async {
    account = value;
    _suspended = false;
    result = null;
    _failures = 0;
    _retryAt = null;
    phase = value == null
        ? AutoSyncPhase.disconnected
        : enabled
        ? AutoSyncPhase.waiting
        : AutoSyncPhase.disabled;
    _notify();
    request(immediate: true);
  }

  /// Owner must join this before replacing the workspace database.
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _disposed = true;
    _timer?.cancel();
    _cancel?.cancel();
    await ready;
    final subscription = _subscription;
    if (subscription != null) await subscription.cancel();
    final pending = _running;
    if (pending != null) await pending;
    final session = _session;
    if (session != null) await session.close();
    _session = null;
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}
