// Disposable two-sshd fixture only. Never print fixture credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';

Future<void> main(List<String> args) async {
  final dir = args.single;
  Future<String> read(String name) => File('$dir/$name').readAsString();
  final credentials = jsonDecode(await read('credentials.json')) as Map;
  final jumpKey = TrustedHostKey(
    'ssh-ed25519',
    (await read('host-fingerprint')).trim(),
  );
  final targetKey = TrustedHostKey(
    'ssh-ed25519',
    (await read('target-fingerprint')).trim(),
  );
  if (jumpKey.matches(targetKey)) throw StateError('Fixture keys must differ');
  final jump = SshProfile(
    id: 'jump',
    host: '127.0.0.1',
    port: int.parse(await read('port')),
    username: 'testuser',
    authMethod: SshAuthMethod.privateKey,
    secrets: {
      ServerSecret.privateKey: await read('encrypted_ed25519'),
      ServerSecret.keyPassphrase: credentials['passphrase'] as String,
    },
  );
  SshProfile target({
    TrustedHostKey? key,
    String? password,
    String host = 'localhost',
    int port = 22241,
  }) => SshProfile(
    id: 'target',
    jumpServerId: jump.id,
    host: host,
    port: port,
    username: 'root',
    authMethod: SshAuthMethod.password,
    hostKey: key,
    secrets: {
      ServerSecret.sshPassword: password ?? credentials['password'] as String,
    },
  );
  const connector = DartSshConnector(
    connectTimeout: Duration(seconds: 5),
    commandTimeout: Duration(seconds: 5),
  );
  final results = <String, Object>{};
  final trustOrder = <String>[];
  Future<bool> verifyJump(SshProfile profile, TrustedHostKey key) async {
    if (profile.id != jump.id || !jumpKey.matches(key)) {
      throw StateError('Wrong jump identity');
    }
    trustOrder.add('jump');
    return true;
  }

  Future<bool> verifyTarget(TrustedHostKey key) async {
    if (!targetKey.matches(key)) throw StateError('Wrong target identity');
    trustOrder.add('target');
    return true;
  }

  Future<SshConnection> connect(
    SshProfile profile, {
    SshProfile? via,
    CancellationToken? token,
    Future<bool> Function(TrustedHostKey)? verifier,
    Future<bool> Function(SshProfile, TrustedHostKey)? jumpVerifier,
  }) => connector.connect(
    profile,
    jumpHosts: [via ?? jump],
    verifyJumpHostKey: jumpVerifier ?? verifyJump,
    verifyHostKey: verifier ?? verifyTarget,
    cancellation: token ?? CancellationToken(),
  );
  Future<void> fails(
    String name,
    SshIssue issue,
    Future<void> Function() run,
  ) async {
    try {
      await run();
    } on SshFailure catch (e) {
      if (e.issue != issue) {
        throw StateError('$name: ${e.issue.name}, expected ${issue.name}');
      }
      results[name] = 'PASS';
      return;
    }
    throw StateError('$name unexpectedly succeeded');
  }

  final connection = await connect(target());
  try {
    final observed = await connection.observe(CancellationToken());
    if (observed.os != 'Ubuntu 24.04' ||
        observed.network.addresses.isEmpty ||
        observed.network.sshPeer != null ||
        trustOrder.join(',') != 'jump,target') {
      throw StateError('Nested observation or trust order invalid');
    }
    results['encrypted_jump_key_target_password'] = 'PASS';
    results['separate_fingerprints_before_each_auth'] = 'PASS';
    results['target_dns_resolved_by_jump_without_false_peer_ip'] = 'PASS';
    await File('$dir/failure').writeAsString('stall');
    await fails(
      'cancel_slow_inventory_through_jump',
      SshIssue.cancelled,
      () async {
        final token = CancellationToken();
        final timer = Timer(const Duration(milliseconds: 300), token.cancel);
        try {
          await connection.observe(token);
        } finally {
          timer.cancel();
        }
      },
    );
  } finally {
    connection.close();
    await connection.done.timeout(const Duration(seconds: 2));
    await File('$dir/failure').writeAsString('');
  }
  const changed = TrustedHostKey('ssh-ed25519', 'SHA256:fixture-changed');
  await fails(
    'changed_jump_key_stops_before_target',
    SshIssue.jumpHostKeyChanged,
    () async {
      (await connect(
        target(),
        via: jump.withHostKey(changed),
        verifier: (_) async => throw StateError('Target reached'),
      )).close();
    },
  );
  await fails(
    'changed_target_key_stops_before_auth',
    SshIssue.hostKeyChanged,
    () async {
      (await connect(
        target(key: changed),
        verifier: (_) async => throw StateError('Changed key reached UI'),
      )).close();
    },
  );
  await fails('rejected_jump_fingerprint', SshIssue.hostKeyRejected, () async {
    (await connect(
      target(),
      jumpVerifier: (_, _) async => false,
      verifier: (_) async => throw StateError('Target reached'),
    )).close();
  });
  await fails(
    'rejected_target_fingerprint',
    SshIssue.hostKeyRejected,
    () async {
      (await connect(target(), verifier: (_) async => false)).close();
    },
  );
  await fails('wrong_target_password', SshIssue.authentication, () async {
    (await connect(target(password: 'incorrect-fixture-password'))).close();
  });
  await fails(
    'unreachable_target_no_direct_fallback',
    SshIssue.network,
    () async {
      (await connect(target(port: 22242))).close();
    },
  );
  await fails(
    'missing_route_no_direct_fallback',
    SshIssue.invalidJumpRoute,
    () async {
      (await connector.connect(
        target(),
        cancellation: CancellationToken(),
        verifyHostKey: verifyTarget,
      )).close();
    },
  );
  await fails('cancel_target_trust', SshIssue.cancelled, () async {
    final token = CancellationToken();
    (await connect(
      target(),
      token: token,
      verifier: (_) async {
        token.cancel();
        return false;
      },
    )).close();
  });
  final keyTarget = SshProfile(
    id: 'target',
    jumpServerId: jump.id,
    host: '127.0.0.1',
    port: 22241,
    username: 'root',
    authMethod: SshAuthMethod.privateKey,
    secrets: {
      ServerSecret.privateKey: await read('encrypted_rsa'),
      ServerSecret.keyPassphrase: credentials['passphrase'] as String,
    },
  );
  final withKey = await connect(keyTarget);
  try {
    await withKey.observe(CancellationToken());
    results['encrypted_keys_on_both_hops'] = 'PASS';
  } finally {
    withKey.close();
  }
  final middle = target();
  final last = SshProfile(
    id: 'last',
    jumpServerId: middle.id,
    host: '127.0.0.1',
    port: 22241,
    username: 'testuser',
    authMethod: SshAuthMethod.password,
    secrets: {ServerSecret.sshPassword: credentials['password'] as String},
  );
  final chain = await connector.connect(
    last,
    jumpHosts: [jump, middle],
    verifyJumpHostKey: (p, k) async =>
        p.id == jump.id ? jumpKey.matches(k) : targetKey.matches(k),
    verifyHostKey: verifyTarget,
    cancellation: CancellationToken(),
  );
  try {
    await chain.observe(CancellationToken());
    results['two_intermediaries_in_saved_route_order'] = 'PASS';
  } finally {
    chain.close();
  }
  // A failed/cancelled route must not break independent sessions to the jump.
  final independent = await connector.connect(
    jump.withHostKey(jumpKey),
    verifyHostKey: (key) async => jumpKey.matches(key),
    cancellation: CancellationToken(),
  );
  try {
    final again = await connect(target());
    again.close();
    await independent.observe(CancellationToken());
    results['reconnect_and_independent_jump_session'] = 'PASS';
  } finally {
    independent.close();
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'fixture':
          'Ubuntu 24.04, separate SSH host keys; target listens only on container loopback:22241',
      'checked_at_utc': DateTime.now().toUtc().toIso8601String(),
      'results': results,
    }),
  );
}
