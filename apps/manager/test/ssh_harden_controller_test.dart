import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:antirkn_manager/ssh/ssh_harden_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'network_support.dart';
import 'ssh_support.dart';

const jobId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
SshProfile original() => SshProfile(
  host: 'fixture.example',
  port: 22,
  username: 'root',
  authMethod: SshAuthMethod.password,
  hostKey: const TrustedHostKey('ssh-ed25519', 'SHA256:fixture'),
  secrets: {ServerSecret.sshPassword: 'old-fixture-password'},
);

class HardenSession extends SshController {
  HardenSession()
    : super(
        openVault: () async => FakeVault(),
        connector: FakeConnector(),
        picker: FakeKeyPicker(),
        network: NetworkController(
          reader: TestInventoryReader(() async => testInventory()),
        ),
      );
  SshProfile current = original().withHardenRecovery(
    jobId: jobId,
    user: 'fixture',
    port: 2222,
    password: 'new-fixture-password',
  );
  @override
  SshProfile? get profile => current;
  String remotePhase = 'testing';
  bool failSave = false,
      failFinalTest = false,
      failAbort = false,
      loseCommitReply = false,
      loseStatus = false,
      failOldLogin = false,
      pendingAbort = false;
  PrivilegeStatus privilege = PrivilegeStatus.sudoWithPassword;
  Completer<void>? connectGate;
  final calls = <String>[];
  final connections = <FakeConnection>[];
  final opened = <SshProfile>[];
  @override
  Future<void> persistHardenProfile(SshProfile updated) async {
    calls.add('save:${updated.username}');
    if (failSave && updated.username != 'root') {
      throw const VaultFailure(VaultIssue.writeFailed);
    }
    current = updated;
  }

  @override
  Future<SshConnection> openHardenConnection(
    SshProfile target,
    CancellationToken token,
  ) async {
    opened.add(target);
    calls.add('connect:${target.username}:$remotePhase');
    if (failFinalTest &&
            remotePhase == 'finalizing' &&
            target.username != 'root' ||
        failOldLogin && target.username == 'root') {
      throw const SshFailure(SshIssue.network);
    }
    final connection = FakeConnection()
      ..privilegeChecker = (_, _) async => PrivilegeCheck(privilege);
    connections.add(connection);
    await connectGate?.future;
    return connection;
  }

  @override
  Future<RunnerResponse> hardenRequest(
    RunnerRequest request,
    CancellationToken token, {
    SshConnection? connection,
    String? password,
  }) async {
    final action = request.json['action'] as String;
    calls.add(action);
    if (action == 'ssh_harden_status' && loseStatus) {
      throw const RunnerFailure(RunnerIssue.unavailable);
    }
    var code = 'ok';
    if (action == 'ssh_harden_confirm') remotePhase = 'finalizing';
    if (action == 'ssh_harden_abort') {
      if (failAbort || remotePhase == 'committed') {
        code = 'ssh_harden_failed';
      } else {
        remotePhase = pendingAbort ? 'rolling_back' : 'rolled_back';
      }
    }
    if (action == 'ssh_harden_commit') {
      expect(connection, isNotNull);
      expect(current.username, 'fixture');
      expect(current.secrets[ServerSecret.sshPassword], 'new-fixture-password');
      expect(current.hardenRecovery, isNotNull);
      remotePhase = 'committed';
      if (loseCommitReply) throw const RunnerFailure(RunnerIssue.unavailable);
    }
    return RunnerResponse.fromJson({
      'version': 1,
      'code': code,
      'alive': true,
      'jobs': <Object?>[],
      if (code == 'ok')
        'sshHardenResult': {
          'phase': remotePhase,
          'confirmed': remotePhase == 'committed',
          'aborted': remotePhase == 'rolled_back',
          'finalized': remotePhase == 'finalizing',
          'deadline':
              DateTime.now()
                  .add(const Duration(minutes: 4))
                  .millisecondsSinceEpoch /
              1000,
        },
    });
  }
}

