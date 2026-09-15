import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

class _Files implements VaultFileStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? expected, String encoded) async {
    if (expected != value) throw const VaultFailure(VaultIssue.busy);
    value = encoded;
  }
}

class _Keys implements VaultKeyStore {
  final data = <String, String>{};
  @override
  Future<String?> read(String id) async => data[id];
  @override
  Future<void> write(String id, String value) async {
    data[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

SshProfile profile(String host, {String name = '', String? jump}) => SshProfile(
  host: host,
  port: 22,
  username: 'private-login-fixture',
  name: name,
  jumpServerId: jump,
  authMethod: SshAuthMethod.password,
  hostKey: TrustedHostKey('ssh-ed25519', 'SHA256:$host'),
  secrets: const {
    ServerSecret.sshPassword: 'private-password-fixture',
    ServerSecret.privateKey: 'private-key-fixture',
    ServerSecret.keyPassphrase: 'private-passphrase-fixture',
    ServerSecret.sudoPassword: 'private-sudo-fixture',
  },
);
void main() {
  late Directory directory;
  late String path;
  final databases = <WorkspaceDatabase>[];
  WorkspaceDatabase open({SecretVault? legacy}) {
    final db = WorkspaceDatabase.open(
      path,
      key: SecretKeyData(List.filled(32, 7)),
      legacy: legacy,
    );
    databases.add(db);
    return db;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('antirkn-database-test-');
    path = '${directory.path}/test.sqlite';
  });
  tearDown(() async {
    for (final db in databases) {
      await db.close();
    }
    databases.clear();
    await directory.delete(recursive: true);
  });

  test(
    'runner request and cursor survive restart encrypted and isolated by server',
    () async {
      final db = open();
      const source = '{"pending":"private-runner-fixture","cursor":12}';
      await db.writeRunnerJournal('one', source);
      await db.writeRunnerJournal('two', '{"cursor":3}');
      await db.close();
      expect(
        String.fromCharCodes(await File(path).readAsBytes()),
        isNot(contains('private-runner-fixture')),
      );
      final reopened = open();
      expect(await reopened.readRunnerJournal('one'), source);
      expect(await reopened.readRunnerJournal('two'), '{"cursor":3}');
      expect(await reopened.readRunnerJournal('absent'), isNull);
      expect(await reopened.readDraft(), isNull);
    },
  );

  test(
    'jump reference survives restart and deletion without losing the route',
    () async {
      final db = open();
      final a = db.newServerId(), b = db.newServerId();
      await (await db.openServer(a)).saveProfile(profile('jump.example'));
      await (await db.openServer(
        b,
      )).saveProfile(profile('target.example', jump: a));
      final restarted = open();
      final target = (await restarted.openServer(b)).profile!;
      expect(target.jumpServerId, a);
      expect(
        resolveSshRoute(
          target,
          (await restarted.listServers()).map((s) => s.profile),
        ).map((s) => s.id),
        [a, b],
      );
      await (await restarted.openServer(a)).saveProfile(null);
      final dangling = (await open().openServer(b)).profile!;
      expect(dangling.jumpServerId, a);
      expect(() => resolveSshRoute(dangling, []), throwsA(isA<SshFailure>()));
    },
  );

  test(
    'multiple servers, settings and encrypted template survive reopen; DB/WAL contain no credentials',
    () async {
      final db = open();
      final idA = db.newServerId(), idB = db.newServerId();
      final a = await db.openServer(idA), b = await db.openServer(idB);
      await a.saveProfile(profile('a.example', name: 'A'));
      await b.saveProfile(profile('b.example', name: 'B'));
      await db.writeLanguage(AppLanguage.ru);
      await db.writeSetting('theme', 'dark');
      await db.writeSetting('motion', 'off');
      await db.writeDraft('# private-template-fixture\nproxies: []');
      for (final file in directory.listSync().whereType<File>()) {
        final raw = String.fromCharCodes(await file.readAsBytes());
        for (final secret in [
          'private-login-fixture',
          'private-password-fixture',
          'private-key-fixture',
          'private-passphrase-fixture',
          'private-sudo-fixture',
          'private-template-fixture',
        ]) {
          expect(raw.contains(secret), isFalse, reason: secret);
        }
      }
      await db.close();
      final reopened = open();
      final records = await reopened.listServers();
      expect(records.map((e) => e.id).toSet(), {idA, idB});
      expect(records.map((e) => e.profile.id).toSet(), {idA, idB});
      expect(
        (await reopened.openServer(idA)).profile!.hostKey!.fingerprint,
        'SHA256:a.example',
      );
      expect(await reopened.readLanguage(), AppLanguage.ru);
      expect(await reopened.readSetting('theme'), 'dark');
      expect(await reopened.readSetting('motion'), 'off');
      expect(
        await reopened.readDraft(),
        '# private-template-fixture\nproxies: []',
      );
      expect(
        (await reopened.openServer(
          idA,
        )).profile!.secrets[ServerSecret.sudoPassword],
        'private-sudo-fixture',
      );
      expect(
        (await reopened.openServer(
          idA,
        )).profile!.secrets[ServerSecret.sshPassword],
        'private-password-fixture',
      );
      final editing = await reopened.openServer(idA);
      await editing.saveProfile(profile('a.example', name: 'Renamed'));
      expect(
        (await reopened.listServers())
            .firstWhere((e) => e.id == idA)
            .profile
            .name,
        'Renamed',
      );
      await editing.saveProfile(null);
      expect((await reopened.listServers()).single.id, idB);
    },
  );

  test(
    'last OS and software versions survive database restart without stale running state',
    () async {
      final db = open();
      final id = db.newServerId();
      final time = DateTime.utc(2026, 9, 13);
      await (await db.openServer(id)).saveProfile(
        profile('fixture.example').withInfo(
          ServerInfo(
            os: 'Ubuntu 24.04.3 LTS',
            architecture: 'x86_64',
            observedAt: time,
            software: ServerSoftwareInventory(
              observedAt: time,
              facts: const {},
              sockets: const [],
              components: [
                ComponentObservation(
                  component: VpnComponent.amneziaWg,
                  presence: ComponentPresence.detected,
                  issues: const [],
                  installations: const [
                    ComponentInstallation(
                      source: InstallationSource.binary,
                      identity: '/usr/bin/awg',
                      version: InventoryValue.ok('3.1.20260812'),
                    ),
                    ComponentInstallation(
                      source: InstallationSource.docker,
                      identity: 'amnezia-awg2',
                      state: ServiceState.running,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await db.close();
      final saved = (await open().listServers()).single.profile.lastInfo!;
      expect(saved.os, 'Ubuntu 24.04.3 LTS');
      expect(saved.observedAt, time);
      expect(
        saved.software!.components.single.installations.first.version!.value,
        '3.1.20260812',
      );
      expect(
        saved.software!.components.single.installations.last.state,
        ServiceState.unknown,
      );
    },
  );

  test(
    'stale writers and deleted records cannot overwrite newer credentials or resurrect a server',
    () async {
      final db = open(), other = open();
      final id = db.newServerId();
      await (await db.openServer(id)).saveProfile(profile('a.example'));
      final first = await db.openServer(id), stale = await other.openServer(id);
      await first.saveProfile(profile('new.example'));
      await expectLater(
        stale.saveProfile(profile('stale.example')),
        throwsA(isA<VaultFailure>()),
      );
      await first.saveProfile(null);
      await expectLater(
        stale.saveProfile(profile('stale.example')),
        throwsA(isA<VaultFailure>()),
      );
      expect(await db.listServers(), isEmpty);
    },
  );

  test('failed transaction keeps old profile and its trusted host key', () async {
    final db = open();
    final id = db.newServerId();
    final store = await db.openServer(id);
    await store.saveProfile(profile('a.example'));
    final raw = sqlite3.open(path);
    raw.execute(
      "CREATE TRIGGER reject_update BEFORE UPDATE ON servers BEGIN SELECT RAISE(ABORT, 'fixture'); END",
    );
    raw.dispose();
    await expectLater(
      store.saveProfile(profile('b.example')),
      throwsA(anything),
    );
    expect(store.profile!.host, 'a.example');
    expect(
      (await db.listServers()).single.profile.hostKey!.fingerprint,
      'SHA256:a.example',
    );
  });

  test(
    'authentication binds encrypted payload to the server ID and revision',
    () async {
      final db = open();
      final a = db.newServerId(), b = db.newServerId();
      await (await db.openServer(a)).saveProfile(profile('a.example'));
      await (await db.openServer(b)).saveProfile(profile('b.example'));
      final raw = sqlite3.open(path);
      // Deliberate tampering bypasses the guard against old application writers.
      raw.execute('BEGIN IMMEDIATE');
      raw.execute(
        'UPDATE sync_identity SET write_guard=1, writer_device=device_id',
      );
      raw.execute(
        'UPDATE servers SET payload = (SELECT payload FROM servers WHERE id = ?) WHERE id = ?',
        [a, b],
      );
      raw.execute('UPDATE sync_identity SET write_guard=0');
      raw.execute('COMMIT');
      raw.dispose();
      await expectLater(db.listServers(), throwsA(isA<VaultFailure>()));
      expect((await db.openServer(a)).profile!.host, 'a.example');
    },
  );

  for (final mode in VaultMode.values) {
    test(
      'legacy $mode migration is atomic, repeatable and keeps old encrypted file',
      () async {
        final files = _Files(), keys = _Keys();
        final legacy = EncryptedSecretVault(files: files, keys: keys);
        const password = 'fixture-master-password';
        await legacy.create(mode, password: password);
        await legacy.saveProfile(profile('legacy.example', name: 'Old server'));
        legacy.lock();
        final original = files.value;
        final db = open(legacy: legacy);
        await db.inspectLegacy();
        if (mode == VaultMode.masterPassword) {
          expect(db.needsLegacyPassword, isTrue);
          await expectLater(
            db.migrateLegacy(password: 'incorrect'),
            throwsA(isA<VaultFailure>()),
          );
          expect(await db.listServers(), isEmpty);
        }
        await db.migrateLegacy(password: password);
        final migrated = (await db.listServers()).single;
        expect(migrated.profile.name, 'Old server');
        expect(migrated.profile.secrets, profile('legacy.example').secrets);
        expect(migrated.profile.hostKey!.fingerprint, 'SHA256:legacy.example');
        expect(db.needsLegacyPassword, isFalse);
        await db.migrateLegacy(password: password);
        expect((await db.listServers()).single.id, migrated.id);
        final handle = await db.openServer(migrated.id);
        await handle.saveProfile(null);
        await db.close();
        final reopened = open(legacy: legacy);
        await reopened.inspectLegacy();
        expect(await reopened.listServers(), isEmpty);
        expect(files.value, original);
      },
    );
  }

  test(
    'migration rollback cannot leave an imported server without its marker',
    () async {
      final legacy = EncryptedSecretVault(files: _Files(), keys: _Keys());
      await legacy.create(VaultMode.system);
      await legacy.saveProfile(profile('legacy.example'));
      legacy.lock();
      final db = open(legacy: legacy);
      final raw = sqlite3.open(path);
      raw.execute(
        "CREATE TRIGGER reject_marker BEFORE INSERT ON migrations BEGIN SELECT RAISE(ABORT, 'fixture'); END",
      );
      await expectLater(db.migrateLegacy(), throwsA(anything));
      expect(await db.listServers(), isEmpty);
      raw.execute('DROP TRIGGER reject_marker');
      raw.dispose();
      await db.migrateLegacy();
      expect((await db.listServers()).single.profile.host, 'legacy.example');
    },
  );

  test('future schema is rejected without changing its version', () async {
    final raw = sqlite3.open(path);
    raw.userVersion = 99;
    raw.dispose();
    expect(open, throwsA(isA<VaultFailure>()));
    final after = sqlite3.open(path);
    expect(after.userVersion, 99);
    after.dispose();
  });

  test('oversized template does not replace the saved draft', () async {
    final db = open();
    await db.writeDraft('saved');
    await expectLater(
      db.writeDraft('x' * (256 * 1024 + 1)),
      throwsA(isA<VaultFailure>()),
    );
    expect(await db.readDraft(), 'saved');
  });
}
