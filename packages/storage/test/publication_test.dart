import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

const settings =
    '{"version":1,"accountKey":"fixture-account","folderId":"private-folder-fixture","folderName":"Fixture","access":"link","enabled":true,"folderReady":true}';
void main() {
  late Directory dir;
  late WorkspaceDatabase db;
  final user = '1' * 32;
  SecretKeyData key() => SecretKeyData(List.filled(32, 37));
  Future<void> profile(String yaml) async {
    final before = await db.readVpn();
    final workspace = before.source == null
        ? VpnWorkspace(
            id: (await db.readWorkspaceIdentity()).workspaceId,
            users: [VpnUser(id: user, login: 'fixture', name: 'Fixture')],
          )
        : VpnWorkspace.decode(before.source!);
    final hash = (await Sha256().hash(
      utf8.encode(yaml),
    )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    await db.writeVpn(
      workspace
          .copy(
            profiles: {
              user: {'yaml': yaml, 'hash': hash},
            },
          )
          .encode(),
      expectedRevision: before.revision,
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('publication-store-');
    db = WorkspaceDatabase.open('${dir.path}/a.sqlite', key: key());
    await profile('mode: rule\n# private-profile-fixture');
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  test(
    'encrypted queue survives reopen without journal events; stale writer rejected',
    () async {
      final draft = (await db.readPublicationDraft(user))!;
      final count = (await db.readChanges()).length;
      const queue =
          '{"status":"waiting","fileId":"private-file-fixture","retryAt":12345}';
      await db.writePublicationQueue(user, queue, expectedSource: null);
      expect((await db.readChanges()).length, count);
      await db.checkPublicationDraft(draft);
      final encrypted = await File(
        '${dir.path}/a.sqlite.publication-$user.json',
      ).readAsString();
      expect(encrypted, isNot(contains('private-file-fixture')));
      await db.close();
      db = WorkspaceDatabase.open('${dir.path}/a.sqlite', key: key());
      expect(await db.readPublicationQueue(user), queue);
      await expectLater(
        db.writePublicationQueue(user, '{}', expectedSource: null),
        throwsA(isA<SyncMergeFailure>()),
      );
    },
  );
  test(
    'draft follows causal profile heads and input edits invalidate pending effects',
    () async {
      final one = (await db.readPublicationDraft(user))!;
      await db.writePublicationDocument(
        'settings',
        settings,
        expectedSource: null,
      );
      await db.checkPublicationDraft(one);
      await profile('mode: global\n# newer-profile-fixture');
      final two = (await db.readPublicationDraft(user))!;
      expect(two.ancestors, contains(one.headId));
      expect(two.headId, isNot(one.headId));
      await expectLater(
        db.checkPublicationDraft(one),
        throwsA(isA<SyncMergeFailure>()),
      );
      await db.writeDraft('changed template');
      await expectLater(
        db.checkPublicationDraft(two),
        throwsA(isA<SyncMergeFailure>()),
      );
      final stored = await db.readVpn();
      final vpn = VpnWorkspace.decode(stored.source!);
      await db.writeVpn(
        vpn.copy(users: []).encode(),
        expectedRevision: stored.revision,
      );
      expect(await db.readPublicationDraft(user), isNull);
    },
  );
  test(
    'unrelated server observations do not invalidate a retained profile',
    () async {
      final draft = (await db.readPublicationDraft(user))!;
      final before = await db.readVpn();
      final workspace = VpnWorkspace.decode(before.source!);
      await db.writeVpn(
        workspace
            .copy(
              servers: {
                'server': {
                  'error': 'vpn_connection',
                  'verifiedAt': '2026-09-19T16:00:00Z',
                },
              },
            )
            .encode(),
        expectedRevision: before.revision,
      );
      await db.checkPublicationDraft(draft);
      final current = await db.readPublicationDraft(user);
      expect(current?.headId, draft.headId);
      expect(current?.hash, draft.hash);
    },
  );
  test(
    'single snapshot carries publication settings and results but keeps device queue local',
    () async {
      const password = 'public-publication-backup-fixture';
      await db.writePublicationDocument(
        'settings',
        settings,
        expectedSource: null,
      );
      await db.writePublicationQueue(
        user,
        '{"attempt":4}',
        expectedSource: null,
      );
      final binding = canonicalJson({
        'version': 1,
        'id': '2' * 32,
        'workspaceId': (await db.readWorkspaceIdentity()).workspaceId,
        'userId': user,
        'accountKey': 'fixture-account',
        'fileId': 'private-existing-fixture',
        'etag': 'old-etag',
        'hash': 'fixture-hash',
        'access': 'link',
        'previous': null,
      });
      await db.writePublicationDocument(
        'binding/$user',
        binding,
        expectedSource: null,
      );
      final backup = await db.createBackup(password);
      SecretKeyData otherKey() => SecretKeyData(List.filled(32, 51));
      var other = WorkspaceDatabase.open(
        '${dir.path}/b.sqlite',
        key: otherKey(),
      );
      try {
        await other.restoreBackup(await other.prepareRestore(backup, password));
        await other.close();
        other = WorkspaceDatabase.open('${dir.path}/b.sqlite', key: otherKey());
        expect(await other.readPublicationDocument('settings'), settings);
        expect(await other.readPublicationQueue(user), isNull);
        expect(await other.readPublicationDocument('binding/$user'), binding);
        const result =
            '{"version":2,"binding":"fixture-operation","fileId":"private-published-fixture","registryId":"registry","head":"fixture-head","hash":"fixture","executor":"fixture-device","access":"link","url":"https://drive.google.com/uc?id=fixture","permissionId":"anyone"}';
        await db.writePublicationDocument(
          'result/$user', result, expectedSource: null,
        );
        final newerBinding = canonicalJson({
          ...jsonDecode(binding) as Map<String, dynamic>,
          'etag': 'new-etag',
        });
        await db.writePublicationDocument(
          'binding/$user', newerBinding, expectedSource: binding,
        );
        final current = await db.createBackup(password);
        await other.restoreBackup(
          await other.prepareRestore(current, password),
        );
        await other.close();
        other = WorkspaceDatabase.open('${dir.path}/b.sqlite', key: otherKey());
        expect(await other.readPublicationDocument('result/$user'), result);
        expect(await other.readPublicationDocument('binding/$user'), newerBinding);
        expect(await other.readPublicationQueue(user), isNull);
      } finally {
        await other.close();
      }
    },
  );
}
