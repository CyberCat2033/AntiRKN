import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

/// One controller per server. Polling only observes; submit/cancel/install are
/// explicit actions. The persisted request is written before any submission.
class RunnerController extends ChangeNotifier {
  RunnerController({
    required this.serverId,
    required this.transport,
    required this.identity,
    required this.password,
    required this.accessFailure,
    this.store,
  }) {
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!busy &&
          transport() != null &&
          error == null &&
          (installation == null ||
              selected?.terminal == false ||
              pending != null)) {
        unawaited(refresh());
      }
    });
  }
  final String serverId;
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
  bool busy = false;
  bool alive = false;
  bool connectionLost = false;
  RunnerIssue? error;
  String? responseCode;
  RunnerInstallation? installation;
  RunnerInstallation? installPlan;
  List<RunnerJob> jobs = [];
  RunnerJob? selected;
  RunnerRequest? pending;
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
      (installation?.release == null ||
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

  void connectionReady() {
    if (_disposed || busy || transport() == null) return;
    if (error == RunnerIssue.unavailable) error = null;
    unawaited(refresh());
  }

  void disconnected() {
    if (busy && installPlan != null) error = RunnerIssue.installFailed;
    _token?.cancel();
    _token = null;
    busy = false;
    installPlan = null;
    connectionLost = selected?.terminal == false || pending != null;
    _notify();
  }

  Future<void> _load() async {
    final current = identity();
    if (current == null) throw const RunnerFailure(RunnerIssue.unavailable);
    if (_loaded && current == _identity) return;
    final raw = await store?.readRunnerJournal(serverId);
    selected = null;
    jobs = [];
    pending = null;
    cursor = 0;
    installation = null;
    _identity = current;
    if (raw != null) {
      final json = decodeRunnerObject(raw);
      if (json['version'] != 1) throw const RunnerFailure(RunnerIssue.storage);
      if (json['identity'] == current) {
        if (json['selected'] case final Map job) {
          selected = RunnerJob.fromJson(Map<String, dynamic>.from(job));
        }
        if (json['pending'] case final Map request) {
          pending = RunnerRequest.fromJson(Map<String, Object?>.from(request));
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
    await store!.writeRunnerJournal(
      serverId,
      jsonEncode({
        'version': 1,
        'identity': _identity,
        'pending': pending?.json,
        'selected': selected?.toJson(),
        'cursor': cursor,
      }),
    );
  }

  Future<void> _run(
    Future<void> Function(RunnerTransport, CancellationToken) action,
  ) async {
    final remote = transport();
    if (busy || remote == null || _disposed) return;
    busy = true;
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
    } on VaultFailure {
      if (!token.isCancelled && !_disposed) error = RunnerIssue.storage;
    } catch (_) {
      if (!token.isCancelled && !_disposed) error = RunnerIssue.invalidResponse;
    } finally {
      if (_token == token) {
        busy = false;
        _token = null;
      }
      _notify();
    }
  }

  Future<void> refresh() => _run((remote, token) async {
    installation = await remote.inspect(token);
    token.check();
    if (installation!.state == 'conflict') {
      throw const RunnerFailure(RunnerIssue.conflict);
    }
    if (installation!.release != null &&
        installation!.release != remote.bundledRelease) {
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
    final id = pending?.id ?? selected?.id ?? jobs.firstOrNull?.id;
    if (id != null) await _readJob(remote, token, id);
  });

  Future<void> prepareInstall() => _run((remote, token) async {
    final next = await remote.inspect(token);
    token.check();
    installation = next;
    if (!next.supported) throw const RunnerFailure(RunnerIssue.prerequisites);
    if (next.state == 'conflict') {
      throw const RunnerFailure(RunnerIssue.conflict);
    }
    if (next.release != null && next.release != remote.bundledRelease) {
      throw const RunnerFailure(RunnerIssue.incompatible);
    }
    installPlan = next;
  });
  void dismissPlan() {
    if (busy) return;
    installPlan = null;
    _notify();
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
      // Persist again before retry, including after a previous disk failure.
      await _save();
      token.check();
      await _readJob(remote, token, pending!.id!);
      if (pending != null && responseCode == 'missing') {
        await _submit(remote, token);
      }
    });
  }

  Future<void> _submit(RunnerTransport remote, CancellationToken token) async {
    final request = pending!;
    final response = await remote.request(
      request,
      token,
      sudoPassword: password(),
    );
    token.check();
    responseCode = response.code;
    alive = response.alive;
    if (response.code == 'ok' && response.jobs.single.id == request.id) {
      selected = response.jobs.single;
      cursor = selected!.sequence;
      pending = null;
      jobs = [selected!, ...jobs.where((j) => j.id != selected!.id)];
    } else if (const {
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
    final response = await remote.request(
      RunnerRequest.status(id, requestedCursor),
      token,
      sudoPassword: password(),
    );
    token.check();
    responseCode = response.code;
    alive = response.alive;
    if (response.code != 'ok') return;
    final job = response.jobs.single;
    if (job.id != id || job.sequence < requestedCursor) {
      throw const RunnerFailure(RunnerIssue.invalidResponse);
    }
    eventsTruncated =
        job.events.isNotEmpty &&
        job.events.first.sequence > requestedCursor + 1;
    selected = job.mergeEvents(selected);
    cursor = job.sequence;
    if (pending?.id == id) pending = null;
    jobs = [selected!, ...jobs.where((j) => j.id != id)];
    await _save();
  }

  Future<void> cancelJob() {
    final job = selected;
    if (job == null || job.terminal) return Future.value();
    return _run((remote, token) async {
      final response = await remote.request(
        RunnerRequest.cancel(job.id),
        token,
        sudoPassword: password(),
      );
      token.check();
      responseCode = response.code;
      await _readJob(remote, token, job.id);
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
