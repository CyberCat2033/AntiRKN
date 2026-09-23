import 'dart:io';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'VPN entities, credentials and pending intent survive reopening encrypted with CAS',
    () async {
      final temp = await Directory.systemTemp.createTemp('vpn-storage-test-');
      addTearDown(() => temp.delete(recursive: true));
      final path = '${temp.path}/workspace.sqlite';
      WorkspaceDatabase open() => WorkspaceDatabase.open(
        path,
        key: SecretKeyData(List.generate(32, (i) => i)),
      );
      final first = open();
      await first.writeSetting('language', 'ru');
      await first.writeDraft('private-template-fixture');
      final initial = await first.readVpn();
      expect(initial.revision, 0);
      final workspace = VpnWorkspace(
        id: initial.workspaceId!,
        users: [
          VpnUser(
            id: 'b' * 32,
            login: 'private-client-login',
            name: 'Private customer',
          ),
        ],
        servers: {
          'one': {
            'pending': {'id': 'private-operation-fixture'},
            'observed': [
              {'uuid': 'private-credential-fixture'},
            ],
          },
        },
        profiles: {
          'b' * 32: {'yaml': 'private-personal-yaml'},
        },
      );
      expect(await first.writeVpn(workspace.encode(), expectedRevision: 0), 1);
      final second = open();
      final stored = VpnWorkspace.decode((await second.readVpn()).source!);
      expect(stored.users.single.id, workspace.users.single.id);
      expect(stored.users.single.login, workspace.users.single.login);
      expect(stored.users.single.name, workspace.users.single.name);
      expect(stored.servers['one']?['pending'], workspace.servers['one']?['pending']);
      expect(stored.servers['one']?['resourceWorkspaceId'], workspace.id);
      expect(stored.profiles['b' * 32]?['yaml'], 'private-personal-yaml');
      expect(stored.profiles['b' * 32]?['publicationWorkspaceId'], workspace.id);
      await first.writeVpn(
        workspace
            .copy(
              users: [VpnUser(id: 'b' * 32, login: 'renamed', name: 'Updated')],
            )
            .encode(),
        expectedRevision: 1,
      );
      await expectLater(
        second.writeVpn(workspace.encode(), expectedRevision: 1),
        throwsA(isA<VaultFailure>()),
      );
      expect(await second.readSetting('language'), 'ru');
      expect(await second.readDraft(), 'private-template-fixture');
      await first.close();
      await second.close();
      final bytes = await File(path).readAsBytes();
      final raw = latin1.decode(bytes);
      for (final secret in [
        'private-client-login',
        'Private customer',
        'private-operation-fixture',
        'private-credential-fixture',
        'private-personal-yaml',
      ]) {
        expect(raw, isNot(contains(secret)));
      }
      final db = sqlite3.open(path);
      db.execute('BEGIN IMMEDIATE');
      db.execute(
        'UPDATE sync_identity SET write_guard=1, writer_device=device_id, writer_version=5',
      );
      db.execute(
        "UPDATE documents SET payload=zeroblob(length(payload)) WHERE id='vpn-workspace-v1'",
      );
      db.execute('UPDATE sync_identity SET write_guard=0');
      db.execute('COMMIT');
      db.dispose();
      final corrupt = open();
      addTearDown(corrupt.close);
      await expectLater(corrupt.readVpn(), throwsA(isA<VaultFailure>()));
    },
  );
}
