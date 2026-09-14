import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';

// All connection material is confined to the private disposable VM folders.
Future<void> main(List<String> args) async {
  final results = <String, bool>{};
  final credentialSets = <Set<String>>[];
  void check(bool condition, String name) {
    if (!condition) throw StateError(name);
    results[name] = true;
    stdout.writeln('PASS $name');
  }

  for (var index = 0; index < args.length; index++) {
    final path = args[index];
    final port = int.parse(await File('$path/port').readAsString());
    final key = await File('$path/client').readAsString();
    final fingerprint = (await File('$path/fingerprint').readAsString()).trim();
    final password =
        (jsonDecode(await File('$path/credentials.json').readAsString())
                as Map)['password']
            as String;
    for (final user in ['root', 'antirkn']) {
      final prefix = 'server${index + 1}_$user';
      final connection = await const DartSshConnector().connect(
        SshProfile(
          id: prefix,
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
          '${prefix}_bundled_release',
        );
        Future<RunnerResponse> send(RunnerRequest r) =>
            remote.request(r, CancellationToken(), sudoPassword: password);
        final jobs = await send(RunnerRequest.list());
        final panel = jobs.jobs
            .firstWhere(
              (j) => j.kind == 'panel_install' && j.status == 'succeeded',
            )
            .id;
        final response = await send(RunnerRequest.vlessState(panel));
        final rows = response.vlessState!;
        check(
          response.code == 'ok' &&
              rows.length == 5 &&
              rows.every((r) => r['confirmed'] == true),
          '${prefix}_confirmed_accesses',
        );
        final clients = rows.first['clients'] as List;
        final payload = <String, Object?>{
          'version': 1,
          'workspaceId': rows.first['workspaceId'],
          'panelId': panel,
          'resources': rows.map((r) => r['spec']).toList(),
          'users': clients
              .map((u) => {'id': u['id'], 'enabled': u['enabled']})
              .toList(),
        };
        final plan = await send(RunnerRequest.vlessPlan(panel, payload));
        check(
          plan.code == 'ok' && plan.vlessPlan?['fingerprint'] is String,
          '${prefix}_plan_through_ssh',
        );
        final bad = Map<String, Object?>.from(
          jsonDecode(jsonEncode(payload)) as Map,
        );
        final resources = bad['resources'] as List;
        resources[1]['port'] = resources[0]['port'];
        final refused = await send(RunnerRequest.vlessPlan(panel, bad));
        check(
          refused.code == 'vless_port_busy',
          '${prefix}_typed_remote_rejection',
        );
        if (user == 'root') {
          credentialSets.add({
            for (final r in rows)
              for (final u in r['clients'] as List) u['uuid'] as String,
          });
        }
      } finally {
        connection.close();
      }
    }
  }
  check(
    credentialSets.length == 2 &&
        credentialSets[0].length == 10 &&
        credentialSets[1].length == 10 &&
        credentialSets[0].intersection(credentialSets[1]).isEmpty,
    'two_servers_distinct_personal_credentials',
  );
  await File('../../docs/evidence/vless-ssh-api.json').writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({'results': results})}\n',
  );
}
