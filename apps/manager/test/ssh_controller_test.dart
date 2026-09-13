import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ssh_support.dart';

void main() {
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
