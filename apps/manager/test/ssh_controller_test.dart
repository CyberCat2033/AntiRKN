import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

import 'ssh_support.dart';
import 'network_support.dart';
import 'runner_support.dart';

void main() {
  test(
    'unexpected disconnect reconnects an active job without resubmission',
    () async {
      final vault = FakeVault(), connector = FakeConnector();
      final c = controller(
        vault,
        connector,
        reconnectDelay: (_) => Duration.zero,
      );
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      await c.save();
      vault.saved = vault.saved!.withHostKey(connector.key);
      await c.connect();
      c.runner.selected = runnerJob('a' * 32);
      final previous = connector.connection;
      connector.connection = FakeConnection();
      previous.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connector.calls, 2);
      expect(c.stage, SshStage.connected);
      expect(c.runner.selected!.id, 'a' * 32);
    },
  );

  test('a lost connection is tried again before the settings', () async {
    final vault = FakeVault(), connector = FakeConnector();
    final c = controller(vault, connector);
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await prepare(c);
    expect(await c.reconnect(), isFalse); // Nothing was lost yet.
    await c.save();
    vault.saved = vault.saved!.withHostKey(connector.key);
    await c.connect();
    var previous = connector.connection;
    connector.connection = FakeConnection();
    previous.close();
    await Future<void>.delayed(Duration.zero);
    expect(c.error, SshIssue.disconnected);
    expect(connector.calls, 1); // No job: no automatic reconnect.
    expect(await c.reconnect(), isTrue);
    expect(c.stage, SshStage.connected);
    expect(c.error, isNull);
    expect(connector.calls, 2);
    // A failed attempt is reported, and the notice then opens the settings.
    previous = connector.connection;
    connector.connection = FakeConnection();
    connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:changed');
    previous.close();
    await Future<void>.delayed(Duration.zero);
    expect(await c.reconnect(), isFalse);
    expect(c.error, SshIssue.hostKeyChanged);
    expect(await c.reconnect(), isFalse); // Not a connection to retry.
    expect(connector.calls, 3);
  });

  test('manual disconnect cancels active-job reconnect', () async {
    final vault = FakeVault(), connector = FakeConnector();
    final c = controller(
      vault,
      connector,
      reconnectDelay: (_) => const Duration(milliseconds: 30),
    );
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await prepare(c);
    await c.save();
    vault.saved = vault.saved!.withHostKey(connector.key);
    await c.connect();
    c.runner.selected = runnerJob('a' * 32);
    connector.connection.close();
    await Future<void>.delayed(Duration.zero);
    c.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(connector.calls, 1);
    expect(c.stage, SshStage.idle);
  });

  test('automatic reconnect stops on a changed host key', () async {
    final vault = FakeVault(), connector = FakeConnector();
    final c = controller(
      vault,
      connector,
      reconnectDelay: (_) => Duration.zero,
    );
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await prepare(c);
    await c.save();
    vault.saved = vault.saved!.withHostKey(connector.key);
    await c.connect();
    c.runner.selected = runnerJob('a' * 32);
    final previous = connector.connection;
    connector.connection = FakeConnection();
    connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:changed');
    previous.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.error, SshIssue.hostKeyChanged);
    expect(connector.calls, 2);
    expect(connector.authentications, 1);
  });

  test(
    'unchanged profile stays saved after focus, edits reverted, and connect',
    () async {
      final vault = FakeVault();
      final connector = FakeConnector();
      final c = controller(vault, connector);
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      await c.save();
      c.editSettings();
      c.host.selection = const TextSelection.collapsed(offset: 2);
      expect(c.saved, isTrue);
      c.serverName.text = 'changed';
      expect(c.saved, isFalse);
      c.serverName.clear();
      expect(c.saved, isTrue);
      final writes = vault.writes;
      await c.save();
      expect(vault.writes, writes);
      vault.saved = vault.saved!.withHostKey(connector.key);
      final work = c.connect();
      await Future<void>.delayed(Duration.zero);
      await work;
      // Only the new observation is written, not another unchanged SSH draft.
      expect(vault.writes, writes + 1);
      expect(c.saved, isTrue);
      expect(c.lastInfo!.os, 'Ubuntu 24.04');
      c.disconnect();
      c.lock();
      await c.initialise();
      expect(c.os, 'Ubuntu 24.04');
      c.editSettings();
      c.host.text = 'another.example';
      await c.save();
      expect(c.lastInfo, isNull);
    },
  );

  test(
    'stuck key import can be cancelled and late result cannot overwrite a retry',
    () async {
      final picker = FakeKeyPicker();
      final pending = Completer<ImportedPrivateKey?>();
      picker.callback = () => pending.future;
      final c = controller(FakeVault(), FakeConnector(), picker: picker);
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      await prepare(c);
      final work = c.importKey();
      expect(c.editing, isFalse);
      c.cancelKeyImport();
      await work;
      expect(c.editing, isTrue);
      picker.callback = () async => ImportedPrivateKey(
        name: 'new-key',
        bytes: Uint8List.fromList(
          utf8.encode(
            '-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----',
          ),
        ),
      );
      await c.importKey();
      final old = Uint8List.fromList([1, 2, 3]);
      final oldKey = ImportedPrivateKey(name: 'old-key', bytes: old);
      pending.complete(oldKey);
      await Future<void>.delayed(Duration.zero);
      expect(oldKey.bytes, [0, 0, 0]);
      expect(c.keyName, 'new-key');
      expect(c.editing, isTrue);
    },
  );
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
            ServerFact.networkTraffic: const InventoryValue.ok(
              '11111111-1111-1111-1111-111111111111\neth0 1024 2048',
            ),
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
      await c.initialise();
      expect(c.observation, isNull);
      expect(c.software!.facts[ServerFact.freeDiskKiB]!.value, '1234');
      expect(c.trafficBytes, (1024, 2048));
      expect(
        c.lastInfo!.publicAddresses!.map((ip) => ip.canonical),
        contains('93.184.215.15'),
      );
      c.host.text = 'new-host.example';
      await c.save();
      expect(c.trafficBytes, isNull);
      expect(c.lastInfo, isNull);
    },
  );

  for (final saveFirst in [false, true]) {
    test(
      'changing host trusts its own key, not the old one (save first: $saveFirst)',
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
          await c.initialise();
        }
        connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:second');
        connector.connection = FakeConnection();
        await c.connect();
        expect(c.challenge, isNull);
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
      await c.initialise();
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

  test('first key is trusted without a prompt and persisted before auth; '
      'a changed key still stops auth', () async {
    final vault = FakeVault();
    final connector = FakeConnector();
    final c = controller(vault, connector);
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await prepare(c);
    await c.save();
    expect(vault.saved!.hostKey, isNull);
    final gate = vault.writeGate = Completer<void>();
    final work = c.connect();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    // Waiting for the trust write, not for the person.
    expect(c.stage, SshStage.connecting);
    expect(c.challenge, isNull);
    expect(connector.authentications, 0);
    vault.writeGate = null;
    gate.complete();
    await work;
    expect(vault.saved!.hostKey!.fingerprint, 'SHA256:fixture');
    expect(c.trustedKey!.fingerprint, 'SHA256:fixture');
    expect(connector.authentications, 1);
    expect(c.stage, SshStage.connected);
    c.disconnect();
    connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:changed');
    connector.connection = FakeConnection();
    await c.connect();
    expect(c.error, SshIssue.hostKeyChanged);
    expect(c.challenge, isNull);
    expect(c.stage, SshStage.idle);
    expect(vault.saved!.hostKey!.fingerprint, 'SHA256:fixture');
    expect(connector.authentications, 1);
  });

  test('a background connection never trusts a first key', () async {
    final vault = FakeVault();
    final connector = FakeConnector();
    final c = controller(vault, connector);
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await prepare(c);
    await c.save();
    expect(await c.connectForDeletion(), isFalse);
    expect(vault.saved!.hostKey, isNull);
    expect(connector.authentications, 0);
  });

  test('actions and refreshes never trust a first key; Connect does', () async {
    final vault = FakeVault();
    final connector = FakeConnector();
    final c = controller(vault, connector);
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await prepare(c);
    await c.save();
    expect(await c.ensureConnected(), isFalse);
    expect(connector.calls, 0);
    expect(vault.saved!.hostKey, isNull);
    expect(c.stage, SshStage.idle);
    await c.connect();
    expect(c.stage, SshStage.connected);
    expect(vault.saved!.hostKey!.fingerprint, 'SHA256:fixture');
    c.disconnect();
    // Once pinned, an action may reconnect by itself.
    connector.connection = FakeConnection();
    await c.ensureConnected();
    expect(connector.calls, 2);
    expect(c.stage, SshStage.connected);
  });

  test('an action waits for a connection already in progress', () async {
    final vault = FakeVault();
    final connector = FakeConnector();
    final c = controller(vault, connector);
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await prepare(c);
    await c.connect();
    c.disconnect();
    connector.connection = FakeConnection();
    final gate = connector.hold = Completer<void>();
    final first = c.ensureConnected();
    await pumpEventQueue();
    expect(c.busy, isTrue);
    // A second caller (the re-read after a cloud pull) used to give up here.
    var secondDone = false;
    final second = c.ensureConnected().whenComplete(() => secondDone = true);
    await pumpEventQueue();
    expect(secondDone, isFalse);
    gate.complete();
    await first;
    await second;
    expect(c.stage, SshStage.connected);
    // The second caller joined the first connection instead of a new one.
    expect(connector.calls, 2);
  });

  for (final edit in [
    'FIXTURE.Example',
    'fixture.example.',
    ' Fixture.EXAMPLE. ',
  ]) {
    test(
      'a case or trailing-dot edit of the host keeps the pin: "$edit"',
      () async {
        final vault = FakeVault();
        final connector = FakeConnector();
        final c = controller(vault, connector);
        addTearDown(c.dispose);
        addTearDown(c.network.dispose);
        await prepare(c);
        await c.connect();
        final pinned = vault.saved!.hostKey;
        c.disconnect();
        c.editSettings();
        c.host.text = edit;
        expect(c.trustedKey, same(pinned));
        expect(await c.save(), isTrue);
        expect(vault.saved!.hostKey, same(pinned));
        connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:rotated');
        connector.connection = FakeConnection();
        await c.connect();
        expect(c.error, SshIssue.hostKeyChanged);
        expect(vault.saved!.hostKey, same(pinned));
        expect(connector.authentications, 1);
      },
    );
  }

  test('trust write failure prevents sending authentication', () async {
    final vault = FakeVault();
    final connector = FakeConnector();
    final c = controller(vault, connector);
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await prepare(c);
    await c.save();
    vault.failWrite = true;
    await c.connect();
    expect(connector.authentications, 0);
    expect(c.error, SshIssue.trustSaveFailed);
    expect(vault.saved!.hostKey, isNull);
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
      await c.connect();
      c.disconnect();
      connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:second');
      connector.connection = FakeConnection();
      await c.connect();
      expect(c.error, SshIssue.hostKeyChanged);
      final work = c.replaceServer();
      await Future<void>.delayed(Duration.zero);
      expect(c.challenge!.fingerprint, 'SHA256:second');
      c.lock();
      await work;
      expect(connector.authentications, 1);
      expect(vault.saved!.hostKey!.fingerprint, 'SHA256:fixture');
      expect(c.challenge, isNull);
      expect(c.unlocked, isFalse);
      expect(c.password.text, isEmpty);
      expect(c.passphrase.text, isEmpty);
      expect(c.network.inventory, isNull);
      await c.initialise();
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
      final imported = ImportedPrivateKey(
        name: 'id_ed25519',
        bytes: bytes.asUnmodifiableView(),
      );
      picker.callback = () async => imported;
      await c.importKey();
      expect(c.keyName, 'id_ed25519');
      expect(imported.bytes.every((b) => b == 0), isTrue);
      expect(c.picking, isFalse);
      expect(c.editing, isTrue);
      expect(c.error, isNull);
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
      await c.initialise();
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
      final imported = ImportedPrivateKey(
        name: 'private',
        bytes: bytes.asUnmodifiableView(),
      );
      pending.complete(imported);
      await work;
      await Future<void>.delayed(Duration.zero);
      expect(c.hasKey, isFalse);
      expect(c.unlocked, isFalse);
      expect(imported.bytes, [0, 0, 0]);
    },
  );

  test(
    'failed refresh retains inventory, selection and accessible credentials',
    () async {
      final connector = FakeConnector();
      final vault = FakeVault();
      final c = controller(vault, connector);
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
      expect(c.unlocked, isTrue);
      expect(connector.connection.closed, isTrue);
      expect(c.password.text, 'fixture-password-only');
    },
  );
}
