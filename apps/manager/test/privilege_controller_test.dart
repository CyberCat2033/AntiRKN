import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'ssh_support.dart';

void main() {
  late FakeVault vault;
  late FakeConnector connector;
  late SshController c;
  setUp(() async {
    vault = FakeVault();
    connector = FakeConnector();
    c = controller(vault, connector);
    await prepare(c);
    c.username.text = 'operator';
    await c.save();
    vault.saved = vault.saved!.withHostKey(connector.key);
    await c.connect();
  });
  tearDown(() {
    c.dispose();
    c.network.dispose();
  });

  test(
    'connect checks SSH password before any prompt; refresh reveals failures',
    () async {
      expect(c.privileges!.granted, isTrue);
      expect(connector.connection.lastSudoPassword, c.password.text);
      expect(c.showPrivilegePrompt, isFalse);
      var attempts = 0;
      connector.connection.privilegeChecker = (_, _) async {
        attempts++;
        return const PrivilegeCheck(PrivilegeStatus.authenticationFailed);
      };
      await c.refresh();
      expect(c.showPrivilegePrompt, isTrue);
      await c.refresh();
      expect(attempts, 1); // No background retry of a rejected credential.
      c.sudoPassword.text = 'new-fixture-password';
      expect(c.showPrivilegePrompt, isTrue);
      connector.connection.privilegeChecker = (_, _) async =>
          const PrivilegeCheck(PrivilegeStatus.sudoWithPassword);
      await c.checkPrivileges();
      expect(c.showPrivilegePrompt, isFalse);
      expect(c.stage, SshStage.connected);
      connector.connection.privilegeChecker = (_, _) async =>
          const PrivilegeCheck(PrivilegeStatus.authenticationFailed);
      await c.refresh();
      expect(c.showPrivilegePrompt, isTrue);
    },
  );

  test('after a server job the installed versions are read again', () async {
    // The connection caches program versions; reusing them after an
    // update showed the old version until the next reconnect.
    final before = connector.connection.reads;
    expect(connector.connection.lastFresh, isFalse);
    c.runner.refreshSoftware!();
    await pumpEventQueue();
    expect(connector.connection.reads, before + 1);
    expect(connector.connection.lastFresh, isTrue);
    await c.refresh();
    expect(connector.connection.lastFresh, isFalse);
  });

  test('failure of a later protected probe reopens the prompt', () async {
    connector.connection.reader = () async => ServerObservation(
      os: c.observation!.os,
      architecture: c.observation!.architecture,
      network: c.observation!.network,
      privilegeIssue: SshIssue.sudoAuthenticationFailed,
    );
    await c.refresh();
    expect(c.showPrivilegePrompt, isTrue);
    expect(c.privileges!.status, PrivilegeStatus.authenticationFailed);
    expect(c.stage, SshStage.connected);
  });

  test(
    'connection loss during password save cannot leave the UI busy',
    () async {
      c.sudoPassword.text = 'new-fixture-password';
      final gate = Completer<void>();
      vault.writeGate = gate;
      final work = c.checkPrivileges();
      await Future<void>.delayed(Duration.zero);
      connector.connection.close();
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await work;
      expect(c.busy, isFalse);
      expect(c.stage, SshStage.idle);
      expect(c.error, SshIssue.disconnected);
    },
  );

  test('repeated action cannot send concurrent password attempts', () async {
    var calls = 0;
    connector.connection.privilegeChecker = (_, _) async {
      calls++;
      return const PrivilegeCheck(PrivilegeStatus.authenticationFailed);
    };
    await Future.wait([c.checkPrivileges(), c.checkPrivileges()]);
    expect(calls, 1);
  });

  test(
    'SSH password is the sudo default; override is separate, saved and restored',
    () async {
      final sshPassword = c.password.text;
      await c.checkPrivileges();
      expect(connector.connection.lastSudoPassword, sshPassword);
      expect(connector.connection.lastUseSudo, isTrue);
      c.sudoPassword.text = 'separate-fixture-sudo';
      expect(c.privileges, isNull);
      await c.checkPrivileges();
      expect(connector.connection.lastSudoPassword, 'separate-fixture-sudo');
      expect(vault.saved!.secrets[ServerSecret.sshPassword], sshPassword);
      expect(
        vault.saved!.secrets[ServerSecret.sudoPassword],
        'separate-fixture-sudo',
      );
      c.lock();
      expect(c.sudoPassword.text, isEmpty);
      await c.initialise();
      expect(c.sudoPassword.text, 'separate-fixture-sudo');
      expect(c.privileges, isNull);
    },
  );

  test(
    'agent/key authentication never substitutes a saved SSH password or passphrase',
    () async {
      c.disconnect();
      c.editSettings();
      c.setAuth(SshAuthMethod.agent);
      c.passphrase.text = 'fixture-key-passphrase';
      await c.save();
      connector.connection = FakeConnection();
      connector.connection.privilegeChecker = (password, _) async {
        expect(password, isNull);
        return const PrivilegeCheck(PrivilegeStatus.passwordRequired);
      };
      await c.connect();
      await c.checkPrivileges();
      expect(c.privileges!.status, PrivilegeStatus.passwordRequired);
      expect(connector.connection.reads, 1);
      expect(c.stage, SshStage.connected);
    },
  );

  test(
    'wrong password preserves SSH and snapshot without automatically retrying',
    () async {
      var attempts = 0;
      final snapshot = c.observation;
      connector.connection.privilegeChecker = (_, _) async {
        attempts++;
        return const PrivilegeCheck(PrivilegeStatus.authenticationFailed);
      };
      await c.checkPrivileges();
      expect(attempts, 1);
      expect(c.observation, same(snapshot));
      expect(c.stage, SshStage.connected);
      expect(connector.connection.closed, isFalse);
      expect(connector.connection.reads, 1);
    },
  );

  test(
    'failed password persistence prevents transmission and preserves saved credentials',
    () async {
      c.sudoPassword.text = 'unsaved-fixture';
      vault.failWrite = true;
      var attempts = 0;
      connector.connection.privilegeChecker = (_, _) async {
        attempts++;
        return const PrivilegeCheck(PrivilegeStatus.root);
      };
      await c.checkPrivileges();
      expect(attempts, 0);
      expect(c.vaultError, VaultIssue.writeFailed);
      expect(vault.saved!.secrets[ServerSecret.sudoPassword] ?? '', isEmpty);
      expect(c.stage, SshStage.connected);
    },
  );

  test('cancellation prevents late privilege success or refresh', () async {
    final pending = Completer<PrivilegeCheck>();
    connector.connection.privilegeChecker = (_, token) =>
        token.bind(pending.future);
    final work = c.checkPrivileges();
    await Future<void>.delayed(Duration.zero);
    expect(c.stage, SshStage.checkingPrivileges);
    c.disconnect();
    pending.complete(const PrivilegeCheck(PrivilegeStatus.root));
    await work;
    expect(c.stage, SshStage.idle);
    expect(c.privileges, isNull);
    expect(connector.connection.reads, 1);
  });

  test(
    'root result needs no sudo on subsequent inventory; malformed password is local',
    () async {
      connector.connection.privilegeChecker = (_, _) async =>
          const PrivilegeCheck(PrivilegeStatus.root);
      await c.checkPrivileges();
      expect(c.isRoot, isTrue);
      expect(connector.connection.lastUseSudo, isFalse);
      c.sudoPassword.text = 'bad\nline';
      await c.checkPrivileges();
      expect(c.privileges!.status, PrivilegeStatus.invalidPassword);
    },
  );

  test(
    'canCheckPrivileges is true while settings are expanded; fallback to password.text',
    () async {
      c.editSettings();
      expect(c.settingsExpanded, isTrue);
      expect(c.canCheckPrivileges, isTrue);
      c.sudoPassword.clear();
      c.password.text = 'active-draft-password';
      connector.connection.privilegeChecker = (_, _) async =>
          const PrivilegeCheck(PrivilegeStatus.sudoWithPassword);
      await c.checkPrivileges();
      expect(connector.connection.lastSudoPassword, 'active-draft-password');
      expect(c.privileges!.granted, isTrue);
    },
  );
}
