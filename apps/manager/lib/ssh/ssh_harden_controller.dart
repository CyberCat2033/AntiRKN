import 'dart:async';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

import 'ssh_controller.dart';

enum SshHardenStage {
  input,
  preparing,
  staging,
  testing,
  tested,
  testFailed,
  confirming,
  aborting,
  done,
  aborted,
}

/// Owns both verification connections; a server result, never a local timer,
/// decides whether a transition was committed or rolled back.
class SshHardenController extends ChangeNotifier {
  SshHardenController(this.session, {bool pollAutomatically = true}) {
    session.runner.pollingPaused = true;
    if (session.profile?.hardenRecovery != null) stage = SshHardenStage.staging;
    if (pollAutomatically) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_disposed) notifyListeners();
        if (!busy && _background == null && jobId != null && !terminal) {
          unawaited(poll());
        }
      });
    }
  }
  final SshController session;
  final token = CancellationToken();
  Timer? _timer;
  bool _disposed = false;

  /// An action the person started. Background status polls never set it, so
  /// the dialog's buttons and icons do not blink once a second.
  bool busy = false;
  Future<void>? _background;
  SshHardenStage stage = SshHardenStage.input;
  String? errorCode;
  DateTime? deadline;
  String? get jobId => session.profile?.hardenRecovery?['jobId'] as String?;
  bool get terminal =>
      stage == SshHardenStage.done || stage == SshHardenStage.aborted;
  int get remainingSeconds => deadline == null
      ? 300
      : deadline!.difference(DateTime.now()).inSeconds.clamp(0, 600);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _cancelRequested = false;

  /// Preparation only reads the plan and stores the recovery profile, so the
  /// person can leave it. Once a job exists the server decides what happened.
  bool get canCancelPreparation =>
      stage == SshHardenStage.preparing && !_cancelRequested;

  void cancelPreparation() {
    if (!canCancelPreparation) return;
    _cancelRequested = true;
    session.runner.cancelAction();
    _notify();
  }

  void _checkCancelled() {
    if (_cancelRequested) throw const _HardenFailure('ssh_harden_cancelled');
  }

  void _failure(Object error) {
    if (error is _HardenFailure && error.code == 'ssh_harden_cancelled') {
      errorCode = null;
      // A job may have been submitted before the cancel arrived: follow it.
      stage = jobId == null ? SshHardenStage.input : SshHardenStage.staging;
      return;
    }
    errorCode = error is _HardenFailure
        ? error.code
        : error is VaultFailure
        ? 'storage'
        : 'ssh_harden_failed';
    stage = jobId == null ? SshHardenStage.input : SshHardenStage.testFailed;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || _disposed || terminal) return;
    busy = true;
    errorCode = null;
    _notify();
    try {
      // A status poll may already be changing the stage: act on its outcome.
      if (_background case final pending?) {
        await pending;
        if (_disposed || terminal) return;
      }
      await action();
    } catch (e) {
      if (!_disposed) _failure(e);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> start({
    required String username,
    required int port,
    required String password,
    bool disableRootLogin = true,
  }) => _run(() async {
    if (jobId != null) throw const _HardenFailure('ssh_harden_conflict');
    _cancelRequested = false;
    stage = SshHardenStage.preparing;
    _notify();
    final runner = session.runner;
    final ready = await runner.ensureReady();
    _checkCancelled();
    if (!ready) throw const _HardenFailure('ssh_harden_failed');
    final plan = await runner.prepareSshHarden(username: username, port: port);
    _checkCancelled();
    if (plan == null || !plan.supported) {
      throw const _HardenFailure('ssh_harden_failed');
    }
    if (!plan.portAvailable) throw const _HardenFailure('ssh_harden_port_busy');
    if (!plan.userAvailable) throw const _HardenFailure('ssh_harden_conflict');
    await runner.submitSshHarden(
      plan: plan,
      username: username,
      port: port,
      sudoPassword: password,
      disableRootLogin: disableRootLogin,
      beforeSubmit: (id) async {
        _checkCancelled();
        final original = session.profile;
        if (original == null) throw const VaultFailure(VaultIssue.writeFailed);
        await session.persistHardenProfile(
          original.withHardenRecovery(
            jobId: id,
            user: username,
            port: port,
            password: password,
          ),
        );
      },
    );
    token.check();
    if (jobId == null) {
      _checkCancelled();
      throw const _HardenFailure('ssh_harden_failed');
    }
    stage = SshHardenStage.staging;
    await _poll();
  });

  Future<SshHardenResult> _request(RunnerRequest request) async {
    RunnerResponse? response;
    try {
      response = await session.hardenRequest(request, token);
    } on SshFailure {
      /* Reopen a saved, pinned recovery route below. */
    } on RunnerFailure {
      /* The original session may have ended during reload. */
    }
    if (response == null) {
      final profile = session.profile;
      if (profile?.hardenRecovery == null) {
        throw const _HardenFailure('ssh_harden_failed');
      }
      for (final hardened in [false, true]) {
        SshConnection? connection;
        try {
          final candidate = profile!.recoveredAccess(hardened: hardened);
          connection = await session.openHardenConnection(candidate, token);
          response = await session.hardenRequest(
            request,
            token,
            connection: connection,
            password:
                candidate.secrets[ServerSecret.sudoPassword] ??
                candidate.secrets[ServerSecret.sshPassword],
          );
          break;
        } on SshFailure {
          token.check();
        } on RunnerFailure {
          token.check();
        } finally {
          connection?.close();
        }
      }
    }
    token.check();
    if (response?.code != 'ok' || response?.sshHardenResult == null) {
      throw _HardenFailure(response?.code ?? 'ssh_harden_failed');
    }
    return response!.sshHardenResult!;
  }

  /// Reads the server status without marking the dialog busy and without
  /// hiding the last error unless the stage actually moved.
  Future<void> poll() {
    if (busy || _disposed || terminal) return Future.value();
    return _background ??= _quietPoll().whenComplete(() => _background = null);
  }

  Future<void> _quietPoll() async {
    final before = stage;
    try {
      await _poll();
      if (stage != before) errorCode = null;
    } catch (e) {
      if (!_disposed) _failure(e);
    } finally {
      _notify();
    }
  }

  Future<void> _poll() async {
    final id = jobId;
    if (id == null) return;
    final result = await _request(RunnerRequest.sshHardenStatus(id));
    deadline = result.deadline;
    if (result.confirmed) {
      await _complete();
    } else if (result.aborted ||
        const {'failed', 'cancelled', 'missing'}.contains(result.phase)) {
      await _restoreOriginal(id);
    } else if (result.phase == 'rollback_failed') {
      throw const _HardenFailure('ssh_harden_recovery_failed');
    } else if (result.phase == 'rolling_back') {
      stage = SshHardenStage.aborting;
    } else if (result.phase == 'testing' || result.finalized) {
      if (stage == SshHardenStage.staging) await _test();
    }
  }

  Future<void> retry() => _run(() async {
    if (jobId == null) return;
    final result = await _request(RunnerRequest.sshHardenStatus(jobId!));
    deadline = result.deadline;
    if (result.confirmed) {
      await _complete();
      return;
    }
    if (result.aborted) {
      await _restoreOriginal(jobId!);
      return;
    }
    if (result.phase != 'testing' && !result.finalized) {
      throw const _HardenFailure('ssh_harden_failed');
    }
    await _test();
  });

  Future<SshConnection> _verifiedConnection() async {
    final profile = session.profile!.recoveredAccess(hardened: true);
    final connection = await session.openHardenConnection(profile, token);
    try {
      token.check();
      final privileges = await connection.checkPrivileges(
        token,
        sudoPassword: profile.secrets[ServerSecret.sudoPassword],
      );
      if (privileges.status != PrivilegeStatus.sudoWithPassword) {
        throw const _HardenFailure('ssh_harden_sudo_required');
      }
      token.check();
      return connection;
    } catch (_) {
      connection.close();
      rethrow;
    }
  }

  Future<void> _test() async {
    stage = SshHardenStage.testing;
    _notify();
    final connection = await _verifiedConnection();
    connection.close();
    final result = await _request(RunnerRequest.sshHardenStatus(jobId!));
    if (result.phase != 'testing' && !result.finalized) {
      throw const _HardenFailure('ssh_harden_conflict');
    }
    deadline = result.deadline;
    stage = SshHardenStage.tested;
  }

  Future<void> confirm() => _run(() async {
    final id = jobId;
    if (id == null || stage != SshHardenStage.tested) return;
    stage = SshHardenStage.confirming;
    _notify();
    SshConnection? finalConnection;
    var commitSent = false;
    try {
      final result = await _request(RunnerRequest.sshHardenConfirm(id));
      if (result.confirmed) {
        await _complete();
        return;
      }
      if (!result.finalized) throw const _HardenFailure('ssh_harden_failed');
      deadline = result.deadline;
      // This is a fresh connection AFTER root/old-port policy is applied.
      finalConnection = await _verifiedConnection();
      await session.persistHardenProfile(
        session.profile!.recoveredAccess(hardened: true),
      );
      token.check();
      commitSent = true;
      final response = await session.hardenRequest(
        RunnerRequest.sshHardenCommit(id),
        token,
        connection: finalConnection,
        password: session.profile!.secrets[ServerSecret.sudoPassword],
      );
      if (response.code != 'ok' ||
          response.sshHardenResult?.confirmed != true) {
        throw _HardenFailure(response.code);
      }
      await _complete();
    } catch (error) {
      if (!_disposed) {
        if (commitSent) {
          // A lost reply is resolved by status. Never announce success merely
          // because commit was sent, and retain both routes if status is lost.
          final result = await _request(RunnerRequest.sshHardenStatus(id));
          if (result.confirmed) {
            await _complete();
            return;
          }
        }
        finalConnection?.close();
        finalConnection = null;
        final aborted = await _request(RunnerRequest.sshHardenAbort(id));
        if (aborted.aborted) await _restoreOriginal(id);
      }
      rethrow;
    } finally {
      finalConnection?.close();
    }
  });

  Future<void> abort() => _run(() async {
    final id = jobId;
    if (id == null) {
      stage = SshHardenStage.aborted;
      return;
    }
    stage = SshHardenStage.aborting;
    _notify();
    final result = await _request(RunnerRequest.sshHardenAbort(id));
    if (result.phase == 'rolling_back') return;
    if (!result.aborted) {
      throw const _HardenFailure('ssh_harden_recovery_failed');
    }
    await _restoreOriginal(id);
  });

  Future<void> _restoreOriginal(String id) async {
    final original = session.profile!.recoveredAccess(hardened: false);
    // A rollback marker alone is insufficient: the old route must actually work.
    final connection = await session.openHardenConnection(original, token);
    connection.close();
    await session.runner.clearHardenPending(id);
    await session.persistHardenProfile(
      original.recoveredAccess(hardened: false, clear: true),
    );
    stage = SshHardenStage.aborted;
  }

  Future<void> _complete() async {
    // New credentials were saved before commit; cleanup may be retried on restart.
    final current = session.profile!;
    final next = current.recoveredAccess(hardened: true);
    if (!current.hasSameConnectionSettings(next)) {
      await session.persistHardenProfile(next);
    }
    await session.runner.clearHardenPending(jobId!);
    try {
      await session.persistHardenProfile(
        next.recoveredAccess(hardened: true, clear: true),
      );
    } on VaultFailure {
      /* Encrypted recovery record remains; current access is saved. */
    }
    stage = SshHardenStage.done;
  }

  @override
  void dispose() {
    _disposed = true;
    token.cancel();
    _timer?.cancel();
    session.runner.pollingPaused = false;
    super.dispose();
  }
}

class _HardenFailure implements Exception {
  const _HardenFailure(this.code);
  final String code;
}
