import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ssh_support.dart';
import 'network_support.dart';

void main() {
  test(
    'software refresh replaces partial snapshot, failed refresh preserves it, lock clears it',
    () async {
      final vault = FakeVault(), connector = FakeConnector();
      final c = controller(vault, connector);
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      ServerObservation snapshot(InventoryStatus status) => ServerObservation(
        os: 'Ubuntu 24.04',
        architecture: 'x86_64',
        network: testInventory(),
        software: ServerSoftwareInventory(
          observedAt: DateTime.utc(2026),
          facts: {
            ServerFact.freeDiskKiB: status == InventoryStatus.ok
                ? const InventoryValue.ok('1234')
                : InventoryValue.failure(status),
          },
          components: [],
          sockets: [],
        ),
      );
      connector.connection.reader = () async =>
          snapshot(InventoryStatus.denied);
      final work = c.connect();
      await Future<void>.delayed(Duration.zero);
      c.decide(true);
      await work;
      expect(c.stage, SshStage.connected);
      expect(
        c.observation!.software!.facts[ServerFact.freeDiskKiB]!.status,
        InventoryStatus.denied,
      );
      connector.connection.reader = () async => snapshot(InventoryStatus.ok);
      await c.refresh();
      final previous = c.observation;
      expect(previous!.software!.facts[ServerFact.freeDiskKiB]!.value, '1234');
      connector.connection.reader = () async =>
          throw const SshFailure(SshIssue.network);
      await c.refresh();
      expect(c.observation, same(previous));
      c.lock();
      expect(c.observation, isNull);
      expect(c.network.inventory, isNull);
    },
  );

  for (final saveFirst in [false, true]) {
    test(
      'changing host requests its own key (save first: $saveFirst)',
      () async {
        final vault = FakeVault();
        final connector = FakeConnector();
        final c = controller(vault, connector);
        addTearDown(c.dispose);
        addTearDown(c.network.dispose);
        await prepare(c);
        final first = c.connect();
        await Future<void>.delayed(Duration.zero);
        c.decide(true);
        await first;
        c.disconnect();
        c.editSettings();
        c.host.text = 'second.example';
        expect(c.trustedKey, isNull);
        if (saveFirst) {
          expect(await c.save(), isTrue);
          expect(vault.saved!.hostKey, isNull);
          c.lock();
          await c.open();
        }
        connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:second');
        connector.connection = FakeConnection();
        final second = c.connect();
        await Future<void>.delayed(Duration.zero);
        expect(c.stage, SshStage.verifying);
        expect(c.challenge!.fingerprint, 'SHA256:second');
        expect(connector.authentications, 1);
        expect(c.observation, isNull);
        c.decide(true);
        await second;
        expect(c.stage, SshStage.connected);
        expect(vault.saved!.host, 'second.example');
        expect(vault.saved!.hostKey!.fingerprint, 'SHA256:second');
        expect(connector.authentications, 2);
      },
    );
  }

  for (final outcome in ['accept', 'reject', 'write failure']) {
    test(
      'explicit replacement $outcome verifies before auth and preserves credentials',
      () async {
        final vault = FakeVault();
        final connector = FakeConnector();
        final c = controller(vault, connector);
        addTearDown(c.dispose);
        addTearDown(c.network.dispose);
        await prepare(c);
        final first = c.connect();
        await Future<void>.delayed(Duration.zero);
        c.decide(true);
        await first;
        c.disconnect();
        final oldKey = vault.saved!.hostKey;
        final secrets = vault.saved!.secrets;
        connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:second');
        connector.connection = FakeConnection();
        await c.connect();
        expect(c.error, SshIssue.hostKeyChanged);
        expect(connector.authentications, 1);
        final replacement = c.replaceServer();
        await Future<void>.delayed(Duration.zero);
        expect(c.replacingServer, isTrue);
        expect(c.stage, SshStage.verifying);
        expect(c.trustedKey, same(oldKey));
        expect(c.challenge!.fingerprint, 'SHA256:second');
        expect(connector.authentications, 1);
        vault.failWrite = outcome == 'write failure';
        c.decide(outcome != 'reject');
        await replacement;
        expect(c.replacingServer, isFalse);
        expect(vault.saved!.secrets, secrets);
        if (outcome == 'accept') {
          expect(c.stage, SshStage.connected);
          expect(vault.saved!.hostKey!.fingerprint, 'SHA256:second');
          expect(connector.authentications, 2);
          c.disconnect();
          connector.key = const TrustedHostKey(
            'ssh-ed25519',
            'SHA256:unexpected',
          );
          await c.connect();
          expect(c.error, SshIssue.hostKeyChanged);
          expect(connector.authentications, 2);
        } else {
          expect(
            c.error,
            outcome == 'reject'
                ? SshIssue.hostKeyRejected
                : SshIssue.trustSaveFailed,
          );
          expect(vault.saved!.hostKey, same(oldKey));
          expect(connector.authentications, 1);
        }
      },
    );
  }

  test(
    'rename and cancel preserve the live session and trusted identity',
    () async {
      final vault = FakeVault();
      final connector = FakeConnector();
      final c = controller(vault, connector);
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      c.serverName.text = 'Мой VPS';
      final work = c.connect();
      await Future<void>.delayed(Duration.zero);
      c.decide(true);
      await work;
      expect(c.settingsExpanded, isFalse);
      expect(c.displayName, 'Мой VPS');
      final inventory = c.network.inventory;
      final trustedKey = c.trustedKey;
      c.editSettings();
      c.serverName.text = 'Другой сервер';
      c.host.text = 'another.example';
      c.password.text = 'changed-test-only';
      c.cancelEditing();
      expect(c.settingsExpanded, isFalse);
      expect(c.serverName.text, 'Мой VPS');
      expect(c.host.text, 'fixture.example');
      expect(c.password.text, 'fixture-password-only');
      expect(connector.connection.closed, isFalse);
      c.editSettings();
      c.serverName.text = '  Личный VPS  ';
      expect(await c.save(), isTrue);
      expect(c.displayName, 'Личный VPS');
      expect(c.settingsExpanded, isFalse);
      expect(c.stage, SshStage.connected);
      expect(connector.connection.closed, isFalse);
      expect(connector.calls, 1);
      expect(c.trustedKey, same(trustedKey));
      expect(c.network.inventory, same(inventory));
      c.lock();
      expect(c.serverName.text, isEmpty);
      await c.open();
      expect(c.serverName.text, 'Личный VPS');
      expect(c.settingsExpanded, isFalse);
      expect(c.saved, isTrue);
    },
  );

  for (final change in ['port', 'password', 'auth']) {
    test(
      'saving changed $change disconnects only after successful persistence',
      () async {
        final vault = FakeVault();
        final connector = FakeConnector();
        final c = controller(vault, connector);
        addTearDown(c.dispose);
        addTearDown(c.network.dispose);
        await prepare(c);
        final work = c.connect();
        await Future<void>.delayed(Duration.zero);
        c.decide(true);
        await work;
        final original = vault.saved;
        final inventory = c.network.inventory;
        c.editSettings();
        switch (change) {
          case 'port':
            c.port.text = '2222';
          case 'password':
            c.password.text = 'new-test-password-only';
          case 'auth':
            c.setAuth(SshAuthMethod.agent);
        }
        vault.failWrite = true;
        expect(await c.save(), isFalse);
        expect(c.settingsExpanded, isTrue);
        expect(c.vaultError, VaultIssue.writeFailed);
        expect(vault.saved, same(original));
        expect(connector.connection.closed, isFalse);
        expect(c.network.inventory, same(inventory));
        vault.failWrite = false;
        expect(await c.save(), isTrue);
        expect(c.settingsExpanded, isFalse);
        expect(c.stage, SshStage.idle);
        expect(connector.connection.closed, isTrue);
        expect(c.network.inventory, isNull);
        expect(c.observation, isNull);
        expect(c.trustedKey, same(original!.hostKey));
        connector.connection = FakeConnection();
        await c.connect();
        expect(c.stage, SshStage.connected);
        expect(c.settingsExpanded, isFalse);
      },
    );
  }

  test(
    'invalid edits stay open and do not replace the saved profile',
    () async {
      final vault = FakeVault();
      final c = controller(vault, FakeConnector());
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      await c.save();
      final original = vault.saved;
      c.editSettings();
      c.port.text = 'invalid';
      expect(await c.save(), isFalse);
      expect(c.settingsExpanded, isTrue);
      expect(c.error, SshIssue.invalidSettings);
      expect(vault.saved, same(original));
      c.cancelEditing();
      expect(c.port.text, '22');
      c.editSettings();
      c.serverName.text = 'invalid\nname';
      expect(await c.save(), isFalse);
      expect(vault.saved, same(original));
    },
  );

  test(
    'trust is persisted before auth; changed key stops auth after reconnect',
    () async {
      final vault = FakeVault();
      final connector = FakeConnector();
      final c = controller(vault, connector);
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      final work = c.connect();
      await Future<void>.delayed(Duration.zero);
      expect(c.stage, SshStage.verifying);
      expect(connector.authentications, 0);
      c.decide(true);
      await work;
      expect(vault.saved!.hostKey!.fingerprint, 'SHA256:fixture');
      expect(connector.authentications, 1);
      expect(c.stage, SshStage.connected);
      c.disconnect();
      connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:changed');
      await c.connect();
      expect(c.error, SshIssue.hostKeyChanged);
      expect(connector.authentications, 1);
    },
  );

  test('trust write failure prevents sending authentication', () async {
    final vault = FakeVault();
    final connector = FakeConnector();
    final c = controller(vault, connector);
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await prepare(c);
    final work = c.connect();
    await Future<void>.delayed(Duration.zero);
    vault.failWrite = true;
    c.decide(true);
    await work;
    expect(connector.authentications, 0);
    expect(c.error, SshIssue.trustSaveFailed);
  });

  test(
    'locking during fingerprint prompt cancels and clears every secret field',
    () async {
      final vault = FakeVault();
      final connector = FakeConnector();
      final c = controller(vault, connector);
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      final work = c.connect();
      await Future<void>.delayed(Duration.zero);
      c.lock();
      await work;
      expect(connector.authentications, 0);
      expect(c.challenge, isNull);
      expect(c.unlocked, isFalse);
      expect(c.password.text, isEmpty);
      expect(c.passphrase.text, isEmpty);
      expect(c.network.inventory, isNull);
      await c.open();
      expect(c.password.text, 'fixture-password-only');
    },
  );

  test(
    'picker cancellation and invalid public key preserve the previously imported key',
    () async {
      final picker = FakeKeyPicker();
      final vault = FakeVault();
      final c = controller(vault, FakeConnector(), picker: picker);
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      final bytes = Uint8List.fromList(
        utf8.encode(
          '-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----',
        ),
      );
      picker.callback = () async =>
          ImportedPrivateKey(name: 'id_ed25519', bytes: bytes);
      await c.importKey();
      expect(c.keyName, 'id_ed25519');
      expect(bytes.every((b) => b == 0), isTrue);
      picker.callback = () async => null;
      await c.importKey();
      expect(c.keyName, 'id_ed25519');
      picker.callback = () async => ImportedPrivateKey(
        name: 'id_ed25519.pub',
        bytes: Uint8List.fromList(utf8.encode('ssh-ed25519 public-test')),
      );
      await c.importKey();
      expect(c.error, SshIssue.invalidKey);
      expect(c.keyName, 'id_ed25519');
      await c.save();
      expect(
        vault.saved!.secrets[ServerSecret.privateKey],
        contains('BEGIN OPENSSH PRIVATE KEY'),
      );
      c.lock();
      expect(c.hasKey, isFalse);
      await c.open();
      expect(c.keyName, 'id_ed25519');
    },
  );

  test(
    'late key picker response after lock is erased and cannot unlock storage',
    () async {
      final picker = FakeKeyPicker();
      final pending = Completer<ImportedPrivateKey?>();
      picker.callback = () => pending.future;
      final c = controller(FakeVault(), FakeConnector(), picker: picker);
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      final work = c.importKey();
      c.lock();
      final bytes = Uint8List.fromList([1, 2, 3]);
      pending.complete(ImportedPrivateKey(name: 'private', bytes: bytes));
      await work;
      expect(c.hasKey, isFalse);
      expect(c.unlocked, isFalse);
      expect(bytes, [0, 0, 0]);
    },
  );

  test(
    'failed refresh retains inventory and selection; idle timeout closes SSH',
    () async {
      final connector = FakeConnector();
      final vault = FakeVault();
      final c = controller(
        vault,
        connector,
        idleTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      final work = c.connect();
      await Future<void>.delayed(Duration.zero);
      c.decide(true);
      await work;
      final inventory = c.network.inventory;
      c.network.select(
        AddressRole.listener,
        c.network.choices(AddressRole.listener).first,
      );
      final choice = c.network.selected(AddressRole.listener);
      connector.connection.reader = () async =>
          throw const SshFailure(SshIssue.commandFailed);
      await c.refresh();
      expect(c.network.inventory, same(inventory));
      expect(c.network.selected(AddressRole.listener), same(choice));
      expect(c.error, SshIssue.commandFailed);
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(c.unlocked, isFalse);
      expect(connector.connection.closed, isTrue);
      expect(c.password.text, isEmpty);
    },
  );
}
