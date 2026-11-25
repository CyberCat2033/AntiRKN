import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

/// One controller per server. Connection setup prepares the runner; polling
/// observes jobs. Persist each job request before submitting it.
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
          error == null &&
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

  Map<String, dynamic>? egress;
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
  bool _applySystemUpgrade = false;
  String? dismissedJobId;
  List<RunnerJob> jobs = [];
  RunnerJob? selected;
  RunnerRequest? pending;
  bool get hasUnfinishedJob =>
      pending != null ||
      selected?.terminal == false ||
      jobs.any((job) => !job.terminal);
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
    _deviceId = store is ChangeJournalStore
        ? (await (store as ChangeJournalStore).readWorkspaceIdentity()).deviceId
        : null;
    final raw = await store?.readRunnerJournal(serverId);
    _journalSource = raw;
    operation = null;
    selected = null;
    jobs = [];
    pending = null;
    cursor = 0;
    installation = null;
    panelAccess = null;
    panelDiscovery = null;
    egress = null;
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
      'egress': egress,
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

  Future<void> _run(
    Future<void> Function(RunnerTransport, CancellationToken) action, {
    bool background = false,
  }) async {
    final remote = transport();
    if (busy || backgroundBusy || remote == null || _disposed) return;
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
      await action(remote, token);
      token.check();
      connectionLost = false;
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

  Future<void> refresh({bool prepare = false}) => _run((remote, token) async {
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
        selected?.id ??
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
        jobs.where((job) => !job.terminal).firstOrNull?.id;
    if (id != null) await _readJob(remote, token, id);
  }, background: true);

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

  Future<void> checkEgress() => requestAction(() async {
    if (panelAccess == null) return;
    await _run((remote, token) async {
      final result = await remote.request(
        RunnerRequest.fromJson({
          'version': 1,
          'action': 'egress_check',
          'id': panelAccess!.id,
        }),
        token,
        sudoPassword: password(),
      );
      token.check();
      responseCode = result.code;
      if (result.code == 'ok' && result.egress != null) {
        egress = result.egress;
        await _save();
      }
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
    String action,
  ) async {
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
    if (plan.code != 'ok' || plan.egress?['fingerprint'] is! String) {
      return false;
    }
    pending = RunnerRequest.fromJson({
      'version': 1,
      'action': 'submit',
      'id': newVpnId(),
      'kind': kind,
      'count': 3,
      'interval': 1,
      'payload': jsonEncode(payload),
      'fingerprint': plan.egress!['fingerprint'],
    });
    selected = null;
    cursor = 0;
    await _save();
    token.check();
    await _submit(remote, token);
    return responseCode == 'ok';
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

  Future<bool> clearManagedClients() async {
    var success = false;
    await requestAction(() async {
      await _run((remote, token) async {
        final response = await remote.request(
          RunnerRequest.clearManagedClients(),
          token,
          sudoPassword: password(),
        );
        responseCode = response.code;
        if (response.code != 'ok') {
          throw RunnerFailure(
            response.code == 'clear_managed_clients_failed'
                ? RunnerIssue.conflict
                : RunnerIssue.unavailable,
          );
        }
        success = true;
      });
    });
    return success;
  }

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
  void dismissJob() {
    if (selected?.terminal == true) {
      dismissedJobId = selected!.id;
      if (selected?.kind == 'component_install') {
        activeComponent = null;
      }
      _notify();
    }
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
  /// resulting, fingerprinted package set without a second confirmation.
  Future<void> updateSystem() async {
    if (!canStart) return;
    await prepareApt(upgrade: false);
    if (!choosingAptUpdate || !canStart) return;
    _systemUpdate = true;
    await applyApt();
    if (error != null && pending == null) _systemUpdate = false;
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
  /// the previous version) through the checked upgrade pipeline.
  Future<void> installComponentVersion(Map<String, Object?> candidate) async {
    await checkComponentUpgrade(
      candidate['component'] as String,
      candidate: candidate,
    );
    final plan = componentUpgradePlan;
    if (plan == null || plan['upgradable'] != true) return;
    await applyComponentUpgrade(plan, candidate);
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

  Future<void> _submit(RunnerTransport remote, CancellationToken token) async {
    final request = pending!;
    if (observesOperation) throw const SyncMergeFailure(SyncMergeIssue.changed);
    await _checkCurrentOperation();
    final response = await remote.request(
      request,
      token,
      sudoPassword: password(),
    );
    token.check();
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
          dismissedJobId = job.id;
          _applySystemUpgrade =
              !observesOperation &&
              (aptPlan?['packages'] as List? ?? []).isNotEmpty;
        }
      }
    }
    if (job.kind == 'egress_apply' && job.terminal) {
      await _readEgress(remote, token);
      await _save();
    }
    if (job.kind == 'protocol_remove' && job.status == 'succeeded') {
      await _discoverPanel(remote, token);
    }
    if ((job.kind == 'panel_update' ||
            job.kind == 'component_upgrade_apply' && !wasTerminal) &&
        job.terminal &&
        panelAccess != null) {
      // Panel and Xray upgrades change the versions the panel is verified
      // against; re-verify so VLESS changes are not deferred on stale records.
      await _verifyPanel(remote, token, panelAccess!.id);
    }
    if (job.kind == 'component_upgrade_apply' &&
        job.status == 'succeeded' &&
        selected!.events.any(
          (e) => e.code == 'upgrade_awaiting_confirmation',
        ) &&
        !selected!.events.any((e) => e.code == 'upgrade_confirmed')) {
      // The server verified real connections; this device confirms that it
      // still controls the server. Without this the server rolls back itself.
      final confirm = await remote.request(
        RunnerRequest.componentUpgradeConfirm(job.id),
        token,
        sudoPassword: password(),
      );
      token.check();
      responseCode = confirm.code;
      // A refused confirmation (already rolled back) shows up in the job
      // itself; re-reading it once is enough and cannot loop.
      if (confirm.code == 'ok' || confirm.code == 'upgrade_rolled_back') {
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
    super.dispose();
  }
}
