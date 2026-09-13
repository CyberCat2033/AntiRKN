// Native plugin smoke using temporary vaults and synthetic credentials only.
import 'dart:convert';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('AntiRKN · Storage check'))),
    ),
  );
  final results = <String, String>{};
  for (final mode in VaultMode.values) {
    final directory = await Directory.systemTemp.createTemp(
      'antirkn-platform-vault-',
    );
    final file = File('${directory.path}/vault.json');
    const keys = PlatformVaultKeyStore();
    final files = LocalVaultFileStore(file);
    final first = EncryptedSecretVault(files: files, keys: keys);
    final second = EncryptedSecretVault(files: files, keys: keys);
    String? keyId;
    const password = 'platform-master-test-only';
    try {
      await first.create(mode, password: password);
      keyId =
          (jsonDecode(await file.readAsString()) as Map<String, dynamic>)['id']
              as String;
      await first.saveProfile(
        SshProfile(
          host: 'platform-smoke.invalid',
          port: 22,
          username: 'test-only',
          authMethod: SshAuthMethod.password,
          secrets: {ServerSecret.sshPassword: 'platform-smoke-test-only'},
        ),
      );
      first.lock();
      await second.unlock(password: password);
      if (second.profile!.secrets[ServerSecret.sshPassword] !=
          'platform-smoke-test-only') {
        throw StateError('Mismatch');
      }
      if ((await file.readAsString()).contains('platform-smoke-test-only')) {
        throw StateError('Plaintext');
      }
      await second.saveProfile(null);
      second.lock();
      results[mode.name] = 'PASS';
    } on VaultFailure catch (e) {
      results[mode.name] = e.issue.name;
    } catch (_) {
      results[mode.name] = 'unexpected';
    } finally {
      first.lock();
      second.lock();
      try {
        if (mode == VaultMode.system && keyId != null) await keys.delete(keyId);
      } catch (_) {
        results[mode.name] = 'cleanup_failed';
      }
      await directory.delete(recursive: true);
    }
  }
  stdout.writeln('VAULT_PLATFORM_SMOKE=${jsonEncode(results)}');
  exit(results['masterPassword'] == 'PASS' ? 0 : 1);
}
