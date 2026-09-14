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
        id: 'component-fixture',
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
      for (final component in ['trusttunnel', 'amneziawg']) {
        final response = await remote.request(
          RunnerRequest.componentPlan(component),
          CancellationToken(),
          sudoPassword: password,
        );
        check(
          response.componentPlan?.state == 'current',
          '${user}_${component}_read_only_plan',
        );
        check(
          response.componentPlan?.installedVersion ==
              (component == 'trusttunnel' ? '1.1.0' : '3.1.20260828'),
          '${user}_${component}_actual_version',
        );
      }
      final cancelled = CancellationToken()..cancel();
      try {
        await remote.request(
          RunnerRequest.componentPlan('trusttunnel'),
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
  await File('../../docs/evidence/components-ssh.json').writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({'results': results})}\n',
  );
}
