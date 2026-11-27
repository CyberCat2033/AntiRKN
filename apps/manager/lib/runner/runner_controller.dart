import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'device_upgrade_checks.dart';

/// One controller per server. Connection setup prepares the runner; polling
/// observes jobs. Persist each job request before submitting it.
/// The one way to change the Xray core (UI-45): the safe transaction of the
/// server's `XrayUpgradeView`. Connections are compared before and after the
/// switch and the app must still work with 3x-ui; otherwise the server keeps
/// or restores the current core.
class XrayVersionChoice {
  const XrayVersionChoice({
    required this.install,
    required this.update,
    required this.ready,
    required this.previous,
    this.runningPhase = _idle,
    this.stoppable = _never,
    this.cancel = _nothing,
  });
  static String? _idle() => null;
  static bool _never() => false;
  static void _nothing() {}

  /// Installs a release asset (`ComponentReleaseSource.resolveAsset`).
  final Future<void> Function(Map<String, Object?> asset) install;

  /// Updates to [version], the release the caller shows as the update; the
  /// core only moves forward.
  final Future<void> Function(String version) update;

  /// Whether a transaction can start now (connection checks are available).
  final bool Function() ready;

  /// The version that ran before the last committed core change.
  final String? Function() previous;

  /// Phase of the transaction in progress (`baseline`, `replacing`…), null
  /// when none runs; the 3x-ui / Xray card draws it.
  final String? Function() runningPhase;

  /// Whether this device drives the run, so Stop can abort it.
  final bool Function() stoppable;

  /// Aborts the run; the server rolls the core back.
  final void Function() cancel;
}

