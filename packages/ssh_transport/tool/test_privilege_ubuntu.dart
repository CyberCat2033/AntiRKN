// Local disposable fixture only. Never print profiles, credentials or raw output.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';

Future<void> main(List<String> args) async {
  final directory = Directory(args.single);
  final data =
      jsonDecode(
            await File('${directory.path}/credentials.json').readAsString(),
          )
          as Map;
  final password = data['password'] as String;
  final pem = await File('${directory.path}/plain_ed25519').readAsString();
  final port = int.parse(await File('${directory.path}/port').readAsString());
  final fingerprint = (await File(
    '${directory.path}/host-fingerprint',
  ).readAsString()).trim();
  final targetFingerprint = (await File(
    '${directory.path}/target-fingerprint',
  ).readAsString()).trim();
  final mode = File('${directory.path}/privilege-mode');
  final results = <String, Object>{};
  const connector = DartSshConnector(commandTimeout: Duration(seconds: 3));
  SshProfile profile(String user, {bool key = false, bool jump = false}) =>
      SshProfile(
        id: jump ? 'target' : 'entry',
        host: '127.0.0.1',
        port: jump ? 22241 : port,
        username: user,
        jumpServerId: jump ? 'entry' : null,
        hostKey: TrustedHostKey(
          'ssh-ed25519',
          jump ? targetFingerprint : fingerprint,
        ),
        authMethod: key ? SshAuthMethod.privateKey : SshAuthMethod.password,
        secrets: {
          ServerSecret.sshPassword: password,
          ServerSecret.privateKey: pem,
        },
      );
  Future<SshConnection> connect(
    String user, {
    bool key = false,
    bool jump = false,
  }) => connector.connect(
    profile(user, key: key, jump: jump),
    cancellation: CancellationToken(),
    verifyHostKey: (key) async =>
        key.fingerprint == (jump ? targetFingerprint : fingerprint),
    jumpHosts: jump ? [profile('testuser')] : [],
    verifyJumpHostKey: (_, key) async => key.fingerprint == fingerprint,
  );

  Future<void> check(
    String name,
    String user,
    PrivilegeStatus expected, {
    String? sudoPassword,
    bool key = false,
    bool jump = false,
  }) async {
    final connection = await connect(user, key: key, jump: jump);
    try {
      final result = await connection.checkPrivileges(
        CancellationToken(),
        sudoPassword: sudoPassword,
      );
      if (result.status != expected) {
        throw StateError(
          '$name: ${result.status.name}, expected ${expected.name}',
        );
      }
      results[name] = 'PASS';
    } finally {
      connection.close();
    }
  }

  await mode.writeAsString('');
  await check('root_password', 'root', PrivilegeStatus.root);
  await check(
    'root_key_no_extra_password',
    'root',
    PrivilegeStatus.root,
    key: true,
  );
  await check('sudo_nopasswd', 'testuser', PrivilegeStatus.sudoWithoutPassword);
  await check(
    'nopasswd_does_not_send_supplied_password',
    'testuser',
    PrivilegeStatus.sudoWithoutPassword,
    sudoPassword: 'unused-fixture-password',
  );
  await check(
    'sudo_password_required',
    'passuser',
    PrivilegeStatus.passwordRequired,
  );
  await check(
    'sudo_password',
    'passuser',
    PrivilegeStatus.sudoWithPassword,
    sudoPassword: password,
  );
  await check(
    'sudo_key_and_separate_password',
    'passuser',
    PrivilegeStatus.sudoWithPassword,
    key: true,
    sudoPassword: password,
  );
  await check(
    'sudo_wrong_password',
    'passuser',
    PrivilegeStatus.authenticationFailed,
    sudoPassword: 'wrong-fixture-password',
  );
  await check(
    'sudo_denied',
    'denieduser',
    PrivilegeStatus.denied,
    sudoPassword: password,
  );
  await check(
    'sudo_requires_terminal',
    'ttyuser',
    PrivilegeStatus.terminalRequired,
  );
  await check(
    'sudo_invalid_password',
    'passuser',
    PrivilegeStatus.invalidPassword,
    sudoPassword: 'line\nbreak',
  );
  await check(
    'sudo_through_jump',
    'passuser',
    PrivilegeStatus.sudoWithPassword,
    key: true,
    jump: true,
    sudoPassword: password,
  );

  for (final user in ['testuser', 'passuser', 'limiteduser']) {
    final connection = await connect(user);
    try {
      final plain = await connection.observe(CancellationToken());
      if (!plain.software!.components[2].issues.contains(
        InventoryStatus.denied,
      )) {
        throw StateError('Expected restricted fixture directory');
      }
      final elevated = await connection.observe(
        CancellationToken(),
        useSudo: true,
        sudoPassword: user == 'passuser' ? password : null,
      );
      final component = elevated.software!.components[2];
      if (user == 'limiteduser') {
        if (!component.issues.contains(InventoryStatus.denied)) {
          throw StateError('Command-specific denial disappeared');
        }
      } else if (!component.installations.any(
        (i) => i.version?.value == '1.1.0',
      )) {
        throw StateError('Elevated read did not obtain version');
      }
      if (elevated.software!.facts[ServerFact.uid]!.value == '0') {
        throw StateError('SSH account UID replaced by sudo UID');
      }
      results['restricted_read_$user'] = 'PASS';
    } finally {
      connection.close();
    }
  }
  await mode.writeAsString('unavailable');
  await check('sudo_unavailable', 'passuser', PrivilegeStatus.unavailable);
  await mode.writeAsString('slow');
  await check(
    'delayed_sudo',
    'passuser',
    PrivilegeStatus.sudoWithPassword,
    sudoPassword: password,
  );
  for (final entry in {
    'timeout': 'stall',
    'cancel': 'stall',
    'disconnect': 'disconnect',
  }.entries) {
    await mode.writeAsString(entry.value);
    final connection = await connect(
      entry.key == 'disconnect' ? 'testuser' : 'passuser',
    );
    final token = CancellationToken();
    final timer = entry.key == 'cancel'
        ? Timer(const Duration(milliseconds: 300), token.cancel)
        : null;
    try {
      await connection.checkPrivileges(token, sudoPassword: password);
      throw StateError('${entry.key} unexpectedly succeeded');
    } on SshFailure catch (e) {
      final allowed = switch (entry.key) {
        'timeout' => {SshIssue.timeout},
        'cancel' => {SshIssue.cancelled},
        _ => {SshIssue.network, SshIssue.disconnected, SshIssue.commandFailed},
      };
      if (!allowed.contains(e.issue)) {
        throw StateError('${entry.key}: ${e.issue.name}');
      }
      results[entry.key] = 'PASS';
    } finally {
      timer?.cancel();
      connection.close();
    }
  }
  await mode.writeAsString('');
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(results));
}
