// Runs only against the disposable localhost fixture from tool/ssh_fixture_setup.sh.
// Test credentials are read from its private directory and never printed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';

Future<void> main(List<String> args) async {
  final directory = Directory(args.single);
  if (!await File('${directory.path}/ready').exists()) {
    throw StateError('Fixture is not ready');
  }
  final credentials =
      jsonDecode(
            await File('${directory.path}/credentials.json').readAsString(),
          )
          as Map<String, dynamic>;
  final expected = (await File(
    '${directory.path}/host-fingerprint',
  ).readAsString()).trim();
  final audit = File('${directory.path}/commands');
  final failure = File('${directory.path}/failure');
  final portFile = File('${directory.path}/port');
  final port = await portFile.exists()
      ? int.parse(await portFile.readAsString())
      : 22240;
  await failure.writeAsString('');
  final results = <String, Object?>{};
  final connector = const DartSshConnector(
    commandTimeout: Duration(seconds: 3),
  );
  Future<SshProfile> profile(
    String username, {
    String? key,
    bool agent = false,
    String? password,
    TrustedHostKey? trust,
  }) async => SshProfile(
    host: '127.0.0.1',
    port: port,
    username: username,
    authMethod: agent
        ? SshAuthMethod.agent
        : key == null
        ? SshAuthMethod.password
        : SshAuthMethod.privateKey,
    hostKey: trust,
    secrets: {
      ServerSecret.sshPassword: password ?? credentials['password']! as String,
      if (key != null)
        ServerSecret.privateKey: await File(
          '${directory.path}/$key',
        ).readAsString(),
      ServerSecret.keyPassphrase: credentials['passphrase']! as String,
    },
  );
  Future<bool> verify(TrustedHostKey key) async {
    if (key.fingerprint != expected) {
      throw StateError('Fixture fingerprint differs');
    }
    return true;
  }

  Future<void> success(String name, SshProfile profile) async {
    final token = CancellationToken();
    final connection = await connector.connect(
      profile,
      verifyHostKey: verify,
      cancellation: token,
    );
    unawaited(connection.done.catchError((Object _) {}));
    try {
      final snapshot = await connection.observe(token);
      if (snapshot.os != 'Ubuntu 24.04' ||
          snapshot.architecture != 'x86_64' ||
          snapshot.network.addresses.isEmpty ||
          !snapshot.network.addresses.any(
            (a) => a.address.canonical == '192.0.2.41',
          ) ||
          snapshot.network.sshPeer?.canonical != '127.0.0.1') {
        throw StateError('Unexpected observation');
      }
      results[name] = {
        'status': 'PASS',
        'addresses': snapshot.network.addresses.length,
        'routes': snapshot.network.routes.length,
        'rules': snapshot.network.rules.length,
      };
    } finally {
      connection.close();
    }
  }

  Future<void> fails(
    String name,
    Future<void> Function() run,
    SshIssue expectedIssue,
  ) async {
    try {
      await run();
    } on SshFailure catch (e) {
      if (e.issue != expectedIssue) {
        throw StateError(
          '$name: ${e.issue.name}, expected ${expectedIssue.name}',
        );
      }
      results[name] = 'PASS';
      return;
    }
    throw StateError('$name unexpectedly succeeded');
  }

  await success('user_password', await profile('testuser'));
  await success('root_password', await profile('root'));
  await success(
    'user_plain_ed25519',
    await profile('testuser', key: 'plain_ed25519'),
  );
  await success(
    'root_encrypted_ed25519',
    await profile('root', key: 'encrypted_ed25519'),
  );
  final heartbeat = Stopwatch()..start();
  var previousTick = 0, maxGap = 0, ticks = 0;
  void tick() {
    final now = heartbeat.elapsedMilliseconds;
    final gap = now - previousTick;
    if (gap > maxGap) maxGap = gap;
    previousTick = now;
    ticks++;
  }

  final timer = Timer.periodic(const Duration(milliseconds: 16), (_) => tick());
  try {
    await success(
      'user_encrypted_rsa',
      await profile('testuser', key: 'encrypted_rsa'),
    );
    tick();
  } finally {
    timer.cancel();
  }
  if (ticks < 2 || maxGap > 250) {
    throw StateError('SSH blocked the calling isolate');
  }
  results['calling_isolate_heartbeat'] = {
    'ticks': ticks,
    'max_gap_ms': maxGap,
    'limit_ms': 250,
  };
  if (linuxSshAgentAvailable) {
    await success('linux_agent', await profile('testuser', agent: true));
  }
  var before = (await audit.readAsLines()).length;
  await fails('wrong_password', () async {
    final c = await connector.connect(
      await profile('testuser', password: 'incorrect-fixture-password'),
      verifyHostKey: verify,
      cancellation: CancellationToken(),
    );
    c.close();
  }, SshIssue.authentication);
  await fails('rejected_fingerprint', () async {
    final c = await connector.connect(
      await profile('testuser'),
      verifyHostKey: (_) async => false,
      cancellation: CancellationToken(),
    );
    c.close();
  }, SshIssue.hostKeyRejected);
  await fails('changed_fingerprint', () async {
    final c = await connector.connect(
      await profile(
        'testuser',
        trust: const TrustedHostKey('ssh-ed25519', 'SHA256:another-server'),
      ),
      verifyHostKey: (_) async => throw StateError('Changed key reached UI'),
      cancellation: CancellationToken(),
    );
    c.close();
  }, SshIssue.hostKeyChanged);
  if ((await audit.readAsLines()).length != before) {
    throw StateError('Commands ran before authentication');
  }
  results['no_commands_before_trust_and_auth'] = 'PASS';

  for (final entry in {
    'exit': SshIssue.commandFailed,
    'invalid': SshIssue.invalidInventory,
    'large': SshIssue.outputLimit,
    'unsupported': SshIssue.unsupportedOs,
    'stall': SshIssue.timeout,
  }.entries) {
    await failure.writeAsString(entry.key);
    await fails('inventory_${entry.key}', () async {
      final token = CancellationToken();
      final c = await connector.connect(
        await profile('testuser'),
        verifyHostKey: verify,
        cancellation: token,
      );
      unawaited(c.done.catchError((Object _) {}));
      try {
        await c.observe(token);
      } finally {
        c.close();
      }
    }, entry.value);
  }
  await failure.writeAsString('stall');
  await fails('cancel_inventory', () async {
    final token = CancellationToken();
    final c = await connector.connect(
      await profile('testuser'),
      verifyHostKey: verify,
      cancellation: token,
    );
    unawaited(c.done.catchError((Object _) {}));
    final timer = Timer(const Duration(milliseconds: 300), token.cancel);
    try {
      await c.observe(token);
    } finally {
      timer.cancel();
      c.close();
    }
  }, SshIssue.cancelled);
  await failure.writeAsString('');
  final commands = await audit.readAsLines();
  const allowed = {
    'cat /etc/os-release',
    'uname -m',
    'ip -j -details address show',
    'ip -j -4 route show table all',
    'ip -j -6 route show table all',
    'ip -j -4 rule show',
    'ip -j -6 rule show',
  };
  if (commands.any((command) => !allowed.contains(command))) {
    throw StateError('Unexpected mutation command');
  }
  results['only_read_commands'] = 'PASS';
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(results));
}
