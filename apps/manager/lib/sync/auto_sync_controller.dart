import 'dart:async';
import 'dart:math';
import 'dart:ui' show AppLifecycleState;
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

  /// The cloud has a newer snapshot; this device has nothing unsent.
  remoteNewer,

  /// A temporary failure; a retry is scheduled without a lifecycle event.
  retrying,

  /// Unsent edits here and a newer cloud version: nothing is exchanged until
  /// the user chooses one of them.
  diverged,

  /// Not retried automatically: needs the user or the next background/launch.
  error,
}

/// One worker per workspace; devices work in turn. Entering the app (launch,
/// return from the background) sends what is unsent, then checks the cloud
/// version and receives a newer one. Edits upload [uploadDebounce] after the
/// last change and on leaving. Temporary failures schedule their own retry;
/// divergent data and revoked access wait.
class AutoSyncController extends ChangeNotifier {
  AutoSyncController({
    required this.accountService,
    required this.settings,
    required this.openSession,
    required this.changes,
    required this.apply,
    this.interval = const Duration(seconds: 30),
    this.debounce = const Duration(seconds: 1),
    this.uploadDebounce = const Duration(seconds: 30),
    this.uploadMaxWait = const Duration(minutes: 2),
    this.applyRetry = const Duration(seconds: 2),
    this.exitDeadline = const Duration(seconds: 5),
    Random? random,
  }) : _random = random ?? Random() {
    ready = _initialize();
    _changes = changes.listen((_) => _edited());
  }
  final GoogleAccountService accountService;
  final SettingsStore settings;
  final Future<AutoSyncSession> Function() openSession;

  /// Local writes; cache-only ones are recognized by the session and cost no
  /// request.
  final Stream<void> changes;
  SyncApplyGate apply;

  /// [interval]: least time between entry checks on focus or a transient
  /// inactive state; returning from the background always checks.
  final Duration interval, debounce;

  /// Upload after edits: [uploadDebounce] after the last change, at most
  /// [uploadMaxWait] after the first one while changes keep coming.
  final Duration uploadDebounce, uploadMaxWait;

  /// How often a received snapshot waiting for an editor is tried again.
  final Duration applyRetry;

  /// Closing the desktop window waits at most this long; the local snapshot
  /// already written is sent at the next launch.
  final Duration exitDeadline;
  late final StreamSubscription<void> _changes;
  Timer? _editTimer, _editDeadline, _entryThrottle;
  late final Future<void> ready;
  GoogleDriveAccount? account;
  bool enabled = true;
  bool applying = false;
  AutoSyncPhase phase = AutoSyncPhase.disconnected;
  AutoSyncResult? result;

  /// Both versions while [phase] is [AutoSyncPhase.diverged].
  SyncDivergence? divergence;

  /// The last choice could not be applied: an editor or operation was open.
  bool choiceBlocked = false;
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
  final Random _random;
  bool _retry = false, _retryRecovery = false;

  static const firstRetry = Duration(seconds: 2),
      maxRetry = Duration(minutes: 5);

  /// Exponential backoff from [firstRetry] to [maxRetry] with jitter in the
  /// last fifth, so devices that failed together do not retry together.
  Duration _retryDelay({Duration? retryAfter}) {
    final exponent = (_consecutiveFailures - 1).clamp(0, 20);
    final base = Duration(
      milliseconds: min(
        firstRetry.inMilliseconds * (1 << exponent),
        maxRetry.inMilliseconds,
      ),
    );
    final jittered = base * (0.8 + 0.2 * _random.nextDouble());
    return retryAfter != null && retryAfter > jittered ? retryAfter : jittered;
  }

