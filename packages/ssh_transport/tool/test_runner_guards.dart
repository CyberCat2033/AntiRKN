import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';

Future<void> main(List<String> args) async {
  final path = args.single;
  final port = int.parse(await File('$path/port').readAsString());
  final pem = await File('$path/client').readAsString();
  final fp = (await File('$path/fingerprint').readAsString()).trim();
  final secret =
      (jsonDecode(await File('$path/credentials.json').readAsString())
              as Map)['password']
          as String;
  final results = <String, bool>{};
  void check(bool value, String name) {
    if (!value) throw StateError(name);
    results[name] = true;
    stdout.writeln('PASS $name');
  }

  Future<SshConnection> connect(String user) =>
      const DartSshConnector().connect(
        SshProfile(
          id: 'guards',
          host: '127.0.0.1',
          port: port,
          username: user,
          authMethod: SshAuthMethod.privateKey,
          secrets: {ServerSecret.privateKey: pem},
        ),
        cancellation: CancellationToken(),
        verifyHostKey: (k) async => k.fingerprint == fp,
      );
  Future<String> admin(String command) async {
    final r = await Process.run('ssh', [
      '-i',
      '$path/client',
      '-o',
      'BatchMode=yes',
      '-o',
      'IdentitiesOnly=yes',
      '-o',
      'UserKnownHostsFile=$path/known_hosts',
      '-p',
      '$port',
      'root@127.0.0.1',
      command,
    ]);
    if (r.exitCode != 0) throw StateError('guard_fixture_admin');
    return r.stdout as String;
  }

  final root = await connect('root');
  final user = await connect('antirkn');
  try {
    final before = await root.runner!.inspect(CancellationToken());
    check(
      (await user.runner!.install(
        before,
        CancellationToken(),
        sudoPassword: secret,
      )).active,
      'password_sudo_installer_stdin',
    );
    final fresh = await root.runner!.inspect(CancellationToken());
    try {
      await user.runner!.install(
        fresh,
        CancellationToken(),
        sudoPassword: 'bad-fixture',
      );
      throw StateError('wrong_installer_password_accepted');
    } on SshFailure catch (e) {
      check(
        e.issue == SshIssue.sudoAuthenticationFailed,
        'installer_wrong_password_single_attempt',
      );
    }
    final configBefore = await admin(
      'sha256sum /etc/ssh/sshd_config /etc/sudoers /etc/systemd/system/antirkn-runner.service /usr/local/lib/antirkn-runner/v1/*.py /usr/local/lib/antirkn-runner/v1/manifest.json',
    );
    await admin(
      "cp /etc/os-release /tmp/antirkn-original-os; printf 'ID=debian\\n' > /etc/os-release",
    );
    try {
      final unsupported = await root.runner!.inspect(CancellationToken());
      check(!unsupported.supported, 'other_distribution_precondition');
      try {
        await root.runner!.install(fresh, CancellationToken());
        throw StateError('os_change_accepted');
      } on RunnerFailure catch (e) {
        check(
          e.issue == RunnerIssue.installFailed,
          'server_rechecks_os_before_mutation',
        );
      }
    } finally {
      await admin(
        'cat /tmp/antirkn-original-os > /etc/os-release; rm /tmp/antirkn-original-os',
      );
    }
    check(
      await admin(
            'sha256sum /etc/ssh/sshd_config /etc/sudoers /etc/systemd/system/antirkn-runner.service /usr/local/lib/antirkn-runner/v1/*.py /usr/local/lib/antirkn-runner/v1/manifest.json',
          ) ==
          configBefore,
      'guard_rejection_preserves_configs',
    );
    await admin(
      "cp /etc/systemd/system/antirkn-runner.service /tmp/antirkn-original-unit; printf '\\n# externally changed fixture\\n' >> /etc/systemd/system/antirkn-runner.service",
    );
    try {
      check(
        (await root.runner!.inspect(CancellationToken())).state == 'conflict',
        'external_unit_change_detected',
      );
      try {
        await root.runner!.install(fresh, CancellationToken());
        throw StateError('changed_unit_accepted');
      } on RunnerFailure catch (e) {
        check(
          e.issue == RunnerIssue.installFailed,
          'external_unit_not_overwritten',
        );
      }
    } finally {
      await admin(
        'cat /tmp/antirkn-original-unit > /etc/systemd/system/antirkn-runner.service; rm /tmp/antirkn-original-unit',
      );
    }
    check(
      (await root.runner!.inspect(CancellationToken())).fingerprint ==
          fresh.fingerprint,
      'fixture_state_restored',
    );
    final cancelled = CancellationToken()..cancel();
    const cancelledId = 'cccccccccccccccccccccccccccccccc';
    try {
      await root.runner!.request(
        RunnerRequest.diagnostic(cancelledId),
        cancelled,
      );
      throw StateError('cancelled_request_sent');
    } on SshFailure catch (e) {
      check(e.issue == SshIssue.cancelled, 'cancel_before_send');
    }
    check(
      (await root.runner!.request(
            RunnerRequest.status(cancelledId, 0),
            CancellationToken(),
          )).code ==
          'missing',
      'cancelled_request_has_no_server_effect',
    );
    final file = File('docs/evidence/runner-guards.json');
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'checked_at_utc': DateTime.now().toUtc().toIso8601String(), 'runner_release': root.runner!.bundledRelease, 'results': results})}\n',
    );
  } finally {
    user.close();
    root.close();
  }
}
