import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class TestKeys implements VaultKeyStore {
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    if (fail) throw StateError('unavailable');
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

class TestFiles implements VaultFileStore {
  String? value;
  bool fail = false;
  Completer<void>? pending;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? expected, String encoded) async {
    if (pending != null) await pending!.future;
    if (fail) throw const VaultFailure(VaultIssue.writeFailed);
    if (value != expected) throw const VaultFailure(VaultIssue.busy);
    value = encoded;
  }
}

final sample = SshProfile(
  host: 'unit-test.example',
  port: 22,
  username: 'test-user',
  authMethod: SshAuthMethod.password,
  keyName: 'private-file',
  secrets: {
    ServerSecret.sshPassword: 'ssh-only-test-secret',
    ServerSecret.privateKey: 'key-only-test-secret',
    ServerSecret.keyPassphrase: 'passphrase-only-test-secret',
    ServerSecret.sudoPassword: 'sudo-only-test-secret',
    ServerSecret.rootPassword: 'root-only-test-secret',
  },
  hostKey: const TrustedHostKey('ssh-ed25519', 'SHA256:test-fingerprint'),
);

Matcher issue(VaultIssue issue) =>
    isA<VaultFailure>().having((e) => e.issue, 'issue', issue);

void main() {
  test(
    'master vault survives a new instance and stores only ciphertext on disk',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'antirkn-vault-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/vault.json');
      final files = LocalVaultFileStore(file);
      final keys = TestKeys();
      final first = EncryptedSecretVault(files: files, keys: keys);
      const password = 'master-password-test-only';
      await first.create(VaultMode.masterPassword, password: password);
      await first.saveProfile(sample);
      final encrypted = await file.readAsString();
      for (final secret in [
        password,
        sample.host,
        sample.username,
        ...sample.secrets.values,
      ]) {
        expect(encrypted.contains(secret), isFalse);
      }
      expect(keys.values, isEmpty);
      first.lock();
      expect(() => first.profile, throwsA(issue(VaultIssue.locked)));
      final second = EncryptedSecretVault(files: files, keys: keys);
      expect(await second.inspect(), VaultMode.masterPassword);
      await expectLater(
        second.unlock(password: 'incorrect-test-password'),
        throwsA(issue(VaultIssue.incorrectPasswordOrDamaged)),
      );
      expect(await file.readAsString(), encrypted);
      expect(second.isUnlocked, isFalse);
      await second.unlock(password: password);
      expect(second.profile!.secrets, sample.secrets);
      expect(second.profile!.hostKey!.fingerprint, sample.hostKey!.fingerprint);
      await second.saveProfile(null);
      second.lock();
      await second.unlock(password: password);
      expect(second.profile, isNull);
      second.lock();
    },
  );

  test(
    'system vault separates OS key from encrypted profile and restores secrets',
    () async {
      final files = TestFiles();
      final keys = TestKeys();
      final vault = EncryptedSecretVault(files: files, keys: keys);
      await vault.create(VaultMode.system);
      await vault.saveProfile(sample);
      expect(keys.values.length, 1);
      expect(files.value!.contains(keys.values.values.single), isFalse);
      vault.lock();
      final restored = EncryptedSecretVault(files: files, keys: keys);
      await restored.unlock();
      expect(restored.profile!.secrets, sample.secrets);
      restored.lock();
      keys.values.clear();
      final unchanged = files.value;
      await expectLater(
        restored.unlock(),
        throwsA(issue(VaultIssue.missingKey)),
      );
      await expectLater(
        restored.create(VaultMode.system),
        throwsA(issue(VaultIssue.alreadyExists)),
      );
      expect(files.value, unchanged);
    },
  );

  test(
    'ciphertext, nonce and authenticated metadata tampering fail closed',
    () async {
      final files = TestFiles();
      final keys = TestKeys();
      final vault = EncryptedSecretVault(files: files, keys: keys);
      await vault.create(VaultMode.system);
      await vault.saveProfile(sample);
      vault.lock();
      final original = files.value!;
      for (final field in ['ciphertext', 'nonce', 'mac', 'salt']) {
        final envelope = jsonDecode(original) as Map<String, dynamic>;
        final bytes = base64Decode(envelope[field] as String);
        bytes[0] ^= 1;
        envelope[field] = base64Encode(bytes);
        files.value = jsonEncode(envelope);
        await expectLater(
          vault.unlock(),
          throwsA(issue(VaultIssue.incorrectPasswordOrDamaged)),
        );
        expect(vault.isUnlocked, isFalse);
        expect(files.value, jsonEncode(envelope));
      }
      files.value = original;
      await vault.unlock();
      expect(vault.profile!.secrets, sample.secrets);
      vault.lock();
    },
  );

  test(
    'failed persistence keeps last committed credentials and allows retry',
    () async {
      final files = TestFiles();
      final vault = EncryptedSecretVault(files: files, keys: TestKeys());
      await vault.create(VaultMode.system);
      await vault.saveProfile(sample);
      final previous = files.value;
      files.fail = true;
      await expectLater(
        vault.saveProfile(null),
        throwsA(issue(VaultIssue.writeFailed)),
      );
      expect(vault.profile, same(sample));
      expect(files.value, previous);
      files.fail = false;
      await vault.saveProfile(null);
      expect(vault.profile, isNull);
      vault.lock();
    },
  );

  test(
    'concurrent app instances cannot silently overwrite newer server trust',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'antirkn-vault-cas-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final files = LocalVaultFileStore(File('${directory.path}/vault.json'));
      final keys = TestKeys();
      final first = EncryptedSecretVault(files: files, keys: keys);
      final second = EncryptedSecretVault(files: files, keys: keys);
      await first.create(VaultMode.system);
      await second.unlock();
      await first.saveProfile(sample);
      await expectLater(
        second.saveProfile(null),
        throwsA(issue(VaultIssue.busy)),
      );
      second.lock();
      await second.unlock();
      expect(second.profile!.hostKey!.fingerprint, sample.hostKey!.fingerprint);
      first.lock();
      second.lock();
    },
  );

  test('lock during a pending save never restores decrypted state', () async {
    final files = TestFiles();
    final vault = EncryptedSecretVault(files: files, keys: TestKeys());
    await vault.create(VaultMode.system);
    files.pending = Completer<void>();
    final operation = vault.saveProfile(sample);
    final expectation = expectLater(
      operation,
      throwsA(issue(VaultIssue.locked)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    vault.lock();
    files.pending!.complete();
    await expectation;
    expect(vault.isUnlocked, isFalse);
    expect(() => vault.profile, throwsA(issue(VaultIssue.locked)));
  });

  test(
    'unavailable keyring cannot create plaintext or overwrite an existing file',
    () async {
      final files = TestFiles();
      final vault = EncryptedSecretVault(
        files: files,
        keys: TestKeys()..fail = true,
      );
      await expectLater(
        vault.create(VaultMode.system),
        throwsA(issue(VaultIssue.unavailable)),
      );
      expect(files.value, isNull);
      expect(vault.isUnlocked, isFalse);
      files.value = 'damaged';
      await expectLater(vault.inspect(), throwsA(issue(VaultIssue.corrupt)));
      expect(files.value, 'damaged');
    },
  );

  test(
    'master password requirements are enforced before creating a file',
    () async {
      final files = TestFiles();
      final vault = EncryptedSecretVault(files: files, keys: TestKeys());
      await expectLater(
        vault.create(VaultMode.masterPassword, password: 'short'),
        throwsA(issue(VaultIssue.weakPassword)),
      );
      expect(files.value, isNull);
    },
  );
}
