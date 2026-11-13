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

/// One worker per workspace. Automatic uploads start on background/exit; at
/// startup only a previously failed local snapshot may be retried.
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
  Timer? _timer;
  Future<void>? _running;
  Future<void>? _stopping;
  SyncCancellation? _cancel;
  bool _foreground = true,
      _suspended = false,
      _disposed = false,
      _again = false;
  Duration _failureBackoff = Duration.zero;
  int _consecutiveFailures = 0;

  bool _diagnosticsPaused = false;
  Future<void> pauseDiagnostics(bool value) async {
    _diagnosticsPaused = value;
    if (value) {
      await ready;
      _timer?.cancel();
      _cancel?.cancel();
      await _running;
    } else {
      _notify();
    }
  }

  bool get _allowed =>
      !_disposed &&
      !_suspended &&
      !_diagnosticsPaused &&
      enabled &&
      account != null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _initialize() async {
    try {
      enabled = await settings.readSetting('googleAutoSync') != 'false';
      account = await accountService.restore();
      if (_disposed) return;
      phase = account == null
          ? AutoSyncPhase.disconnected
          : enabled
          ? AutoSyncPhase.waiting
          : AutoSyncPhase.disabled;
      request(immediate: true, forceRecovery: true);
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

  void request({bool immediate = false, bool forceRecovery = false}) {
    if (!_allowed) return;
    if (forceRecovery) _forceRecovery = true;
    if (_running != null) {
      _again = true;
      return;
    }
    _timer?.cancel();
    _timer = Timer(
      immediate || forceRecovery ? Duration.zero : debounce,
      _start,
    );
  }

  void _start() {
    if (!_allowed || _running != null) return;
    _running = _run().whenComplete(() {
      _running = null;
      if (_allowed && _again) {
        _again = false;
        final delay =
            _failureBackoff > Duration.zero ? _failureBackoff : debounce;
        _timer = Timer(delay, _start);
      }
    });
  }

  Future<void> _run() async {
    final forceRecovery = _forceRecovery;
    _forceRecovery = false;
    _cancel = SyncCancellation();
    phase = AutoSyncPhase.syncing;
    accountError = null;
    transportError = null;
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
      phase = next.waitingForEditor
          ? AutoSyncPhase.editing
          : next.conflicts > 0
          ? AutoSyncPhase.conflict
          : next.waitingGroups > 0 || next.rejected > 0
          ? AutoSyncPhase.incomplete
          : next.more
          ? AutoSyncPhase.waiting
          : AutoSyncPhase.synced;
      _consecutiveFailures = 0;
      _failureBackoff = Duration.zero;
    } on GoogleAccountFailure catch (error) {
      accountError = error.issue;
      phase = AutoSyncPhase.error;
      _again = false;
    } on SyncTransportFailure catch (error) {
      if (error.issue != SyncTransportIssue.cancelled) {
        transportError = error.issue;
        phase = AutoSyncPhase.error;
        _consecutiveFailures++;
        if (error.issue == SyncTransportIssue.rateLimited) {
          _failureBackoff = error.retryAfter ?? const Duration(seconds: 30);
        } else {
          final seconds = (1 << _consecutiveFailures).clamp(2, 30);
          _failureBackoff = Duration(seconds: seconds);
        }
      }
    } catch (_) {
      transportError = SyncTransportIssue.storage;
      phase = AutoSyncPhase.error;
      _consecutiveFailures++;
      _failureBackoff = const Duration(seconds: 5);
    } finally {
      _cancel = null;
      _notify();
    }
  }

  void foreground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (!value) {
      request(immediate: true);
    }
  }

  /// Desktop exit can wait for the local save and the best-effort upload.
  Future<void> flushOnExit() async {
    await ready;
    if (!_allowed) return;
    _timer?.cancel();
    final pending = _running;
    if (pending != null) await pending;
    await _run();
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
    phase = value == null
        ? AutoSyncPhase.disconnected
        : enabled
        ? AutoSyncPhase.waiting
        : AutoSyncPhase.disabled;
    _notify();
    request(immediate: true, forceRecovery: true);
  }

  /// Owner must join this before replacing the workspace database.
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _disposed = true;
    _timer?.cancel();
    _cancel?.cancel();
    await ready;
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
