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
  final results = <String, bool>{};
  void check(bool condition, String name) {
    if (!condition) throw StateError(name);
    results[name] = true;
    stdout.writeln('PASS $name');
  }

  for (final user in ['root', 'antirkn']) {
    final connection = await const DartSshConnector().connect(
      SshProfile(
        id: 'panel-fixture',
        host: '127.0.0.1',
        port: port,
        username: user,
        authMethod: user == 'root'
            ? SshAuthMethod.privateKey
            : SshAuthMethod.password,
        secrets: {
          ServerSecret.privateKey: key,
          ServerSecret.sshPassword: password,
        },
      ),
      verifyHostKey: (host) async => host.fingerprint == fingerprint,
      cancellation: CancellationToken(),
    );
    try {
      final remote = connection.runner!;
      final install = await remote.inspect(CancellationToken());
      check(
        install.active && install.release == remote.bundledRelease,
        '${user}_runner_release',
      );
      final jobs = await remote.request(
        RunnerRequest.list(),
        CancellationToken(),
        sudoPassword: password,
      );
      final job = jobs.jobs.firstWhere(
        (j) => j.kind == 'panel_install' && j.status == 'succeeded',
      );
      final api = await remote.request(
        RunnerRequest.panelVerify(job.id),
        CancellationToken(),
        sudoPassword: password,
      );
      check(
        api.panelVerified && api.panelAccess?.id == job.id,
        '${user}_api_through_direct_tcpip',
      );
      final again = await remote.request(
        RunnerRequest.panelVerify(job.id),
        CancellationToken(),
        sudoPassword: password,
      );
      check(
        again.panelAccess!.password == api.panelAccess!.password,
        '${user}_stable_credentials',
      );
      final cancelled = CancellationToken()..cancel();
      try {
        await remote.request(
          RunnerRequest.panelVerify(job.id),
          cancelled,
          sudoPassword: password,
        );
        throw StateError('cancel_not_enforced');
      } on SshFailure catch (e) {
        check(e.issue == SshIssue.cancelled, '${user}_cancel_before_request');
      }
    } finally {
      connection.close();
    }
  }
  await File('../../docs/evidence/panel-ssh-api.json').writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({'results': results})}\n',
  );
}