  /// Temporary transport/account states. A first 401 is retried once because
  /// the Drive adapter has invalidated the cached token for the next attempt.
  bool _transient({
    SyncTransportIssue? transport,
    GoogleAccountIssue? account,
  }) =>
      switch (transport) {
        SyncTransportIssue.network ||
        SyncTransportIssue.unavailable ||
        SyncTransportIssue.rateLimited => true,
        SyncTransportIssue.unauthorized => _consecutiveFailures == 1,
        _ => false,
      } ||
      account == GoogleAccountIssue.network ||
      account == GoogleAccountIssue.busy;

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
      request(immediate: true, forceRecovery: true, enter: true);
    } on GoogleAccountFailure catch (error) {
      accountError = error.issue;
      phase = AutoSyncPhase.error;
    } catch (_) {
      transportError = SyncTransportIssue.storage;
      phase = AutoSyncPhase.error;
    }
    _notify();
  }

  bool _forceRecovery = false, _enter = false, _runningEnter = false;
  bool _retryEnter = false;

  void request({
    bool immediate = false,
    bool forceRecovery = false,
    bool enter = false,
  }) {
    if (!_allowed) return;
    // A return to the app while its entry check runs does not start another.
    if (enter && _runningEnter) return;
    if (forceRecovery) _forceRecovery = true;
    if (enter) {
      _enter = true;
      _entryThrottle?.cancel();
      _entryThrottle = Timer(interval, () {});
    }
    if (_running != null) {
      _again = true;
      return;
    }
    _timer?.cancel();
    _timer = Timer(
      immediate || forceRecovery || enter ? Duration.zero : debounce,
      _start,
    );
  }

  void _start() {
    if (!_allowed || _running != null) return;
    _running = _run().whenComplete(() {
      _running = null;
      if (!_allowed) {
        _retry = false;
        return;
      }
      if (_again || _retry) {
        if (_retry) {
          _forceRecovery = _forceRecovery || _retryRecovery;
          _enter = _enter || _retryEnter;
        }
        _again = _retry = false;
        final delay = _failureBackoff > Duration.zero
            ? _failureBackoff
            : debounce;
        _timer = Timer(delay, _start);
      } else if (phase == AutoSyncPhase.editing && _foreground) {
        // The received snapshot is kept; trying the gate again is free.
        _timer = Timer(applyRetry, _start);
      }
    });
  }

  /// A local change: upload once the edits settle.
  void _edited() {
    if (!_allowed || divergence != null) return;
    _editTimer?.cancel();
    _editTimer = Timer(uploadDebounce, _uploadEdits);
    _editDeadline ??= Timer(uploadMaxWait, _uploadEdits);
  }

  void _uploadEdits() {
    _cancelEdits();
    request(immediate: true);
  }

  void _cancelEdits() {
    _editTimer?.cancel();
    _editDeadline?.cancel();
    _editTimer = _editDeadline = null;
  }

  Future<void> _run({SyncDivergenceChoice? choice}) async {
    final forceRecovery = _forceRecovery, enter = _enter;
    _forceRecovery = _enter = false;
    _runningEnter = enter;
    // Edits made so far go with this exchange.
    _cancelEdits();
    _cancel = SyncCancellation();
    // A received snapshot waiting for an editor keeps saying so.
    if (phase != AutoSyncPhase.editing) phase = AutoSyncPhase.syncing;
    accountError = null;
    transportError = null;
    _notify();
    try {
      _session ??= await openSession();
      _cancel!.check();
      Future<bool> gate(Future<void> Function() receive) => apply(() async {
        _cancel!.check();
        applying = true;
        _notify();
        try {
          await receive();
        } finally {
          applying = false;
          _notify();
        }
      });
      final next = choice == null
          ? await _session!.exchange(
              cancellation: _cancel!,
              forceRecovery: forceRecovery,
              enter: enter,
              apply: gate,
            )
          : await _session!.resolve(
              choice,
              cancellation: _cancel!,
              apply: gate,
            );
      _cancel!.check();
      result = next;
      choiceBlocked = false;
      if (next.divergence != null) divergence = next.divergence;
      if (choice != null && next.waitingForEditor && next.divergence == null) {
        // Nothing replaced: the versions still wait for a choice.
        choiceBlocked = true;
      } else if (next.divergence == null) {
        divergence = null;
      }
      phase = divergence != null
          ? AutoSyncPhase.diverged
          : next.received
          ? AutoSyncPhase.synced
          : next.waitingForEditor
          ? AutoSyncPhase.editing
          : next.conflicts > 0
          ? AutoSyncPhase.conflict
          : next.remoteNewer
          ? AutoSyncPhase.remoteNewer
          : next.waitingGroups > 0 || next.rejected > 0
          ? AutoSyncPhase.incomplete
          : next.more
          ? AutoSyncPhase.waiting
          : AutoSyncPhase.synced;
      _consecutiveFailures = 0;
      _failureBackoff = Duration.zero;
    } on GoogleAccountFailure catch (error) {
      accountError = error.issue;
      _failed(forceRecovery, account: error.issue);
    } on SyncTransportFailure catch (error) {
      if (error.issue != SyncTransportIssue.cancelled) {
        transportError = error.issue;
        _failed(
          forceRecovery,
          transport: error.issue,
          retryAfter: error.retryAfter,
        );
      }
    } catch (_) {
      transportError = SyncTransportIssue.storage;
      _failed(forceRecovery, transport: SyncTransportIssue.storage);
    } finally {
      _cancel = null;
      _runningEnter = false;
      _notify();
    }
  }

  void _failed(
    bool forceRecovery, {
    SyncTransportIssue? transport,
    GoogleAccountIssue? account,
    Duration? retryAfter,
  }) {
    _consecutiveFailures++;
    if (_transient(transport: transport, account: account)) {
      phase = AutoSyncPhase.retrying;
      _failureBackoff = _retryDelay(retryAfter: retryAfter);
      _retry = true;
      _retryRecovery = forceRecovery;
      _retryEnter = _runningEnter;
      return;
    }
    // Divergent data, revoked access or a local failure would fail the same
    // way again; the next background/launch or a user action tries anew.
    phase = transport == SyncTransportIssue.conflict
        ? AutoSyncPhase.conflict
        : AutoSyncPhase.error;
    _failureBackoff = Duration.zero;
    _again = _retry = false;
  }

  /// Whether [state] keeps automatic sync in the foreground; null keeps the
  /// current state. An unfocused desktop window is still visible. On Android
  /// `inactive` is transient (notification shade, permission dialog, picker,
  /// Google sign-in, share sheet): only hidden/paused leave and upload.
  static bool? lifecycleForeground(
    AppLifecycleState state, {
    required bool desktop,
  }) => switch (state) {
    AppLifecycleState.resumed => true,
    AppLifecycleState.inactive => desktop ? true : null,
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => false,
  };

  /// Leaving uploads unsent edits; returning checks the cloud version.
  void foreground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    request(immediate: true, enter: value);
  }

  /// The app is resumed (also after focus or a notification shade): checks
  /// the cloud unless an entry check ran within [interval].
  void resumed() {
    if (!_foreground || (_entryThrottle?.isActive ?? false)) return;
    request(immediate: true, enter: true);
  }

  /// Desktop exit waits for the local save and the upload, at most
  /// [exitDeadline]: a local snapshot not sent by then is sent at the next
  /// launch, and unsaved edits are captured then.
  Future<void> flushOnExit() async {
    final done = Completer<void>();
    final deadline = Timer(exitDeadline, () {
      if (!done.isCompleted) done.complete();
    });
    unawaited(
      _runNow(cancelled: () => done.isCompleted).whenComplete(() {
        if (!done.isCompleted) done.complete();
      }),
    );
    await done.future;
    if (!deadline.isActive) _cancel?.cancel();
    deadline.cancel();
  }

  /// The user's explicit choice between the diverged versions.
  Future<void> resolve(SyncDivergenceChoice choice) => _runNow(choice: choice);

  /// Runs one exchange (or [choice]) now, after the current one; leaving
  /// mode, no entry check.
  Future<void> _runNow({
    SyncDivergenceChoice? choice,
    bool Function()? cancelled,
  }) async {
    await ready;
    if (!_allowed) return;
    _timer?.cancel();
    _cancelEdits();
    final pending = _running;
    if (pending != null) await pending;
    if ((cancelled?.call() ?? false) || _running != null) return;
    _enter = false;
    final run = _run(choice: choice);
    _running = run;
    try {
      await run;
    } finally {
      if (identical(_running, run)) _running = null;
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
    divergence = null;
    choiceBlocked = false;
    phase = value == null
        ? AutoSyncPhase.disconnected
        : enabled
        ? AutoSyncPhase.waiting
        : AutoSyncPhase.disabled;
    _notify();
    request(immediate: true, forceRecovery: true, enter: true);
  }

  /// Owner must join this before replacing the workspace database.
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _disposed = true;
    _timer?.cancel();
    _cancelEdits();
    _entryThrottle?.cancel();
    unawaited(_changes.cancel());
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