void main() {
  late HardenSession session;
  late SshHardenController flow;
  setUp(() {
    session = HardenSession();
    flow = SshHardenController(session, pollAutomatically: false);
  });
  tearDown(() {
    flow.dispose();
    session.dispose();
    session.network.dispose();
  });
  test('two new-password sessions and durable save precede commit', () async {
    await flow.retry();
    expect(flow.stage, SshHardenStage.tested);
    expect(
      session.opened.single.secrets[ServerSecret.sshPassword],
      'new-fixture-password',
    );
    await flow.confirm();
    expect(flow.stage, SshHardenStage.done);
    expect(session.opened.length, 2);
    expect(session.connections.every((c) => c.closed), isTrue);
    expect(
      session.calls.indexOf('save:fixture'),
      lessThan(session.calls.indexOf('ssh_harden_commit')),
    );
    expect(session.current.hardenRecovery, isNull);
  });
  test(
    'failed final connection aborts and restores original credentials',
    () async {
      await flow.retry();
      session.failFinalTest = true;
      await flow.confirm();
      expect(session.remotePhase, 'rolled_back');
      expect(session.calls, isNot(contains('ssh_harden_commit')));
      expect(session.current.username, 'root');
      expect(
        session.current.secrets[ServerSecret.sshPassword],
        'old-fixture-password',
      );
      expect(flow.stage, isNot(SshHardenStage.done));
    },
  );
  test('vault failure prevents commit', () async {
    await flow.retry();
    session.failSave = true;
    await flow.confirm();
    expect(session.calls, isNot(contains('ssh_harden_commit')));
    expect(session.remotePhase, 'rolled_back');
    expect(session.current.username, 'root');
    expect(flow.errorCode, 'storage');
  });
  test('lost commit reply is resolved by status without abort', () async {
    await flow.retry();
    session.loseCommitReply = true;
    await flow.confirm();
    expect(flow.stage, SshHardenStage.done);
    expect(session.calls, isNot(contains('ssh_harden_abort')));
  });
  test('lost commit and status retain both recovery routes', () async {
    await flow.retry();
    session.loseCommitReply = true;
    session.loseStatus = true;
    await flow.confirm();
    expect(flow.stage, SshHardenStage.testFailed);
    expect(session.remotePhase, 'committed');
    expect(session.current.hardenRecovery, isNotNull);
    expect(session.current.recoveredAccess(hardened: false).username, 'root');
    expect(session.calls, isNot(contains('ssh_harden_abort')));
    session.loseStatus = false;
    await flow.poll();
    expect(flow.stage, SshHardenStage.done);
  });
  test(
    'asynchronous cleanup waits for server rollback and a working old route',
    () async {
      session.pendingAbort = true;
      await flow.abort();
      expect(flow.stage, SshHardenStage.aborting);
      expect(session.current.hardenRecovery, isNotNull);
      session.remotePhase = 'rolled_back';
      await flow.poll();
      expect(flow.stage, SshHardenStage.aborted);
      expect(session.current.hardenRecovery, isNull);
      expect(session.opened.last.username, 'root');
    },
  );
  test('failed abort is never announced as rollback', () async {
    session.failAbort = true;
    await flow.abort();
    expect(flow.stage, SshHardenStage.testFailed);
    expect(session.current.hardenRecovery, isNotNull);
  });
  test('rollback result requires a working old SSH route', () async {
    session.failOldLogin = true;
    await flow.abort();
    expect(flow.stage, SshHardenStage.testFailed);
    expect(session.current.hardenRecovery, isNotNull);
  });
  test('NOPASSWD and UID zero cannot pass new-account verification', () async {
    for (final status in [
      PrivilegeStatus.root,
      PrivilegeStatus.sudoWithoutPassword,
    ]) {
      session.privilege = status;
      await flow.retry();
      expect(flow.stage, SshHardenStage.testFailed);
      expect(flow.errorCode, 'ssh_harden_sudo_required');
    }
    expect(session.connections.every((c) => c.closed), isTrue);
  });
  test('committed recovery restores saved new access', () async {
    session.remotePhase = 'committed';
    await flow.poll();
    expect(flow.stage, SshHardenStage.done);
    expect(session.current.username, 'fixture');
    expect(session.current.hardenRecovery, isNull);
  });
  test(
    'server timeout restores old credentials after a new-profile save',
    () async {
      session.current = session.current.recoveredAccess(hardened: true);
      session.remotePhase = 'rolled_back';
      await flow.poll();
      expect(flow.stage, SshHardenStage.aborted);
      expect(session.current.username, 'root');
      expect(
        session.current.secrets[ServerSecret.sshPassword],
        'old-fixture-password',
      );
    },
  );
  test(
    'unsubmitted recovery is cleared only after verifying old login',
    () async {
      session.remotePhase = 'missing';
      await flow.poll();
      expect(flow.stage, SshHardenStage.aborted);
      expect(session.opened.single.username, 'root');
      expect(session.current.hardenRecovery, isNull);
    },
  );
  test('cancellation closes a late verification connection', () async {
    session.connectGate = Completer<void>();
    final pending = flow.retry();
    await Future<void>.delayed(Duration.zero);
    flow.token.cancel();
    session.connectGate!.complete();
    await pending;
    expect(session.connections.single.closed, isTrue);
    expect(session.calls, isNot(contains('ssh_harden_commit')));
  });
}
