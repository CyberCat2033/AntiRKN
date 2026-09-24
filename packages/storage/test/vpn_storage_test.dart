import 'dart:io';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  for (final offload in [false, true]) {
    test(
      'VPN entities and pending intent survive encrypted with CAS (offload=$offload)',
      () async {
        final temp = await Directory.systemTemp.createTemp('vpn-storage-test-');
        addTearDown(() => temp.delete(recursive: true));
        final path = '${temp.path}/workspace.sqlite';
        WorkspaceDatabase open() => WorkspaceDatabase.open(
          path,
          key: SecretKeyData(List.generate(32, (i) => i)),
          offloadVpnWrites: offload,
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
        expect(
          await first.writeVpn(workspace.encode(), expectedRevision: 0),
          1,
        );
        final second = open();
        final stored = VpnWorkspace.decode((await second.readVpn()).source!);
        expect(stored.users.single.id, workspace.users.single.id);
        expect(stored.users.single.login, workspace.users.single.login);
        expect(stored.users.single.name, workspace.users.single.name);
        expect(
          stored.servers['one']?['pending'],
          workspace.servers['one']?['pending'],
        );
        expect(stored.servers['one']?['resourceWorkspaceId'], workspace.id);
        expect(stored.profiles['b' * 32]?['yaml'], 'private-personal-yaml');
        expect(
          stored.profiles['b' * 32]?['publicationWorkspaceId'],
          workspace.id,
        );
        final previousSequence =
            (await first.readChanges()).last.header.sequence;
        await first.upsertVpnUser(
          VpnUser(id: 'b' * 32, login: 'renamed', name: 'Updated'),
          expectedRevision: 1,
        );
        final userChanges = await first.readChanges(
          afterSequence: previousSequence,
        );
        expect(userChanges.map((change) => change.header.entityKind), [
          ChangeEntityKind.vpnUser,
        ]);
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

  test('offloaded VPN write keeps the caller isolate responsive', () async {
    final temp = await Directory.systemTemp.createTemp('vpn-offload-test-');
    addTearDown(() => temp.delete(recursive: true));
    final db = WorkspaceDatabase.open(
      '${temp.path}/workspace.sqlite',
      key: SecretKeyData(List.generate(32, (i) => i)),
      offloadVpnWrites: true,
    );
    addTearDown(db.close);
    final identity = await db.readWorkspaceIdentity();
    final workspace = VpnWorkspace(
      id: identity.workspaceId,
      users: [
        for (var i = 0; i < 600; i++)
          VpnUser(
            id: i.toRadixString(16).padLeft(32, '0'),
            login: 'client-$i',
            name: 'Client $i',
          ),
      ],
    );
    var writeFinished = false;
    final change = db.localChanges.first.timeout(const Duration(seconds: 5));
    final write = db.writeVpnWorkspace(workspace, expectedRevision: 0);
    write.then((_) => writeFinished = true);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(writeFinished, isFalse);
    expect(await write, 1);
    await change;
    expect((await db.readVpn()).revision, 1);
    expect((await db.readChanges(limit: 1000)).length, greaterThan(600));
  });

  test('user patch preserves order and journals only that user', () async {
    final temp = await Directory.systemTemp.createTemp('vpn-user-patch-test-');
    addTearDown(() => temp.delete(recursive: true));
    final db = WorkspaceDatabase.open(
      '${temp.path}/workspace.sqlite',
      key: SecretKeyData(List.generate(32, (i) => i)),
      offloadVpnWrites: true,
    );
    addTearDown(db.close);
    final identity = await db.readWorkspaceIdentity();
    final firstId = 'a' * 32;
    final secondId = 'b' * 32;
    await db.writeVpnWorkspace(
      VpnWorkspace(
        id: identity.workspaceId,
        users: [
          VpnUser(id: firstId, login: 'first', name: 'First'),
          VpnUser(id: secondId, login: 'second', name: 'Second'),
        ],
      ),
      expectedRevision: 0,
    );
    final sequence = (await db.readChanges()).last.header.sequence;
    expect(
      await db.upsertVpnUser(
        VpnUser(id: firstId, login: 'first', name: 'Renamed'),
        expectedRevision: 1,
      ),
      2,
    );
    final saved = VpnWorkspace.decode((await db.readVpn()).source!);
    expect(saved.users.map((user) => user.id), [firstId, secondId]);
    expect(saved.users.first.name, 'Renamed');
    expect(
      (await db.readChanges(afterSequence: sequence)).map(
        (change) => change.header.entityKind,
      ),
      [ChangeEntityKind.vpnUser],
    );
    await expectLater(
      db.upsertVpnUser(
        VpnUser(id: firstId, login: 'second', name: 'Duplicate login'),
        expectedRevision: 2,
      ),
      throwsA(isA<FormatException>()),
    );
    expect((await db.readVpn()).revision, 2);
  });
}
