// Disposable QEMU fixture only; credentials stay in private fixture files.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';

Future<void> main(List<String> args) async {
  final path = args.single;
  final port = int.parse(await File('$path/port').readAsString());
  final key = await File('$path/client').readAsString();
  final fingerprint = (await File('$path/fingerprint').readAsString()).trim();
  final password =
      (jsonDecode(await File('$path/credentials.json').readAsString())
              as Map)['password']
          as String;
  final results = <String, Object>{};
  void check(bool condition, String name) {
    if (!condition) throw StateError(name);
    results[name] = true;
    stdout.writeln('PASS $name');
  }

  Future<SshConnection> connect({
    String user = 'root',
    bool passwordAuth = false,
  }) => const DartSshConnector(commandTimeout: Duration(seconds: 15)).connect(
    SshProfile(
      id: 'runner-fixture',
      host: '127.0.0.1',
      port: port,
      username: user,
      authMethod: passwordAuth
          ? SshAuthMethod.password
          : SshAuthMethod.privateKey,
      secrets: {
        ServerSecret.privateKey: key,
        ServerSecret.sshPassword: password,
      },
    ),
    verifyHostKey: (host) async => host.fingerprint == fingerprint,
    cancellation: CancellationToken(),
  );
  Future<ProcessResult> admin(String command, {bool success = true}) async {
    final result = await Process.run('ssh', [
      '-i',
      '$path/client',
      '-o',
      'IdentitiesOnly=yes',
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=3',
      '-o',
      'UserKnownHostsFile=$path/known_hosts',
      '-p',
      '$port',
      'root@127.0.0.1',
      command,
    ]);
    if (success && result.exitCode != 0) throw StateError('fixture_admin');
    return result;
  }

  SshConnection connection = await connect();
  Future<RunnerResponse> request(RunnerRequest request) =>
      connection.runner!.request(request, CancellationToken());
  Future<RunnerJob> waitFor(
    String id,
    bool Function(RunnerJob) condition,
  ) async {
    for (var i = 0; i < 80; i++) {
      final job = (await request(RunnerRequest.status(id, 0))).jobs.single;
      if (condition(job)) return job;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('job_deadline');
  }

  try {
    final missing = await connection.runner!.inspect(CancellationToken());
    check(
      missing.supported && missing.state == 'missing',
      'read_only_inspect_missing',
    );
    check(
      (await admin(
            'test ! -e /var/lib/antirkn-runner && test ! -e /usr/local/lib/antirkn-runner',
          )).exitCode ==
          0,
      'no_bootstrap_before_plan',
    );
    final installed = await connection.runner!.install(
      missing,
      CancellationToken(),
    );
    check(
      installed.active &&
          installed.release == connection.runner!.bundledRelease,
      'install_root_verified_worker',
    );
    final pid = (await admin(
      'systemctl show -p MainPID --value antirkn-runner',
    )).stdout;
    final again = await connection.runner!.install(
      installed,
      CancellationToken(),
    );
    check(
      again.active &&
          pid ==
              (await admin(
                'systemctl show -p MainPID --value antirkn-runner',
              )).stdout,
      'repeat_install_preserves_worker',
    );
    try {
      await connection.runner!.install(missing, CancellationToken());
      throw StateError('stale_accepted');
    } on RunnerFailure catch (e) {
      check(e.issue == RunnerIssue.installFailed, 'stale_plan_rejected');
    }
    final user = await connect(user: 'antirkn', passwordAuth: true);
    try {
      check(
        (await user.runner!.inspect(CancellationToken())).state == 'installed',
        'unprivileged_inspection',
      );
      check(
        (await user.checkPrivileges(
              CancellationToken(),
              sudoPassword: password,
            )).status ==
            PrivilegeStatus.sudoWithPassword,
        'ssh_password_sudo',
      );
      check(
        (await user.runner!.request(
          RunnerRequest.list(),
          CancellationToken(),
          sudoPassword: password,
        )).alive,
        'sudo_password_then_rpc_stdin',
      );
      try {
        await user.runner!.request(
          RunnerRequest.list(),
          CancellationToken(),
          sudoPassword: 'incorrect-fixture',
        );
        throw StateError('wrong_accepted');
      } on SshFailure catch (e) {
        check(
          e.issue == SshIssue.sudoAuthenticationFailed,
          'wrong_sudo_no_rpc_payload',
        );
      }
      check(
        (await user.runner!.request(
          RunnerRequest.list(),
          CancellationToken(),
          sudoPassword: password,
        )).alive,
        'sudo_failure_preserves_ssh',
      );
      await admin(
        "printf 'antirkn ALL=(ALL) NOPASSWD: ALL\\n' > /etc/sudoers.d/99-antirkn-runner-fixture; chmod 440 /etc/sudoers.d/99-antirkn-runner-fixture",
      );
      check(
        (await user.runner!.request(
          RunnerRequest.list(),
          CancellationToken(),
          sudoPassword: 'unused-fixture',
        )).alive,
        'nopasswd_rpc',
      );
      await admin('rm /etc/sudoers.d/99-antirkn-runner-fixture');
    } finally {
      user.close();
    }
    const firstId = '11111111111111111111111111111111';
    final first = RunnerRequest.diagnostic(firstId, count: 6, interval: 1);
    final cursor = (await request(first)).jobs.single.sequence;
    connection.close();
    await Future<void>.delayed(const Duration(seconds: 2));
    connection = await connect();
    final after = (await request(
      RunnerRequest.status(firstId, cursor),
    )).jobs.single;
    check(
      after.checkpoint > 0 && after.events.every((e) => e.sequence > cursor),
      'disconnect_reconnect_missing_events',
    );
    final complete = await waitFor(firstId, (j) => j.terminal);
    check(
      complete.status == 'succeeded' && complete.checkpoint == 6,
      'real_diagnostic_completed',
    );
    check(
      (await request(first)).jobs.single.sequence == complete.sequence,
      'same_id_no_second_execution',
    );
    check(
      (await request(RunnerRequest.diagnostic(firstId, count: 7))).code ==
          'conflict',
      'changed_request_same_id_rejected',
    );
    final peer = await connect();
    final concurrent = await Future.wait([
      request(RunnerRequest.diagnostic('22222222222222222222222222222222')),
      peer.runner!.request(
        RunnerRequest.diagnostic('33333333333333333333333333333333'),
        CancellationToken(),
      ),
    ]);
    peer.close();
    check(
      concurrent.where((r) => r.code == 'ok').length == 1 &&
          concurrent.where((r) => r.code == 'busy').length == 1,
      'two_connections_exclusive_job',
    );
    final active = concurrent.firstWhere((r) => r.code == 'ok').jobs.single.id;
    await request(RunnerRequest.cancel(active));
    check(
      (await waitFor(active, (j) => j.terminal)).status == 'cancelled',
      'cancel_at_checkpoint',
    );
    const crashId = '44444444444444444444444444444444';
    await request(RunnerRequest.diagnostic(crashId, count: 10, interval: 1));
    final checkpoint = (await waitFor(
      crashId,
      (j) => j.checkpoint >= 2,
    )).checkpoint;
    await admin(
      'systemctl kill --signal=KILL --kill-whom=main antirkn-runner.service',
    );
    final recovered = await waitFor(crashId, (j) => j.terminal);
    check(
      recovered.status == 'succeeded' &&
          recovered.checkpoint >= checkpoint &&
          recovered.events.any((e) => e.code == 'recovered'),
      'worker_crash_checkpoint_recovery',
    );
    const rebootId = '55555555555555555555555555555555';
    await request(RunnerRequest.diagnostic(rebootId, count: 8, interval: 2));
    await waitFor(rebootId, (j) => j.checkpoint >= 1);
    await admin('systemctl reboot', success: false);
    connection.close();
    await Future<void>.delayed(const Duration(seconds: 3));
    var reconnected = false;
    for (var i = 0; i < 40; i++) {
      try {
        connection = await connect();
        reconnected = true;
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    check(reconnected, 'vm_reboot_ssh_restored');
    final rebooted = await waitFor(rebootId, (j) => j.terminal);
    check(
      rebooted.status == 'succeeded' &&
          rebooted.events.any((e) => e.code == 'recovered'),
      'systemd_boot_job_recovery',
    );
    check(
      (await admin(
            'stat -c %a /var/lib/antirkn-runner /var/lib/antirkn-runner/jobs.sqlite',
          )).stdout.toString().trim() ==
          '700\n600',
      'private_server_journal',
    );
    final evidence = {
      'checked_at_utc': DateTime.now().toUtc().toIso8601String(),
      'fixture':
          'Disposable QEMU/KVM Ubuntu 24.04.5 x86_64; real systemd, OpenSSH and sudo',
      'image_sha256':
          '612b2c0cc1bc413a6cb8c38fd611794caf0f2b436c50013d8b3794db12ad7354',
      'runner_release': connection.runner!.bundledRelease,
      'results': results,
    };
    await File('docs/evidence/runner-ubuntu.json').writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
    );
  } finally {
    connection.close();
  }
}