class RunnerController extends ChangeNotifier {
  RunnerController({
    required this.serverId,
    required this.transport,
    required this.identity,
    required this.password,
    required this.accessFailure,
    this.store,
    this.software,
    this.refreshSoftware,
    this.connectForAction,
  }) {
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!pollingPaused &&
          !busy &&
          !backgroundBusy &&
          transport() != null &&
          (error == null || watchesUpgrade) &&
          hasUnfinishedJob) {
        unawaited(pollActiveJob());
      }
    });
  }
  final String serverId;
  final Future<bool> Function()? connectForAction;
  Completer<void>? _idle;
  bool actionPending = false;

  bool get canRequestAction =>
      !busy &&
      !actionPending &&
      pending == null &&
      (!connected ||
          !jobs.any(
            (job) =>
                !job.terminal &&
                job.kind != 'apt_update' &&
                job.kind != 'apt_upgrade',
          ));

  Future<void> waitUntilIdle() async {
    while (_idle != null) {
      await _idle!.future;
    }
  }

  /// Explicit UI actions reconnect, then reuse the normal trust and sudo checks.
  Future<bool> ensureReady() async {
    if (_disposed) return false;
    if (!connected && await connectForAction?.call() != true) return false;
    await waitUntilIdle();
    if (!connected || _disposed) return false;
    if (!installed ||
        !alive ||
        error != null ||
        installation?.upgradable == true ||
        (bundledRelease != null && installation?.release != bundledRelease)) {
      await refresh(prepare: true);
    }
    return connected && installed && alive && error == null;
  }

  Future<void> requestAction(Future<void> Function() action) async {
    if (!canRequestAction) return;
    actionPending = true;
    _notify();
    try {
      if (await ensureReady()) await action();
    } finally {
      actionPending = false;
      _notify();
    }
  }

  /// Install/Update is consent; preflight and fingerprint checks stay internal.
  /// Installs confirmed while the server was busy, in confirmation order.
  /// The server runs one job at a time; dropping the request silently made
  /// a confirmed install look like it never happened.
  final queuedInstalls = <String>[];
  String? _installing;

  /// Pause before a queued install retries after the server said busy.
  @visibleForTesting
  Duration busyRetryDelay = const Duration(seconds: 10);

  Future<void> installOrUpdate(String component) async {
    // A repeated confirmation of the same install is not a second install.
    if (queuedInstalls.contains(component) || _installing == component) {
      return;
    }
    queuedInstalls.add(component);
    _notify();
    try {
      final deadline = DateTime.now().add(const Duration(hours: 1));
      while (!_disposed && DateTime.now().isBefore(deadline)) {
        await _turn(component, deadline);
        // Resuming after the wait is a later microtask: the controller may
        // have become busy again (a refresh or poll). Starting is checked in
        // the same synchronous step as the start itself.
        if (_disposed ||
            !canRequestAction ||
            queuedInstalls.first != component) {
          continue;
        }
        queuedInstalls.remove(component);
        responseCode = null;
        final before = selected?.id;
        _notify();
        await _install(component);
        // Done only when a job really went to the server or the server gave
        // a reason the person sees (plan refused, error). The server runs one
        // job at a time, including jobs this controller does not track (the
        // app's own VPN sync, another device): "busy" or a silent stop
        // because such a job appeared admits no effect, so wait and retry.
        final submitted = selected != null && selected!.id != before;
        final refused =
            error != null ||
            (component == 'panel'
                ? panelPlan?.canApply == false
                : componentPlan?.component == component &&
                      componentPlan?.canApply == false) ||
            (responseCode != null &&
                responseCode != 'ok' &&
                responseCode != 'busy');
        if (_disposed || submitted || refused) return;
        queuedInstalls.insert(0, component);
        _notify();
        await Future<void>.delayed(busyRetryDelay);
      }
    } finally {
      if (queuedInstalls.remove(component)) _notify();
    }
  }

  /// Completes when [component] heads the queue and the server is free, or
  /// at [deadline]. Job status arrives by polling; a timer also looks, so a
  /// missed notification cannot strand the queue.
  Future<void> _turn(String component, DateTime deadline) async {
    final turn = Completer<void>();
    void check() {
      if (_disposed ||
          !DateTime.now().isBefore(deadline) ||
          (canRequestAction && queuedInstalls.first == component)) {
        if (!turn.isCompleted) turn.complete();
      }
    }

    addListener(check);
    final ticker = Timer.periodic(const Duration(seconds: 2), (_) => check());
    try {
      check();
      await turn.future;
    } finally {
      ticker.cancel();
      removeListener(check);
    }
  }

  Future<void> _install(String component) async {
    _installing = component;
    try {
      await requestAction(() => _installNow(component));
    } finally {
      _installing = null;
    }
  }

  Future<void> _installNow(String component) async {
    if (component == 'panel') {
      if (panelDetected) {
        await preparePanelUpdate();
        await applyPanelUpdate();
      } else {
        await openPanelPlan();
        await applyPanel();
      }
    } else {
      await prepareComponent(component);
      await applyComponent();
    }
  }

  final void Function()? refreshSoftware;

  /// Registered while the server's `XrayUpgradeView` is mounted.
  XrayVersionChoice? xrayVersionChoice;

  /// Bumped when the transaction of [xrayVersionChoice] changes, so the
  /// 3x-ui / Xray software card redraws its progress.
  final xrayRevision = ValueNotifier<int>(0);

  /// The device's connection checks around a 3x-ui, TrustTunnel or
  /// AmneziaWG upgrade; registered with [xrayVersionChoice], which has the
  /// VPN side they need.
  DeviceUpgradeChecks Function(CancellationToken token, VoidCallback changed)?
  deviceChecks;

  /// The connections compared around the last checked component upgrade
  /// and its stage: `baseline`, `upgrading`, `comparison`, `committed`,
  /// `rolling_back`, `rolled_back` or `failed` (with [upgradeCheckCode]).
  final upgradeChecks = <UpgradeComparison>[];
  String? upgradeCheckPhase;
  String upgradeCheckCode = '';
  CancellationToken? _upgradeCheckToken;

  /// Stops a checked upgrade: before the switch nothing changes, after it
  /// the server rolls back.
  void cancelUpgradeChecks() => _upgradeCheckToken?.cancel();

  /// A checked upgrade runs (its card shows progress and Stop).
  bool get upgradeChecking => _upgradeCheckToken != null;

  /// Closes the outcome of a finished checked upgrade.
  void dismissUpgradeChecks() {
    if (upgradeChecking) return;
    upgradeCheckPhase = null;
    upgradeCheckCode = '';
    upgradeChecks.clear();
    _notify();
  }

  bool _softwareRefreshPending = false;
  final ServerSoftwareInventory? Function()? software;
  final RunnerTransport? Function() transport;
  final String? Function() identity;
  final String? Function() password;
  final void Function(SshIssue) accessFailure;
  final RunnerJournalStore? store;
  Timer? _timer;
  CancellationToken? _token;
  bool _disposed = false;
  bool _loaded = false;
  String? _identity;
  String? _journalSource;
  String? _deviceId;
  ServerOperation? operation;
  bool get observesOperation =>
      operation != null && operation!.executorDeviceId != _deviceId;
  bool busy = false;
  bool backgroundBusy = false;
  bool pollingPaused = false;
  bool alive = false;
  bool connectionLost = false;
  RunnerIssue? error;
  String? responseCode;
  RunnerInstallation? installation;
  RunnerInstallation? installPlan;
  RunnerInstallation? panelRunnerPlan;
  PanelPlan? panelPlan;
  PanelUpdatePlan? panelUpdatePlan;
  bool panelLoginRequired = false;
  ComponentPlan? componentPlan;

  /// JSON of the upstream release chosen for [componentPlan] ('' = pinned).
  String componentChoice = '';
  Map<String, dynamic>? componentUpgradePlan;
  RunnerInstallation? componentRunnerPlan;
  String? activeComponent;

  /// Version the last component or 3x-ui job started on this device moves
  /// to: the title of its progress card. Not stored; null after a restart.
  String? componentTarget, panelTarget;

  Map<String, dynamic>? egress;

  /// Public relay state of this server: `{inbounds: [{panelId, inboundId,
  /// tag, stale}], observedHash}`. The service link is read on request and
  /// never kept here or in the journal.
  Map<String, dynamic>? relay;

  /// The code of the last failed `relay_state`; [relay] keeps the last known
  /// state then.
  String? relayStateIssue;

  /// Relay inbounds of the connected panel.
  List<Map<String, dynamic>> get relayInbounds => [
    for (final entry in relay?['inbounds'] as List? ?? const [])
      if (entry is Map && entry['panelId'] == panelAccess?.id)
        Map<String, dynamic>.from(entry),
  ];
  Map<String, dynamic>? relayEntry(int inboundId) =>
      relayInbounds.where((e) => e['inboundId'] == inboundId).firstOrNull;
  Map<String, dynamic>? panelDiscovery;
  PanelAccess? panelAccess;
  ComponentPresence presence(VpnComponent component) =>
      software
          ?.call()
          ?.components
          .where((c) => c.component == component)
          .firstOrNull
          ?.presence ??
      ComponentPresence.unknown;
  bool get panelDetected =>
      panelAccess != null ||
      panels.isNotEmpty ||
      presence(VpnComponent.panel) == ComponentPresence.detected;
  List<Map<String, dynamic>> get panels =>
      (panelDiscovery?['panels'] as List? ?? [])
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();
  DateTime? panelVerifiedAt;
  bool choosingPanel = false;
  bool panelSelected = false;
  String? resumePlan;
  int? panelPort = 0;
  Map<String, dynamic>? aptPlan;
  bool choosingAptUpdate = false;
  bool _systemUpdate = false;

  /// The system update installs the refreshed package set at once; without
  /// it (Check), the plan is only shown.
  bool _systemUpgrade = true;
  bool _applySystemUpgrade = false;

  /// The finished job this device closed, as of its event [_dismissedAt].
  /// Kept in the local journal only, so a closed failure does not come back
  /// with the next refresh or start; a resumed job's new events show again.
  String? dismissedJobId;
  int? _dismissedAt;
  bool isDismissed(RunnerJob job) =>
      dismissedJobId == job.id &&
      (_dismissedAt == null || job.sequence <= _dismissedAt!);
  void _dismiss(RunnerJob job) {
    dismissedJobId = job.id;
    _dismissedAt = job.sequence;
  }

  List<RunnerJob> jobs = [];
  RunnerJob? selected;

  /// The selected job when it ended in a failure that was not closed here.
  RunnerJob? get failedJob {
    final job = selected;
    return job != null &&
            const {
              'failed',
              'partially_applied',
              'needs_attention',
            }.contains(job.status) &&
            !isDismissed(job)
        ? job
        : null;
  }

  RunnerRequest? pending;
  bool get hasUnfinishedJob =>
      pending != null ||
      selected?.terminal == false ||
      jobs.any((job) => !job.terminal) ||
      watchesUpgrade;

  /// A component upgrade that succeeded but is not settled yet: the server
  /// waits for this device's confirmation and rolls back on its own when
  /// none arrives. The job stays watched (and the confirmation retried)
  /// until it is confirmed or rolled back, at most [upgradeWatchLimit].
  String? _upgradeWatchId;
  DateTime? _upgradeWatchUntil;
  String? _upgradeConfirmedId;
  @visibleForTesting
  Duration upgradeWatchLimit = const Duration(minutes: 15);
  bool get watchesUpgrade =>
      _upgradeWatchId != null && DateTime.now().isBefore(_upgradeWatchUntil!);
  int cursor = 0;
  bool eventsTruncated = false;
  bool get connected => transport() != null;
  String? get bundledRelease => transport()?.bundledRelease;
  bool get installed =>
      installation?.state == 'installed' &&
      installation?.release == transport()?.bundledRelease;
  bool get canInstall =>
      connected &&
      !busy &&
      installation?.supported == true &&
      installation?.state != 'conflict' &&
      (installation?.upgradable == true ||
          installation?.release == null ||
          installation?.release == transport()?.bundledRelease);
  bool get canStart =>
      installed &&
      alive &&
      !busy &&
      pending == null &&
      !jobs.any((j) => !j.terminal);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> restoreLocal() async {
    if (_disposed || identity() == null) return;
    try {
      await _load();
    } catch (_) {
      error = RunnerIssue.storage;
    }
    _notify();
  }

  bool _pendingConnectionReady = false;

  void connectionReady() {
    if (_disposed || transport() == null) return;
    if (busy) {
      _pendingConnectionReady = true;
      return;
    }
    _pendingConnectionReady = false;
    if (error == RunnerIssue.unavailable) error = null;
    unawaited(refresh(prepare: true));
  }

  void disconnected() {
    if (busy && installPlan != null) error = RunnerIssue.installFailed;
    _token?.cancel();
    _token = null;
    busy = false;
    backgroundBusy = false;
    installPlan = null;
    panelPlan = null;
    panelUpdatePlan = null;
    componentPlan = null;
    componentRunnerPlan = null;
    panelRunnerPlan = null;
    choosingPanel = false;
    resumePlan = null;
    panelVerifiedAt = null;
    aptPlan = null;
    choosingAptUpdate = false;
    connectionLost = hasUnfinishedJob;
    _notify();
  }

  Future<void> _load() async {
    final current = identity();
    if (current == null) throw const RunnerFailure(RunnerIssue.unavailable);
    if (_loaded && current == _identity) return;
    if (_loaded && current != _identity) {
      resumePlan = null;
      panelPlan = null;
      panelUpdatePlan = null;
      componentPlan = null;
      componentRunnerPlan = null;
      panelRunnerPlan = null;
      installPlan = null;
      choosingPanel = false;
      panelSelected = false;
    }
    _deviceId = store is WorkspaceIdentityStore
        ? (await (store as WorkspaceIdentityStore).readWorkspaceIdentity())
              .deviceId
        : null;
    final raw = await store?.readRunnerJournal(serverId);
    _journalSource = raw;
    operation = null;
    selected = null;
    dismissedJobId = null;
    _dismissedAt = null;
    jobs = [];
    pending = null;
    cursor = 0;
    installation = null;
    panelAccess = null;
    panelDiscovery = null;
    egress = null;
    relay = null;
    relayStateIssue = null;
    panelVerifiedAt = null;
    activeComponent = null;
    _identity = current;
    if (raw != null) {
      final json = decodeRunnerObject(raw);
      if (json['version'] != 1) throw const RunnerFailure(RunnerIssue.storage);
      if (json['identity'] == current) {
        if (json['activeComponent'] case final String comp) {
          activeComponent = comp;
        }
        if (json['operation'] case final Map metadata) {
          operation = ServerOperation.fromJson(metadata);
          operation!.validatePending(json['pending'] as Map?);
        }
        if (json['egress'] case final Map savedEgress) {
          egress = Map<String, dynamic>.from(savedEgress);
        }
        if (json['relay'] case final Map savedRelay) {
          relay = _publicRelay(savedRelay);
        }
        if (json['panelDiscovery'] case final Map discovery) {
          panelDiscovery = Map<String, dynamic>.from(discovery);
        }
        if (json['panelAccess'] case final Map access) {
          panelAccess = PanelAccess.fromJson(Map<String, dynamic>.from(access));
          panelVerifiedAt = DateTime.tryParse(
            json['panelVerifiedAt'] as String? ?? '',
          );
        }
        if (json['selected'] case final Map job) {
          selected = RunnerJob.fromJson(Map<String, dynamic>.from(job));
        }
        if (json['dismissedJob'] case {
          'id': final String id,
          'sequence': final int sequence,
        }) {
          dismissedJobId = id;
          _dismissedAt = sequence;
        }
        if (json['pending'] case final Map request) {
          pending = RunnerRequest.fromJson(Map<String, Object?>.from(request));
          if (pending?.json['component'] case final String comp) {
            activeComponent ??= comp;
          } else if (pending?.json['kind'] == 'component_upgrade_apply') {
            try {
              final payload = jsonDecode(
                pending!.json['payload'] as String? ?? '{}',
              );
              if (payload['component'] case final String comp) {
                activeComponent ??= comp;
              }
            } catch (_) {}
          }
        }
        cursor = json['cursor'] as int;
        if (cursor < 0 || cursor > (selected?.sequence ?? 0)) {
          throw const RunnerFailure(RunnerIssue.storage);
        }
      }
    }
    _loaded = true;
  }

  Future<void> _save() async {
    if (store == null) throw const RunnerFailure(RunnerIssue.storage);
    final previous = _journalSource == null
        ? null
        : decodeRunnerObject(_journalSource!);
    // Only a newly approved ID establishes ownership here. Loading an old
    // pending request (including legacy records) grants no automatic authority.
    if (_deviceId != null &&
        pending != null &&
        pending!.id != operation?.operationId &&
        pending!.id != (previous?['pending'] as Map?)?['id']) {
      operation = ServerOperation(
        operationId: pending!.id!,
        executorDeviceId: _deviceId!,
        expectedRevision: pending!.json['fingerprint'] as String?,
      );
    }
    final source = jsonEncode({
      'version': 1,
      'identity': _identity,
      'pending': observesOperation ? (previous?['pending']) : pending?.json,
      'selected': observesOperation
          ? (previous?['selected'])
          : selected?.toJson(),
      'cursor': observesOperation ? (previous?['cursor'] ?? 0) : cursor,
      if (operation != null) 'operation': operation!.toJson(),
      if (activeComponent != null) 'activeComponent': activeComponent,
      if (dismissedJobId != null)
        'dismissedJob': {'id': dismissedJobId, 'sequence': _dismissedAt},
      'egress': egress,
      'relay': relay,
      'panelDiscovery': panelDiscovery,
      'panelAccess': panelAccess?.toJson(),
      'panelVerifiedAt': panelVerifiedAt?.toUtc().toIso8601String(),
    });
    if (store case final ConditionalRunnerJournalStore conditional) {
      await conditional.writeRunnerJournalIfUnchanged(
        serverId,
        source,
        expectedSource: _journalSource,
      );
    } else {
      await store!.writeRunnerJournal(serverId, source);
    }
    _journalSource = source;
  }

  Future<void> _checkCurrentOperation() async {
    if (store is ConditionalRunnerJournalStore &&
        await store!.readRunnerJournal(serverId) != _journalSource) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
  }

  Future<void> _claimOperation(RunnerRequest request) async {
    if (_deviceId != null) {
      operation = ServerOperation(
        operationId: request.id!,
        executorDeviceId: _deviceId!,
        expectedRevision: request.json['fingerprint'] as String?,
      );
    }
    await _save();
    await _checkCurrentOperation();
  }

  /// Stops waiting for the request in flight. The server may already have
  /// acted on it, so callers read the state again instead of assuming none.
  void cancelAction() => _token?.cancel();

  Future<void> _run(
    Future<void> Function(RunnerTransport, CancellationToken) action, {
    bool background = false,
  }) {
    final remote = transport();
    if (remote == null) return Future.value();
    return _exclusive(
      (token) => action(remote, token),
      background: background,
      reachesServer: true,
    );
  }

  /// Runs [action] alone against the journal: one runner operation at a
  /// time, with the journal loaded and failures mapped to [error]. A local
  /// action ([reachesServer] false) needs no connection.
  Future<void> _exclusive(
    Future<void> Function(CancellationToken) action, {
    bool background = false,
    bool reachesServer = false,
  }) async {
    if (busy || backgroundBusy || _disposed) return;
    if (background) {
      backgroundBusy = true;
    } else {
      busy = true;
    }
    final idle = Completer<void>();
    _idle = idle;
    error = null;
    responseCode = null;
    final token = CancellationToken();
    _token = token;
    _notify();
    try {
      await _load();
      token.check();
      await action(token);
      token.check();
      if (reachesServer) connectionLost = false;
    } on SshFailure catch (e) {
      if (!token.isCancelled && !_disposed) {
        accessFailure(e.issue);
        connectionLost = true;
        error = RunnerIssue.unavailable;
      }
    } on RunnerFailure catch (e) {
      if (!token.isCancelled && !_disposed) error = e.issue;
    } on SyncMergeFailure {
      if (!token.isCancelled && !_disposed) {
        error = RunnerIssue.conflict;
        responseCode = 'sync_conflict';
        _loaded = false;
      }
    } on VaultFailure {
      if (!token.isCancelled && !_disposed) error = RunnerIssue.storage;
    } catch (_) {
      if (!token.isCancelled && !_disposed) {
        error = (connectionLost || !connected)
            ? RunnerIssue.unavailable
            : RunnerIssue.invalidResponse;
      }
    } finally {
      if (_token == token) {
        if (background) {
          backgroundBusy = false;
        } else {
          busy = false;
        }
        _token = null;
      }
      if (_idle == idle) _idle = null;
      idle.complete();
      _notify();
      if (_pendingConnectionReady && !_disposed && transport() != null) {
        _pendingConnectionReady = false;
        connectionReady();
      }
      if (_softwareRefreshPending && !_disposed) {
        _softwareRefreshPending = false;
        refreshSoftware?.call();
      }
      if (_applySystemUpgrade && !_disposed) {
        _applySystemUpgrade = false;
        await applyApt();
      }
    }
  }

  Future<void> refresh({bool prepare = false}) async {
    // The background job poll runs every few seconds. An explicit refresh
    // waits for it instead of being dropped, so the button and
    // pull-to-refresh always do something.
    if (backgroundBusy && !busy) await waitUntilIdle();
    return _refresh(prepare);
  }

  Future<void> _refresh(bool prepare) => _run((remote, token) async {
    installation = await remote.inspect(token);
    token.check();
    if (installation!.state == 'conflict') {
      throw const RunnerFailure(RunnerIssue.conflict);
    }
    if (prepare &&
        installation!.supported &&
        (installation!.release == null ||
            installation!.upgradable ||
            installation!.release == remote.bundledRelease) &&
        (!installed ||
            installation!.active == false ||
            installation!.upgradable)) {
      installation = await remote.install(
        installation!,
        token,
        sudoPassword: password(),
      );
      token.check();
    }
    if (installation!.release != null &&
        installation!.release != remote.bundledRelease) {
      if (installation!.upgradable) return;
      throw const RunnerFailure(RunnerIssue.incompatible);
    }
    if (installation!.state != 'installed') return;
    final list = await remote.request(
      RunnerRequest.list(),
      token,
      sudoPassword: password(),
    );
    token.check();
    responseCode = list.code;
    alive = list.alive;
    jobs = list.jobs;
    final id =
        pending?.id ??
        jobs.where((j) => !j.terminal).firstOrNull?.id ??
        // A closed job gives way to the newest one (the list is newest first).
        switch (selected) {
          final job? when !isDismissed(job) => job.id,
          _ => null,
        } ??
        jobs.firstOrNull?.id;
    if (id != null) await _readJob(remote, token, id);
    if (prepare) await _discoverPanel(remote, token);
  });

  /// A live job already has a durable ID. Poll only its incremental status;
  /// explicit refresh and a new connection still inspect and list the runner.
  Future<void> pollActiveJob() => _run((remote, token) async {
    final id =
        pending?.id ??
        (selected?.terminal == false ? selected?.id : null) ??
        jobs.where((job) => !job.terminal).firstOrNull?.id ??
        (watchesUpgrade ? _upgradeWatchId : null);
    if (id != null) await _readJob(remote, token, id);
  }, background: true);

  /// The full event timeline of one job, for its details sheet: the list
  /// carries only each job's last event. Reading an old job is not acting
  /// on it, so [selected], [jobs], the cursor and the error state stay as
  /// they are. Null when offline, the runner forgot the job or the read
  /// failed.
  Future<RunnerJob?> readJobHistory(String id) async {
    final remote = transport();
    if (remote == null || _disposed) return null;
    try {
      final response = await remote.request(
        RunnerRequest.status(id, 0),
        CancellationToken(),
        sudoPassword: password(),
      );
      final job = response.jobs.firstOrNull;
      return response.code == 'ok' && job?.id == id ? job : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> connectPanel(int port, String username, String password) async {
    var success = false;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.fromJson({
          'version': 1,
          'action': 'panel_connect',
          'payload': jsonEncode({
            'port': port,
            'username': username,
            'password': password,
          }),
        }),
        token,
        sudoPassword: this.password(),
      );
      token.check();
      responseCode = response.code;
      if (response.code != 'ok' || response.panelAccess == null) {
        throw const RunnerFailure(RunnerIssue.invalidResponse);
      }
      panelAccess = response.panelAccess;
      panelLoginRequired = false;
      panelVerifiedAt = DateTime.now();
      await _save();
      success = true;
    });
    return success;
  }

  Future<Map<String, dynamic>?> readInbound(int id) async {
    if (panelAccess == null) return null;
    Map<String, dynamic>? result;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.fromJson({
          'version': 1,
          'action': 'inbound_read',
          'id': panelAccess!.id,
          'payload': jsonEncode({'inboundId': id}),
        }),
        token,
        sudoPassword: password(),
      );
      token.check();
      responseCode = response.code;
      result = response.inboundSnapshot;
    });
    return result;
  }

  Future<Map<String, dynamic>?> planInbound(
    Map<String, Object?> payload,
  ) async {
    if (panelAccess == null || !canPlan) return null;
    Map<String, dynamic>? result;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.fromJson({
          'version': 1,
          'action': 'inbound_plan',
          'id': panelAccess!.id,
          'payload': jsonEncode(payload),
        }),
        token,
        sudoPassword: password(),
      );
      token.check();
      responseCode = response.code;
      result = response.inboundPlan;
    });
    return result;
  }

  Future<bool> applyInbound(
    Map<String, Object?> payload,
    String fingerprint, {
    bool remove = false,
  }) async {
    if (panelAccess == null || !canStart) return false;
    var success = false;
    await _run((remote, token) async {
      final id = List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      pending = RunnerRequest.fromJson({
        'version': 1,
        'action': 'submit',
        'id': id,
        'kind': remove ? 'inbound_remove' : 'inbound_update',
        'count': 3,
        'interval': 1,
        'payload': jsonEncode({...payload, 'panelId': panelAccess!.id}),
        'fingerprint': fingerprint,
      });
      selected = null;
      cursor = 0;
      await _save();
      token.check();
      await _submit(remote, token);
      success = responseCode == 'ok';
    });
    return success;
  }

  Future<void> setInboundEnabled(int id, bool enabled) =>
      requestAction(() async {
        final snapshot = await readInbound(id);
        if (snapshot == null) return;
        final payload = <String, Object?>{
          'inboundId': id,
          'observedHash': snapshot['fingerprint'],
          'patch': {'enable': enabled},
        };
        final plan = await planInbound(payload);
        if (plan != null) {
          await applyInbound(payload, plan['fingerprint'] as String);
        }
      });

  Future<void> _readEgress(
    RunnerTransport remote,
    CancellationToken token,
  ) async {
    final result = await remote.request(
      RunnerRequest.fromJson({'version': 1, 'action': 'egress_state'}),
      token,
      sudoPassword: password(),
    );
    token.check();
    if (result.code == 'ok' && result.egress != null) egress = result.egress;
  }

  Future<void> refreshEgress() => requestAction(() async {
    await _run((remote, token) async {
      await _readEgress(remote, token);
      await _save();
    });
  });

  Future<bool> applyEgress({
    required bool enabled,
    required String uri,
    int socksPort = 0,
    String? observedHash,
  }) async {
    final expected = observedHash ?? egress?['observedHash'];
    var success = false;
    await requestAction(() async {
      if (panelAccess == null || panelLoginRequired) return;
      await _run((remote, token) async {
        // The editor's observation is retained; a concurrent change is a conflict.
        if (egress == null) await _readEgress(remote, token);
        if (egress == null) return;
        final payload = <String, Object?>{
          'panelId': panelAccess!.id,
          'enabled': enabled,
          'uri': uri,
          'socksPort': socksPort,
          'observedHash': expected ?? egress!['observedHash'],
        };
        success = await _submitEgress(
          remote,
          token,
          payload,
          'egress_apply',
          'egress_plan',
        );
      });
    });
    return success;
  }

  Future<bool> _submitEgress(
    RunnerTransport remote,
    CancellationToken token,
    Map<String, Object?> payload,
    String kind,
    String action, {
    Map<String, dynamic>? Function(RunnerResponse) result = _egressResult,
  }) async {
    final plan = await remote.request(
      RunnerRequest.fromJson({
        'version': 1,
        'action': action,
        'payload': jsonEncode(payload),
      }),
      token,
      sudoPassword: password(),
    );
    token.check();
    responseCode = plan.code;
    if (plan.code == 'panel_auth_failed') panelLoginRequired = true;
    final fingerprint = result(plan)?['fingerprint'];
    if (plan.code != 'ok' || fingerprint is! String) return false;
    pending = RunnerRequest.fromJson({
      'version': 1,
      'action': 'submit',
      'id': newVpnId(),
      'kind': kind,
      'count': 3,
      'interval': 1,
      'payload': jsonEncode(payload),
      'fingerprint': fingerprint,
    });
    selected = null;
    cursor = 0;
    await _save();
    token.check();
    await _submit(remote, token);
    return responseCode == 'ok';
  }

  static Map<String, dynamic>? _egressResult(RunnerResponse r) => r.egress;

  /// Only the public fields: nothing secret reaches the journal even if a
  /// runner answered with more.
  static Map<String, dynamic> _publicRelay(Map value) => {
    'inbounds': [
      for (final e in value['inbounds'] as List? ?? const [])
        if (e is Map &&
            e['panelId'] is String &&
            e['inboundId'] is int &&
            e['tag'] is String)
          {
            'panelId': e['panelId'],
            'inboundId': e['inboundId'],
            'tag': e['tag'],
            'stale': e['stale'] == true,
          },
    ],
    'observedHash': value['observedHash'] as String,
  };

  Future<void> _readRelay(
    RunnerTransport remote,
    CancellationToken token,
  ) async {
    final result = await remote.request(
      RunnerRequest.fromJson({'version': 1, 'action': 'relay_state'}),
      token,
      sudoPassword: password(),
    );
    token.check();
    if (result.code == 'panel_auth_failed') panelLoginRequired = true;
    if (result.code != 'ok') {
      // An unreachable panel says nothing about relay: keep the last state.
      relayStateIssue = result.code;
    } else if (result.relay?['observedHash'] is String) {
      relay = _publicRelay(result.relay!);
      relayStateIssue = null;
    }
  }

  Future<void> refreshRelay() => requestAction(() async {
    await _run((remote, token) async {
      await _readRelay(remote, token);
      await _save();
    });
  });

  /// Turns the direct exit of [inboundId] on the connected panel on or off.
  /// [observedHash] defaults to the state the caller showed; a change since
  /// then is a conflict, as for egress.
  Future<bool> applyRelay({
    required int inboundId,
    required bool enabled,
    String? observedHash,
  }) async {
    final expected = observedHash ?? relay?['observedHash'] as String?;
    var success = false;
    await requestAction(() async {
      if (panelAccess == null || panelLoginRequired) return;
      await _run((remote, token) async {
        if (relay == null) await _readRelay(remote, token);
        if (relay == null) {
          responseCode = relayStateIssue ?? 'relay_failed';
          return;
        }
        final payload = <String, Object?>{
          'panelId': panelAccess!.id,
          'inboundId': inboundId,
          'enabled': enabled,
          'observedHash': expected ?? relay!['observedHash'],
        };
        success = await _submitEgress(
          remote,
          token,
          payload,
          'relay_apply',
          'relay_plan',
          result: (r) => r.relay,
        );
      });
    });
    return success;
  }

  /// The service link of a relay inbound, named "[label]" in its fragment.
  /// It is returned only to the caller: never stored or logged.
  Future<String?> relayLink({
    required int inboundId,
    required String endpoint,
    required int externalPort,
    required String label,
  }) async {
    String? uri;
    await requestAction(() async {
      if (panelAccess == null || panelLoginRequired) return;
      await _run((remote, token) async {
        final result = await remote.request(
          RunnerRequest.fromJson({
            'version': 1,
            'action': 'relay_link',
            'payload': jsonEncode({
              'panelId': panelAccess!.id,
              'inboundId': inboundId,
              'endpoint': endpoint,
              'externalPort': externalPort,
            }),
          }),
          token,
          sudoPassword: password(),
        );
        token.check();
        responseCode = result.code;
        if (result.code == 'panel_auth_failed') panelLoginRequired = true;
        if (result.code == 'ok' && result.relay?['uri'] is String) {
          uri = namedShareLink(result.relay!['uri'] as String, label);
        }
      });
    });
    return uri;
  }

  Future<String?> createEgressAccess({
    required String source,
    required int inboundId,
    required String endpoint,
    required int externalPort,
  }) async {
    String? uri;
    await requestAction(() async {
      if (panelAccess == null || panelLoginRequired) return;
      await _run((remote, token) async {
        final payload = <String, Object?>{
          'panelId': panelAccess!.id,
          'source': source,
          'inboundId': inboundId,
          'endpoint': endpoint,
          'externalPort': externalPort,
        };
        if (!await _submitEgress(
          remote,
          token,
          payload,
          'egress_access',
          'egress_access_plan',
        )) {
          return;
        }
        final id = selected!.id;
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (DateTime.now().isBefore(deadline)) {
          token.check();
          await _readJob(remote, token, id);
          if (selected!.terminal) break;
          await Future<void>.delayed(const Duration(milliseconds: 750));
        }
        if (selected?.status != 'succeeded') return;
        final result = await remote.request(
          RunnerRequest.fromJson({
            'version': 1,
            'action': 'egress_access_read',
            'id': id,
          }),
          token,
          sudoPassword: password(),
        );
        token.check();
        responseCode = result.code;
        if (result.code == 'ok') uri = result.egress?['uri'] as String?;
      });
    });
    return uri;
  }

  Map<String, dynamic>? ttDiscovery, ttCertificates;
  Future<Map<String, dynamic>?> ttRequest(
    String action, {
    String? id,
    Map<String, Object?>? payload,
  }) async {
    Map<String, dynamic>? result;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.fromJson({
          'version': 1,
          'action': action,
          'id': ?id,
          if (payload != null) 'payload': jsonEncode(payload),
        }),
        token,
        sudoPassword: password(),
      );
      token.check();
      responseCode = response.code;
      if (response.code != 'ok' || response.tt == null) return;
      result = response.tt;
      if (action == 'tt_discover') ttDiscovery = result;
      if (action == 'tt_certificates') ttCertificates = result;
    });
    return result;
  }

  Future<bool> applyTtJob(
    Map<String, Object?> payload,
    String fingerprint, {
    String kind = 'tt_external_edit',
    int count = 3,
  }) async {
    if (!canStart || !installed) return false;
    var success = false;
    await _run((remote, token) async {
      pending = RunnerRequest.fromJson({
        'version': 1,
        'action': 'submit',
        'id': newVpnId(),
        'kind': kind,
        'count': count,
        'interval': 1,
        'payload': jsonEncode(payload),
        'fingerprint': fingerprint,
      });
      selected = null;
      cursor = 0;
      await _save();
      token.check();
      await _submit(remote, token);
      success = responseCode == 'ok';
    });
    return success;
  }

  Map<String, dynamic>? awgDiscovery;
  Future<Map<String, dynamic>?> awgRequest(
    String action, {
    String? id,
    Map<String, Object?>? payload,
  }) async {
    Map<String, dynamic>? result;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.fromJson({
          'version': 1,
          'action': action,
          'id': ?id,
          if (payload != null) 'payload': jsonEncode(payload),
        }),
        token,
        sudoPassword: password(),
      );
      token.check();
      responseCode = response.code;
      if (response.code != 'ok' || response.awgExternal == null) return;
      result = response.awgExternal;
      if (action == 'awg_discover') awgDiscovery = result;
    });
    return result;
  }

  Future<bool> applyExternalAwg(
    Map<String, Object?> payload,
    String fingerprint,
  ) async {
    if (!canStart || !installed) return false;
    var success = false;
    await _run((remote, token) async {
      pending = RunnerRequest.fromJson({
        'version': 1,
        'action': 'submit',
        'id': newVpnId(),
        'kind': 'awg_external_edit',
        'count': 3,
        'interval': 1,
        'payload': jsonEncode(payload),
        'fingerprint': fingerprint,
      });
      selected = null;
      cursor = 0;
      await _save();
      token.check();
      await _submit(remote, token);
      success = responseCode == 'ok';
    });
    return success;
  }

  Future<Map<String, dynamic>?> scanReality(String target, String sni) async {
    final panel = panelAccess;
    if (panel == null || !installed || !connected || busy) return null;
    Map<String, dynamic>? result;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.realityScan(panel.id, target, sni),
        token,
        sudoPassword: password(),
      );
      token.check();
      if (response.code != 'ok' || response.realityScan == null) {
        throw const RunnerFailure(RunnerIssue.invalidResponse);
      }
      result = response.realityScan;
    });
    return result;
  }

  Future<void> rebootServer() => requestAction(() async {
    await _run((remote, token) async {
      if (pending != null || jobs.any((job) => !job.terminal)) return;
      pending = RunnerRequest.fromJson({
        'version': 1,
        'action': 'submit',
        'kind': 'server_reboot',
        'id': List.generate(
          16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        'count': 2,
        'interval': 1,
      });
      selected = null;
      cursor = 0;
      await _save();
      token.check();
      await _submit(remote, token);
    });
  });

  Future<void> installPanelCli() => _run((remote, token) async {
    final result = await remote.request(
      RunnerRequest.panelCli(),
      token,
      sudoPassword: password(),
    );
    token.check();
    if (result.code != 'ok' || result.panelDiscovery == null) {
      throw const RunnerFailure(RunnerIssue.installFailed);
    }
    panelDiscovery = result.panelDiscovery;
    await _save();
  });

  Future<void> discoverPanel() => _run(_discoverPanel);

  Future<void> _discoverPanel(
    RunnerTransport remote,
    CancellationToken token,
  ) async {
    final result = await remote.request(
      RunnerRequest.panelDiscover(),
      token,
      sudoPassword: password(),
    );
    token.check();
    if (result.code != 'ok' || result.panelDiscovery == null) {
      panelDiscovery = {'failed': true};
      return;
    }
    panelDiscovery = result.panelDiscovery;
    panelAccess = result.panelAccess;
    panelVerifiedAt = null;
    if (panelDetected) {
      choosingPanel = false;
      panelSelected = false;
      panelPort = panels.firstOrNull?['port'] as int? ?? panelAccess?.port;
    }
    await _save();
    if (panelAccess != null) await _verifyPanel(remote, token, panelAccess!.id);
  }

  Future<void> prepareInstall() => _run((remote, token) async {
    final next = await remote.inspect(token);
    token.check();
    installation = next;
    if (!next.supported) throw const RunnerFailure(RunnerIssue.prerequisites);
    if (next.state == 'conflict') {
      throw const RunnerFailure(RunnerIssue.conflict);
    }
    if (next.release != null &&
        next.release != remote.bundledRelease &&
        !next.upgradable) {
      throw const RunnerFailure(RunnerIssue.incompatible);
    }
    installPlan = next;
  });
  void dismissPlan() {
    if (busy) return;
    installPlan = null;
    _notify();
  }

  void chooseComponents() {
    if (busy || panelDetected) return;
    choosingPanel = true;
    panelSelected = false;
    panelPlan = null;
    panelUpdatePlan = null;
    componentPlan = null;
    componentRunnerPlan = null;
    _notify();
  }

  void selectPanel(bool value) {
    if (busy) return;
    panelSelected = value;
    panelPlan = null;
    panelUpdatePlan = null;
    componentPlan = null;
    componentRunnerPlan = null;
    _notify();
  }

  void changePanelPort(String value) {
    if (busy) return;
    final port = int.tryParse(value);
    panelPort = port != null && port >= 1024 && port <= 65535 ? port : null;
    panelPlan = null;
    panelUpdatePlan = null;
    componentPlan = null;
    componentRunnerPlan = null;
    _notify();
  }

  void dismissComponents() {
    if (busy) return;
    choosingPanel = false;
    panelPlan = null;
    panelUpdatePlan = null;
    componentPlan = null;
    componentRunnerPlan = null;
    panelRunnerPlan = null;
    _notify();
  }

  Future<void> openPanelPlan() {
    if (busy ||
        panelDetected ||
        pending != null ||
        jobs.any((j) => !j.terminal)) {
      return Future.value();
    }
    choosingPanel = true;
    panelSelected = true;
    panelPort = 0;
    componentPlan = null;
    aptPlan = null;
    choosingAptUpdate = false;
    return preparePanel();
  }

  bool get canPlan =>
      connected && !busy && pending == null && !jobs.any((j) => !j.terminal);

  /// Closes the finished selected job on this device. Hidden at once;
  /// written after the operation in flight, alone, like any journal change.
  Future<void> dismissJob() async {
    final job = selected;
    if (job == null || !job.terminal || _disposed) return;
    _dismiss(job);
    if (job.kind == 'component_install') activeComponent = null;
    _notify();
    while ((busy || backgroundBusy) && !_disposed) {
      final idle = _idle;
      if (idle == null) return;
      await idle.future;
    }
    await _exclusive((_) async {
      // A reload may have replaced the journal: close only what was shown.
      if (selected?.id != job.id || selected?.terminal != true) return;
      dismissedJobId = job.id;
      _dismissedAt = job.sequence;
      if (job.kind == 'component_install') activeComponent = null;
      await _save();
    });
  }

  void dismissApt() {
    if (busy) return;
    _systemUpdate = false;
    aptPlan = null;
    choosingAptUpdate = false;
    _notify();
  }

  Future<void> prepareApt({required bool upgrade}) {
    if (!canPlan) return Future.value();
    panelPlan = null;
    panelUpdatePlan = null;
    componentPlan = null;
    aptPlan = null;
    choosingAptUpdate = !upgrade;
    if (!upgrade) {
      _notify();
      return Future.value();
    }
    return _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.aptPlan(),
        token,
        sudoPassword: password(),
      );
      token.check();
      responseCode = response.code;
      if (response.code != 'ok' || response.aptPlan == null) {
        if (response.code == 'apt_conflict' || response.code == 'conflict') {
          throw const RunnerFailure(RunnerIssue.conflict);
        }
        if (response.code == 'apt_prerequisites') {
          throw const RunnerFailure(RunnerIssue.prerequisites);
        }
        return;
      }
      aptPlan = response.aptPlan;
    });
  }

  /// The explicit system-update action refreshes indexes and installs the
  /// resulting, fingerprinted package set without a second confirmation;
  /// with [upgrade] false it stops at the plan ([aptPlan]), for Upgrade.
  Future<void> updateSystem({bool upgrade = true}) async {
    if (!canStart) return;
    await prepareApt(upgrade: false);
    if (!choosingAptUpdate || !canStart) return;
    _systemUpdate = true;
    _systemUpgrade = upgrade;
    final before = selected?.id;
    await applyApt();
    // Only a submitted (or possibly submitted) index refresh continues with
    // the upgrade. A refusal (busy, capacity) or a skipped start leaves no
    // job: a later unrelated apt_update must not upgrade packages.
    if (pending == null && (selected == null || selected!.id == before)) {
      _systemUpdate = false;
    }
  }

  Future<void> retryJob() => requestAction(() async {
    prepareResume();
    if (resumePlan != null) await applyResume();
  });

  Future<void> applyApt() {
    if (!canStart ||
        (!choosingAptUpdate && (aptPlan?['packages'] as List? ?? []).isEmpty)) {
      return Future.value();
    }
    final fingerprint = choosingAptUpdate
        ? null
        : aptPlan!['fingerprint'] as String;
    return _run((remote, token) async {
      final random = Random.secure();
      final id = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      pending = RunnerRequest.apt(id, fingerprint: fingerprint);
      selected = null;
      cursor = 0;
      await _save();
      token.check();
      aptPlan = null;
      choosingAptUpdate = false;
      await _submit(remote, token);
    });
  }

  Future<void> preparePanel() {
    if (panelDetected ||
        !panelSelected ||
        panelPort == null ||
        pending != null) {
      return Future.value();
    }
    return _run((remote, token) async {
      final runnerPlan = await remote.inspect(token);
      token.check();
      installation = runnerPlan;
      if (!runnerPlan.supported) {
        throw const RunnerFailure(RunnerIssue.prerequisites);
      }
      if (runnerPlan.state == 'conflict') {
        throw const RunnerFailure(RunnerIssue.conflict);
      }
      if (runnerPlan.release != null &&
          runnerPlan.release != remote.bundledRelease &&
          !runnerPlan.upgradable) {
        throw const RunnerFailure(RunnerIssue.incompatible);
      }
      final result = await remote.request(
        RunnerRequest.panelPlan(panelPort!),
        token,
        sudoPassword: password(),
      );
      token.check();
      panelPlan = result.panelPlan;
      panelPort = panelPlan?.port;
      panelRunnerPlan = runnerPlan;
      if (panelPlan == null) {
        throw const RunnerFailure(RunnerIssue.invalidResponse);
      }
    });
  }

  bool get canApplyPanel =>
      connected &&
      !busy &&
      pending == null &&
      panelSelected &&
      panelPlan?.canApply == true &&
      panelRunnerPlan != null &&
      !jobs.any((job) => !job.terminal);

  Future<void> applyPanel() {
    if (!canApplyPanel) return Future.value();
    final plan = panelPlan!;
    final runnerPlan = panelRunnerPlan!;
    return _run((remote, token) async {
      // Revalidate component snapshot before even preparing its runner dependency.
      final current = await remote.request(
        RunnerRequest.panelPlan(plan.port),
        token,
        sudoPassword: password(),
      );
      token.check();
      if (current.panelPlan?.fingerprint != plan.fingerprint ||
          current.panelPlan?.canApply != true) {
        panelPlan = null;
        panelUpdatePlan = null;
        componentPlan = null;
        componentRunnerPlan = null;
        throw const RunnerFailure(RunnerIssue.conflict);
      }
      installation = await remote.install(
        runnerPlan,
        token,
        sudoPassword: password(),
      );
      token.check();
      final random = Random.secure();
      final id = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      pending = RunnerRequest.panelInstall(id, plan);
      selected = null;
      cursor = 0;
      await _save();
      token.check();
      choosingPanel = false;
      panelPlan = null;
      panelUpdatePlan = null;
      componentPlan = null;
      componentRunnerPlan = null;
      panelRunnerPlan = null;
      await _submit(remote, token);
    });
  }

  Future<void> preparePanelUpdate() async {
    if (!canPlan || !installed || panelAccess == null || panelLoginRequired) {
      return;
    }
    await _run((remote, token) async {
      panelPlan = null;
      componentPlan = null;
      aptPlan = null;
      choosingAptUpdate = false;
      panelUpdatePlan = null;
      final response = await remote.request(
        RunnerRequest.panelUpdatePlan(panelAccess!.id),
        token,
        sudoPassword: password(),
      );
      token.check();
      responseCode = response.code;
      if (response.code != 'ok' || response.panelUpdatePlan == null) {
        if (response.code == 'panel_auth_failed') panelLoginRequired = true;
        if (response.code == 'panel_update_incompatible' ||
            response.code == 'incompatible') {
          throw const RunnerFailure(RunnerIssue.incompatible);
        }
        if (response.code == 'conflict' || response.code == 'panel_conflict') {
          throw const RunnerFailure(RunnerIssue.conflict);
        }
        if (response.code == 'prerequisites' ||
            response.code == 'panel_prerequisites') {
          throw const RunnerFailure(RunnerIssue.prerequisites);
        }
        if (response.code == 'busy') {
          throw const RunnerFailure(RunnerIssue.unavailable);
        }
        throw const RunnerFailure(RunnerIssue.invalidResponse);
      }
      panelUpdatePlan = response.panelUpdatePlan;
    });
  }

  void dismissPanelUpdate() {
    if (busy) return;
    panelUpdatePlan = null;
    _notify();
  }

  Future<void> applyPanelUpdate() async {
    final plan = panelUpdatePlan;
    if (!canStart || plan?.canApply != true) return;
    await _run((remote, token) async {
      final current = await remote.request(
        RunnerRequest.panelUpdatePlan(plan!.panelId),
        token,
        sudoPassword: password(),
      );
      token.check();
      if (current.panelUpdatePlan?.fingerprint != plan.fingerprint ||
          current.panelUpdatePlan?.canApply != true) {
        panelUpdatePlan = null;
        throw const RunnerFailure(RunnerIssue.conflict);
      }
      final random = Random.secure();
      final id = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      panelTarget = plan.panelVersion;
      pending = RunnerRequest.panelUpdate(id, plan);
      selected = null;
      cursor = 0;
      await _save();
      await _submit(remote, token);
      panelUpdatePlan = null;
    });
  }

  Future<void> prepareComponent(
    String component, {
    Map<String, Object?>? choice,
  }) => _run((remote, token) async {
    activeComponent = component;
    componentChoice = choice == null ? '' : jsonEncode(choice);
    panelPlan = null;
    panelUpdatePlan = null;
    aptPlan = null;
    choosingAptUpdate = false;
    componentPlan = null;
    componentRunnerPlan = null;
    final runnerPlan = await remote.inspect(token);
    token.check();
    if (!runnerPlan.supported) {
      throw const RunnerFailure(RunnerIssue.prerequisites);
    }
    if (runnerPlan.state == 'conflict') {
      throw const RunnerFailure(RunnerIssue.conflict);
    }
    if (runnerPlan.release != null &&
        runnerPlan.release != remote.bundledRelease &&
        !runnerPlan.upgradable) {
      throw const RunnerFailure(RunnerIssue.incompatible);
    }
    final response = await remote.request(
      RunnerRequest.componentPlan(component, choice: componentChoice),
      token,
      sudoPassword: password(),
    );
    token.check();
    if (response.code != 'ok' || response.componentPlan == null) {
      throw const RunnerFailure(RunnerIssue.invalidResponse);
    }
    componentPlan = response.componentPlan;
    componentRunnerPlan = runnerPlan;
  });

  void dismissComponent() {
    if (busy) return;
    componentPlan = null;
    componentRunnerPlan = null;
    if (selected == null || selected?.terminal == true) {
      activeComponent = null;
    }
    _notify();
  }

  Future<Map<String, dynamic>?> prepareProtocolRemoval(String protocol) async {
    if (!canStart) return null;
    Map<String, dynamic>? result;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.fromJson({
          'version': 1,
          'action': 'protocol_remove_plan',
          'protocol': protocol,
        }),
        token,
        sudoPassword: password(),
      );
      responseCode = response.code;
      if (response.code != 'ok') {
        throw RunnerFailure(
          response.code == 'protocol_remove_conflict'
              ? RunnerIssue.conflict
              : RunnerIssue.unavailable,
        );
      }
      result = response.removalPlan;
    });
    return result;
  }

  Future<bool> removeProtocol(
    Map<String, dynamic> plan,
    Future<bool> Function() retireConnections,
  ) async {
    if (!canStart) return false;
    var submitted = false;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.fromJson({
          'version': 1,
          'action': 'protocol_remove_plan',
          'protocol': plan['protocol'],
        }),
        token,
        sudoPassword: password(),
      );
      if (response.code != 'ok' ||
          response.removalPlan?['fingerprint'] != plan['fingerprint']) {
        throw const RunnerFailure(RunnerIssue.conflict);
      }
      // Persist the local tombstones/paused desired state before sending the
      // job, so reconnect or background reconciliation cannot recreate peers.
      if (!await retireConnections()) {
        throw const RunnerFailure(RunnerIssue.storage);
      }
      token.check();
      pending = RunnerRequest.fromJson({
        'version': 1,
        'action': 'submit',
        'id': List.generate(
          16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        'kind': 'protocol_remove',
        'count': 4,
        'interval': 1,
        'protocol': plan['protocol'],
        'fingerprint': plan['fingerprint'],
      });
      selected = null;
      cursor = 0;
      await _save();
      await _submit(remote, token);
      submitted = selected?.kind == 'protocol_remove' || pending != null;
    });
    return submitted;
  }

  Future<SshHardenPlan?> prepareSshHarden({
    required String username,
    required int port,
  }) async {
    if (!canStart) return null;
    SshHardenPlan? result;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.sshHardenPlan({'username': username, 'port': port}),
        token,
        sudoPassword: password(),
      );
      responseCode = response.code;
      if (response.code != 'ok') {
        throw const RunnerFailure(RunnerIssue.conflict);
      }
      result = response.sshHardenPlan;
    });
    return result;
  }

  Future<String?> submitSshHarden({
    required SshHardenPlan plan,
    required String username,
    required int port,
    required String sudoPassword,
    String? publicKey,
    int deadlineSeconds = 300,
    bool disableRootLogin = true,
    required Future<void> Function(String id) beforeSubmit,
  }) async {
    if (!canStart) return null;
    String? jobId;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.sshHardenPlan({'username': username, 'port': port}),
        token,
        sudoPassword: password(),
      );
      if (response.code != 'ok' ||
          response.sshHardenPlan?.fingerprint != plan.fingerprint) {
        throw const RunnerFailure(RunnerIssue.conflict);
      }
      token.check();
      final random = Random.secure();
      final id = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await beforeSubmit(id);
      token.check();
      pending = RunnerRequest.sshHarden(id, {
        'username': username,
        'port': port,
        'sudoPassword': sudoPassword,
        if (publicKey != null && publicKey.isNotEmpty) 'publicKey': publicKey,
        'disableRootLogin': disableRootLogin,
        'deadlineSeconds': deadlineSeconds,
      }, plan.fingerprint);
      selected = null;
      cursor = 0;
      await _save();
      await _submit(remote, token);
      if (selected?.id == id || pending?.id == id) jobId = id;
    });
    return jobId;
  }

  Future<void> clearHardenPending(String id) async {
    if (store != null) await _load();
    if (pending?.id == id && pending?.json['kind'] == 'ssh_harden') {
      pending = null;
      await _save();
    }
  }

  Future<SshHardenResult?> confirmSshHarden(String jobId) async {
    SshHardenResult? result;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.sshHardenConfirm(jobId),
        token,
        sudoPassword: password(),
      );
      responseCode = response.code;
      result = response.sshHardenResult;
    });
    return result;
  }

  Future<SshHardenResult?> abortSshHarden(String jobId) async {
    SshHardenResult? result;
    await _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.sshHardenAbort(jobId),
        token,
        sudoPassword: password(),
      );
      responseCode = response.code;
      result = response.sshHardenResult;
    });
    return result;
  }

  bool get canApplyComponent =>
      connected &&
      !busy &&
      pending == null &&
      componentPlan?.canApply == true &&
      componentRunnerPlan != null &&
      !jobs.any((j) => !j.terminal);

  Future<void> applyComponent() {
    if (!canApplyComponent) return Future.value();
    final plan = componentPlan!;
    final runnerPlan = componentRunnerPlan!;
    activeComponent = plan.component;
    return _run((remote, token) async {
      final current = await remote.request(
        RunnerRequest.componentPlan(plan.component, choice: componentChoice),
        token,
        sudoPassword: password(),
      );
      token.check();
      if (current.componentPlan?.fingerprint != plan.fingerprint ||
          current.componentPlan?.canApply != true) {
        componentPlan = null;
        throw const RunnerFailure(RunnerIssue.conflict);
      }
      installation = await remote.install(
        runnerPlan,
        token,
        sudoPassword: password(),
      );
      token.check();
      final random = Random.secure();
      final id = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      componentTarget = plan.version;
      pending = RunnerRequest.componentInstall(
        id,
        plan,
        choice: componentChoice,
      );
      selected = null;
      cursor = 0;
      await _save();
      token.check();
      componentPlan = null;
      componentRunnerPlan = null;
      choosingPanel = false;
      await _submit(remote, token);
    });
  }

  Future<void> verifyPanel() => _run((remote, token) async {
    final id =
        selected?.kind == 'panel_install' && selected?.status == 'succeeded'
        ? selected!.id
        : panelAccess?.id;
    if (id == null) return;
    await _verifyPanel(remote, token, id);
  });

  Future<void> checkComponentUpgrade(
    String component, {
    Map<String, Object?>? candidate,
  }) => _run((remote, token) async {
    if (installation?.upgradable == true ||
        !installed ||
        (bundledRelease != null && installation?.release != bundledRelease)) {
      installation = await remote.install(
        installation ?? await remote.inspect(token),
        token,
        sudoPassword: password(),
      );
      token.check();
    }
    componentUpgradePlan = null;
    final response = await remote.request(
      RunnerRequest.componentUpgradeCheck(component, candidate: candidate),
      token,
      sudoPassword: password(),
    );
    token.check();
    if (response.code == 'ok' && response.componentUpgrade != null) {
      activeComponent = component;
      componentUpgradePlan = response.componentUpgrade;
      _notify();
    } else {
      responseCode = response.code;
    }
  });

  /// What the version picker needs from the server for each component: its
  /// architecture, the installed version and the previous version that can
  /// be restored from a snapshot (`snapshot`).
  Future<Map<String, Map<String, dynamic>>> componentVersionPlans(
    List<String> components,
  ) async {
    final plans = <String, Map<String, dynamic>>{};
    await _run((remote, token) async {
      if (installation?.upgradable == true ||
          !installed ||
          (bundledRelease != null && installation?.release != bundledRelease)) {
        installation = await remote.install(
          installation ?? await remote.inspect(token),
          token,
          sudoPassword: password(),
        );
        token.check();
      }
      for (final component in components) {
        final response = await remote.request(
          RunnerRequest.componentUpgradeCheck(component),
          token,
          sudoPassword: password(),
        );
        token.check();
        if (response.code == 'ok' && response.componentUpgrade != null) {
          plans[component] = response.componentUpgrade!;
        }
      }
    });
    return plans;
  }

  /// Install exactly the chosen version (a release asset or the snapshot of
  /// the previous version) through the checked upgrade pipeline. Never Xray:
  /// its core changes only through [xrayVersionChoice] (UI-45).
  Future<void> installComponentVersion(Map<String, Object?> candidate) async {
    if (candidate['component'] == 'xray') {
      throw ArgumentError.value('xray', 'component');
    }
    await checkComponentUpgrade(
      candidate['component'] as String,
      candidate: candidate,
    );
    final plan = componentUpgradePlan;
    if (plan == null || plan['upgradable'] != true) return;
    final targets = plan['deviceChecks'];
    if (targets is Map && _checkedTargets(targets)) {
      await _checkedComponentUpgrade(plan, candidate, targets);
      return;
    }
    await applyComponentUpgrade(plan, candidate);
  }

  /// Whether the server names connections to check (or failed to list them).
  static bool _checkedTargets(Map targets) =>
      targets['error'] != null ||
      (targets['resources'] as List? ?? const []).isNotEmpty ||
      (targets['inbounds'] as List? ?? const []).any(
        (r) => r is Map && r['enabled'] == true,
      );

  /// A 3x-ui, TrustTunnel or AmneziaWG upgrade like the Xray transaction:
  /// every enabled connection is checked from this device through a server
  /// lease before the switch, the job keeps the leases, and its confirmation
  /// window waits for the same checks from the same network. Only a commit
  /// keeps the new version; anything else rolls it back on the server.
  Future<void> _checkedComponentUpgrade(
    Map<String, dynamic> plan,
    Map<String, Object?> candidate,
    Map targets,
  ) async {
    final component = (plan['component'] ?? candidate['component']) as String;
    final token = CancellationToken();
    _upgradeCheckToken = token;
    final deadline = Timer(const Duration(minutes: 14), token.cancel);
    upgradeChecks.clear();
    upgradeCheckPhase = 'baseline';
    upgradeCheckCode = '';
    activeComponent = component;
    _notify();
    final checks = deviceChecks?.call(token, _notify);
    String? jobId;
    final random = Random.secure();
    final key = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    var awaiting = false;
    try {
      if (targets['error'] case final String code) throw FormatException(code);
      if (checks == null || !checks.available) {
        throw const FormatException('upgrade_checks_unavailable');
      }
      await checks.open();
      String? panelId;
      if (component == 'panel') {
        panelId = targets['panelId'] as String?;
        final rows = (targets['inbounds'] as List).cast<Map>();
        final enabled = rows.where((r) => r['enabled'] == true).toList();
        if (panelId == null ||
            panelAccess == null ||
            enabled.any((r) => r['protocol'] != 'vless')) {
          throw const FormatException('upgrade_checks_coverage');
        }
        for (final row in enabled) {
          final comparison = UpgradeComparison(
            row['id'] as int,
            '${row['name']}',
            true,
          );
          upgradeChecks.add(comparison);
          await checks.before(
            await checks.panelInbound(row, panelId),
            comparison,
          );
        }
      } else {
        final target = component == 'trusttunnel'
            ? ttTarget(serverId)
            : awgTarget(serverId);
        for (final id in (targets['resources'] as List).cast<String>()) {
          final comparison = UpgradeComparison(
            id,
            checks.nameOf(component, id),
            true,
          );
          upgradeChecks.add(comparison);
          await checks.before(
            checks.resource((target: target, resource: id)),
            comparison,
          );
        }
      }
      await checks.sameNetwork();
      upgradeCheckPhase = 'upgrading';
      _notify();
      await applyComponentUpgrade(plan, {
        ...candidate,
        'deviceCheck': {
          'leases': checks.leases,
          'baseline': checks.results('before'),
          'network': checks.tag,
          'keyHash': sha256.convert(utf8.encode(key)).toString(),
          'panelId': ?panelId,
        },
      });
      jobId = selected?.id;
      if (responseCode != 'ok' || jobId == null) {
        throw FormatException(responseCode ?? 'upgrade_failed');
      }
      awaiting = await _awaitChecks(jobId, token);
      if (!awaiting) {
        throw FormatException(_failureCode(selected) ?? 'upgrade_failed');
      }
      upgradeCheckPhase = 'comparison';
      _notify();
      final after = await checks.after();
      final remote = transport();
      if (remote == null) throw const FormatException('server_unavailable');
      final response = await remote.request(
        RunnerRequest.componentUpgradeCommit(
          jobId,
          key: key,
          network: checks.tag,
          checks: after,
        ),
        token,
        sudoPassword: password(),
      );
      if (response.code != 'ok') throw FormatException(response.code);
      upgradeCheckPhase = 'committed';
      upgradeCheckCode = 'committed';
      _softwareRefreshPending = true;
      await selectJob(jobId);
      refreshSoftware?.call();
    } catch (error) {
      upgradeCheckCode = token.isCancelled
          ? 'cancelled'
          : error is FormatException
          ? error.message
          : 'upgrade_failed';
      upgradeCheckPhase = jobId == null ? 'failed' : 'rolling_back';
      _notify();
      if (jobId != null) {
        await _rollBackChecked(jobId, key, awaiting);
        if (upgradeCheckPhase == 'rolled_back' && checks != null) {
          final again = CancellationToken();
          final limit = Timer(const Duration(minutes: 3), again.cancel);
          try {
            await checks.restore(again);
          } catch (_) {
          } finally {
            limit.cancel();
          }
        }
      }
    } finally {
      await checks?.close();
      deadline.cancel();
      if (identical(_upgradeCheckToken, token)) _upgradeCheckToken = null;
      _notify();
    }
  }

  /// Reads the job until its window waits for the checks (true) or it ends
  /// without one (false).
  Future<bool> _awaitChecks(String id, CancellationToken token) async {
    while (true) {
      token.check();
      final job = selected?.id == id ? selected : null;
      if (job != null) {
        if (job.events.any((e) => e.code == 'upgrade_awaiting_checks')) {
          return job.status == 'succeeded';
        }
        if (job.terminal) return false;
      }
      await token.bind(Future<void>.delayed(const Duration(seconds: 1)));
      await selectJob(id);
    }
  }

  static String? _failureCode(RunnerJob? job) {
    if (job == null) return null;
    for (final event in job.events.reversed) {
      if (event.code.startsWith('upgrade_') &&
          upgradeFailureCodes.contains(event.code)) {
        return event.code;
      }
    }
    return null;
  }

  /// Codes of a checked upgrade that ended it: shown as the reason.
  static const upgradeFailureCodes = {
    'upgrade_checks_required',
    'upgrade_checks_coverage',
    'upgrade_checks_changed',
    'upgrade_checks_timeout',
    'upgrade_checks_failed',
    'upgrade_checks_panel_api',
    'upgrade_connectivity_failed',
    'upgrade_healthcheck_failed',
    'upgrade_syntax_failed',
    'upgrade_checksum_failed',
    'upgrade_download_failed',
    'upgrade_download_missing',
    'upgrade_conflict',
    'upgrade_failed',
  };

  /// After a failed or stopped comparison: the server rolls back (a running
  /// job is cancelled, an open window ends now) and the job is read until
  /// it shows the outcome.
  Future<void> _rollBackChecked(String id, String key, bool awaiting) async {
    final recovery = CancellationToken();
    final limit = Timer(const Duration(seconds: 120), recovery.cancel);
    try {
      final remote = transport();
      if (remote == null) throw const FormatException('server_unavailable');
      if (awaiting || selected?.terminal == true) {
        await remote.request(
          RunnerRequest.componentUpgradeAbort(id, key),
          recovery,
          sudoPassword: password(),
        );
      } else {
        await cancelJob();
      }
      while (!recovery.isCancelled) {
        await selectJob(id);
        final job = selected?.id == id ? selected : null;
        if (job != null && job.terminal && job.status != 'succeeded') {
          upgradeCheckPhase = job.status == 'needs_attention'
              ? 'failed'
              : 'rolled_back';
          break;
        }
        await recovery.bind(Future<void>.delayed(const Duration(seconds: 2)));
      }
    } catch (_) {
      // The window's own timer still rolls back without the device.
    } finally {
      limit.cancel();
      _softwareRefreshPending = true;
      refreshSoftware?.call();
      _notify();
    }
  }

  Future<void> applyComponentUpgrade(
    Map<String, dynamic> plan,
    Map<String, Object?> candidate,
  ) => _run((remote, token) async {
    if (installation?.upgradable == true ||
        !installed ||
        (bundledRelease != null && installation?.release != bundledRelease)) {
      installation = await remote.install(
        installation ?? await remote.inspect(token),
        token,
        sudoPassword: password(),
      );
      token.check();
    }
    activeComponent =
        (plan['component'] as String?) ?? (candidate['component'] as String?);
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    componentTarget = candidate['version'] as String?;
    pending = RunnerRequest.componentUpgradeApply(
      id,
      candidate: candidate,
      fingerprint: plan['fingerprint'] as String,
    );
    selected = null;
    cursor = 0;
    await _save();
    token.check();
    componentUpgradePlan = null;
    await _submit(remote, token);
  });

  void prepareResume() {
    // A failed component upgrade has already been rolled back; the runner
    // refuses to resume it, a new choice of version starts it again.
    if (busy ||
        !const {
          'panel_install',
          'panel_update',
          'component_install',
          'protocol_remove',
          'inbound_update',
          'inbound_remove',
          'awg_external_edit',
          'tt_external_edit',
          'tt_certificate',
        }.contains(selected?.kind) ||
        !const {'failed', 'partially_applied'}.contains(selected?.status)) {
      return;
    }
    resumePlan = selected!.id;
    _notify();
  }

  void dismissResume() {
    if (busy) return;
    resumePlan = null;
    _notify();
  }

  Future<void> applyResume() {
    final id = resumePlan;
    if (id == null) return Future.value();
    return _run((remote, token) async {
      await _readJob(remote, token, id);
      if (selected?.id != id ||
          !const {'failed', 'partially_applied'}.contains(selected?.status)) {
        throw const RunnerFailure(RunnerIssue.conflict);
      }
      if (_deviceId != null) {
        operation = operation?.operationId == id
            ? operation!.withExecutor(_deviceId!)
            : ServerOperation(operationId: id, executorDeviceId: _deviceId!);
      }
      await _save();
      await _checkCurrentOperation();
      final response = await remote.request(
        RunnerRequest.resume(id),
        token,
        sudoPassword: password(),
      );
      responseCode = response.code;
      token.check();
      resumePlan = null;
      await _readJob(remote, token, id);
    });
  }

  Future<void> _verifyPanel(
    RunnerTransport remote,
    CancellationToken token,
    String id,
  ) async {
    final result = await remote.request(
      RunnerRequest.panelVerify(id),
      token,
      sudoPassword: password(),
    );
    token.check();
    responseCode = result.code;
    if (result.code == 'panel_auth_failed') {
      panelLoginRequired = true;
      panelVerifiedAt = null;
      return;
    }
    if (!result.panelVerified || result.panelAccess?.id != id) {
      if (panelAccess == null) {
        panelLoginRequired = true;
      }
      panelVerifiedAt = null;
      return;
    }
    panelAccess = result.panelAccess;
    panelLoginRequired = false;
    panelVerifiedAt = DateTime.now();
    await _readEgress(remote, token);
    await _readRelay(remote, token);
    await _save();
  }

  Future<void> applyInstall() {
    final plan = installPlan;
    if (plan == null) return Future.value();
    return _run((remote, token) async {
      // The installer independently compares this fingerprint under a lock.
      installation = await remote.install(
        plan,
        token,
        sudoPassword: password(),
      );
      token.check();
      installPlan = null;
      final result = await remote.request(
        RunnerRequest.list(),
        token,
        sudoPassword: password(),
      );
      token.check();
      jobs = result.jobs;
      alive = result.alive;
      responseCode = result.code;
    });
  }

  Future<void> startDiagnostic() {
    if (!canStart) return Future.value();
    return _run((remote, token) async {
      final random = Random.secure();
      pending = RunnerRequest.diagnostic(
        List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
      );
      selected = null;
      cursor = 0;
      await _save();
      token.check();
      await _submit(remote, token);
    });
  }

  Future<void> retryPending() {
    if (pending == null) return Future.value();
    return _run((remote, token) async {
      final request = pending!;
      // Establish fate before taking over; a lost response is not a missing job.
      await _readJob(remote, token, request.id!);
      if (pending != null && responseCode == 'missing') {
        await _claimOperation(request);
        await _submit(remote, token);
      }
    });
  }

  /// A submission is resent while a connection check holds the server.
  bool waitingForProbe = false;

  /// How long a job waits for running connection checks (probe_busy).
  @visibleForTesting
  static Duration probeBusyWait = const Duration(seconds: 90);
  @visibleForTesting
  static Duration probeBusyRetry = const Duration(seconds: 3);

  Future<void> _submit(RunnerTransport remote, CancellationToken token) async {
    final request = pending!;
    if (observesOperation) throw const SyncMergeFailure(SyncMergeIssue.changed);
    await _checkCurrentOperation();
    var response = await remote.request(
      request,
      token,
      sudoPassword: password(),
    );
    token.check();
    // A connection check holds a short server lease and the runner refuses
    // jobs meanwhile (probe_busy, a definitive refusal: nothing was queued).
    // One check ends within about 80 s, so the same request is sent again.
    if (response.code == 'probe_busy') {
      waitingForProbe = true;
      _notify();
    }
    try {
      for (
        final waitUntil = DateTime.now().add(probeBusyWait);
        response.code == 'probe_busy' && DateTime.now().isBefore(waitUntil);
      ) {
        await token.bind(Future<void>.delayed(probeBusyRetry));
        response = await remote.request(
          request,
          token,
          sudoPassword: password(),
        );
        token.check();
      }
    } finally {
      if (waitingForProbe) {
        waitingForProbe = false;
        _notify();
      }
    }
    responseCode = response.code;
    alive = response.alive;
    if (response.code == 'ok') {
      final matching =
          response.jobs.where((j) => j.id == request.id).firstOrNull ??
          response.jobs.firstOrNull;
      if (matching != null) {
        selected = matching;
        cursor = selected!.sequence;
        jobs = [selected!, ...jobs.where((j) => j.id != selected!.id)];
      }
      pending = null;
    } else if (const {
      'xray_check_busy',
      'probe_busy',
      'busy',
      'capacity',
      'conflict',
      'invalid',
      'incompatible',
      'upgrade_checks_required',
      'upgrade_checks_coverage',
      'upgrade_checks_changed',
      'upgrade_checks_timeout',
      'upgrade_checks_panel_api',
    }.contains(response.code)) {
      // A definitive refusal admits no effect. An uncertain response keeps ID.
      pending = null;
    }
    await _save();
  }

  Future<void> selectJob(String id) => _run((remote, token) async {
    if (pending != null) return;
    await _readJob(remote, token, id);
  });
  Future<void> _readJob(
    RunnerTransport remote,
    CancellationToken token,
    String id,
  ) async {
    final requestedCursor = selected?.id == id ? cursor : 0;
    final wasTerminal = selected?.id == id && selected?.terminal == true;
    final response = await remote.request(
      RunnerRequest.status(id, requestedCursor),
      token,
      sudoPassword: password(),
    );
    token.check();
    responseCode = response.code;
    alive = response.alive;
    if (response.code != 'ok') {
      if (response.code == 'missing') {
        if (selected?.id == id) selected = null;
        jobs = jobs.where((j) => j.id != id).toList();
      }
      return;
    }
    final job = response.jobs.firstOrNull;
    if (job == null || job.id != id) {
      return;
    }
    if (job.sequence < requestedCursor) {
      cursor = 0;
    }
    eventsTruncated =
        job.events.isNotEmpty &&
        job.events.first.sequence > requestedCursor + 1;
    if (job.status == 'succeeded' &&
        const {
          'panel_install',
          'panel_update',
          'component_install',
          'component_upgrade_apply',
          'protocol_remove',
          'apt_upgrade',
          'inbound_update',
          'inbound_remove',
          'awg_external_edit',
          'tt_external_edit',
          'tt_certificate',
          'ssh_harden',
        }.contains(job.kind) &&
        (selected?.id != job.id || selected?.status != 'succeeded')) {
      _softwareRefreshPending = true;
    }
    selected = job.mergeEvents(selected);
    cursor = job.sequence;
    if (pending?.id == id) pending = null;
    jobs = [selected!, ...jobs.where((j) => j.id != id)];
    await _save();
    if (_systemUpdate && job.kind == 'apt_update' && job.terminal) {
      _systemUpdate = false;
      if (job.status == 'succeeded') {
        final plan = await remote.request(
          RunnerRequest.aptPlan(),
          token,
          sudoPassword: password(),
        );
        token.check();
        responseCode = plan.code;
        if (plan.code == 'ok' && plan.aptPlan != null) {
          aptPlan = plan.aptPlan;
          _dismiss(job);
          _applySystemUpgrade =
              _systemUpgrade &&
              !observesOperation &&
              (aptPlan?['packages'] as List? ?? []).isNotEmpty;
        }
      }
    }
    if (job.kind == 'egress_apply' && job.terminal) {
      await _readEgress(remote, token);
      await _save();
    }
    if (job.kind == 'relay_apply' && job.terminal) {
      await _readRelay(remote, token);
      await _save();
    }
    if (job.kind == 'protocol_remove' && job.status == 'succeeded') {
      await _discoverPanel(remote, token);
    }
    bool hasEvent(String code) => selected!.events.any((e) => e.code == code);
    final awaitingConfirmation =
        job.kind == 'component_upgrade_apply' &&
        job.status == 'succeeded' &&
        hasEvent('upgrade_awaiting_confirmation') &&
        !hasEvent('upgrade_confirmed') &&
        !hasEvent('upgrade_rolled_back') &&
        !hasEvent('upgrade_rollback_failed');
    // A checked upgrade waits for this device's connection checks instead
    // (_checkedComponentUpgrade); it is watched, never confirmed here.
    final awaitingChecks =
        job.kind == 'component_upgrade_apply' &&
        job.status == 'succeeded' &&
        hasEvent('upgrade_awaiting_checks') &&
        !hasEvent('upgrade_confirmed') &&
        !hasEvent('upgrade_rolled_back') &&
        !hasEvent('upgrade_rollback_failed');
    // The server rolls an unconfirmed upgrade back after the job succeeded:
    // the versions read before are stale then.
    var rolledBackLate = false;
    if (awaitingConfirmation || awaitingChecks) {
      if (_upgradeWatchId != id) {
        _upgradeWatchId = id;
        _upgradeWatchUntil = DateTime.now().add(upgradeWatchLimit);
      }
    } else if (_upgradeWatchId == id) {
      _upgradeWatchId = null;
      _upgradeWatchUntil = null;
      if (job.status != 'succeeded') {
        rolledBackLate = true;
        _softwareRefreshPending = true;
      }
    }
    if ((rolledBackLate ||
            (job.kind == 'panel_update' ||
                    job.kind == 'component_upgrade_apply') &&
                !wasTerminal &&
                job.terminal) &&
        panelAccess != null) {
      // Panel and Xray upgrades change the versions the panel is verified
      // against; re-verify so VLESS changes are not deferred on stale records.
      await _verifyPanel(remote, token, panelAccess!.id);
    }
    if (awaitingConfirmation && _upgradeConfirmedId != id) {
      // The server verified real connections; this device confirms that it
      // still controls the server. Without this the server rolls back itself.
      // A failed or refused-for-now confirmation (lock busy) is sent again
      // with the next poll while the job is watched.
      final confirm = await remote.request(
        RunnerRequest.componentUpgradeConfirm(job.id),
        token,
        sudoPassword: password(),
      );
      token.check();
      // Confirmed or already rolled back: the outcome shows up in the job
      // itself. It is confirmed once and re-read once, so this cannot loop.
      if (confirm.code == 'ok' || confirm.code == 'upgrade_rolled_back') {
        responseCode = confirm.code;
        _upgradeConfirmedId = id;
        await _readJob(remote, token, job.id);
      }
    }
    if (job.kind == 'panel_install' &&
        job.status == 'succeeded' &&
        panelAccess?.id != id) {
      await _verifyPanel(remote, token, id);
    }
  }

  Future<void> cancelJob() {
    final job = selected;
    if (job == null || job.terminal) return Future.value();
    return _run((remote, token) async {
      if (!connected && connectForAction != null) {
        if (await connectForAction!() != true) return;
      }
      final response = await remote.request(
        RunnerRequest.cancel(job.id),
        token,
        sudoPassword: password(),
      );
      token.check();
      responseCode = response.code;
      final currentJob = response.jobs.firstOrNull;
      if (currentJob?.status == 'planned') {
        try {
          await remote.emergencyReset(token, sudoPassword: password());
        } catch (_) {}
      }
      await _readJob(remote, token, job.id);
      if (installation?.upgradable == true || !installed) {
        try {
          installation = await remote.install(
            installation ?? await remote.inspect(token),
            token,
            sudoPassword: password(),
          );
        } catch (_) {}
      }
    });
  }

  Future<void> resetJobQueue() async {
    _token?.cancel();
    _token = null;
    busy = false;
    backgroundBusy = false;
    actionPending = false;
    pending = null;
    resumePlan = null;
    choosingAptUpdate = false;
    choosingPanel = false;
    error = null;
    responseCode = null;
    connectionLost = false;
    selected = null;
    cursor = 0;
    _notify();

    await _run((remote, token) async {
      if (!connected && connectForAction != null) {
        if (await connectForAction!() != true) return;
      }
      final targetIds = <String>{
        if (selected != null && !selected!.terminal) selected!.id,
        for (final j in jobs)
          if (!j.terminal) j.id,
      };
      for (final id in targetIds) {
        try {
          await remote.request(
            RunnerRequest.cancel(id),
            token,
            sudoPassword: password(),
          );
        } catch (_) {}
      }
      try {
        await remote.emergencyReset(token, sudoPassword: password());
      } catch (_) {}
      try {
        final insp = await remote.inspect(token);
        token.check();
        installation = insp;
        if (insp.release != remote.bundledRelease ||
            insp.upgradable ||
            !insp.active ||
            !installed) {
          installation = await remote.install(
            insp,
            token,
            sudoPassword: password(),
          );
        }
      } catch (_) {}
      try {
        final list = await remote.request(
          RunnerRequest.list(),
          token,
          sudoPassword: password(),
        );
        token.check();
        responseCode = list.code;
        alive = list.alive;
        jobs = list.jobs;
        selected = null;
        cursor = 0;
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _token?.cancel();
    xrayRevision.dispose();
    super.dispose();
  }
}
