import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

final _userId = 'a' * 32;

Future<String> _sha256(String text) async => (await Sha256().hash(
  utf8.encode(text),
)).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

Future<Map<String, dynamic>> _profile(String yaml) async => {
  'yaml': yaml,
  'hash': await _sha256(yaml),
};

Future<(Directory, String)> _temp() async {
  final temp = await Directory.systemTemp.createTemp('vpn-projection-cache-');
  addTearDown(() => temp.delete(recursive: true));
  return (temp, '${temp.path}/workspace.sqlite');
}

/// The next read decrypts exactly once; reads after it decrypt nothing.
Future<VpnWorkspace> _readFresh(WorkspaceDatabase db) async {
  final before = db.debugVpnProjectionLoads;
  final source = (await db.readVpn()).source!;
  expect(db.debugVpnProjectionLoads, before + 1, reason: 'stale projection');
  await _expectCached(db);
  return VpnWorkspace.decode(source);
}

Future<void> _expectCached(WorkspaceDatabase db) async {
  final loads = db.debugVpnProjectionLoads;
  for (var i = 0; i < 3; i++) {
    await db.readVpn();
    final draft = await db.readPublicationDraft(_userId);
    if (draft != null) await db.checkPublicationDraft(draft);
  }
  expect(db.debugVpnProjectionLoads, loads, reason: 'decrypted again');
}

int _overlayRows(String path) {
  final raw = sqlite3.open(path);
  try {
    return raw
            .select(
              'SELECT (SELECT count(*) FROM vpn_user_overlay)+(SELECT count(*) FROM vpn_profile_overlay) AS n',
            )
            .single['n']
        as int;
  } finally {
    raw.dispose();
  }
}

Uint8List _payload(Database raw) =>
    raw
            .select("SELECT payload FROM documents WHERE id='vpn-workspace-v1'")
            .single['payload']
        as Uint8List;

/// Replaces the stored document behind the store's back, keeping its
/// revision: only `data_version` can tell the change.
void _replacePayload(String path, Uint8List payload) {
  final raw = sqlite3.open(path);
  try {
    raw.execute('DROP TRIGGER IF EXISTS journal_guard_documents_update');
    raw.execute("UPDATE documents SET payload=? WHERE id='vpn-workspace-v1'", [
      payload,
    ]);
  } finally {
    raw.dispose();
  }
}

void main() {
  for (final offload in [false, true]) {
    test('every VPN write path refreshes the cached projection '
        '(offload=$offload)', () async {
      final (_, path) = await _temp();
      final db = WorkspaceDatabase.open(
        path,
        key: SecretKeyData(List.filled(32, 61)),
        offloadVpnWrites: offload,
      );
      addTearDown(db.close);
      final id = (await db.readWorkspaceIdentity()).workspaceId;
      await db.writeVpnWorkspace(
        VpnWorkspace(
          id: id,
          users: [VpnUser(id: _userId, login: 'first', name: 'First')],
        ),
        expectedRevision: 0,
      );
      expect((await _readFresh(db)).users.single.name, 'First');

      // Overlay user patch.
      await db.upsertVpnUser(
        VpnUser(id: _userId, login: 'first', name: 'Renamed'),
        expectedRevision: 1,
      );
      expect(_overlayRows(path), 1);
      expect((await _readFresh(db)).users.single.name, 'Renamed');

      // Profile write; publication reads share the projection.
      await db.upsertVpnProfile(
        _userId,
        await _profile('mode: rule\n# one'),
        expectedRevision: 2,
      );
      expect(
        (await _readFresh(db)).profiles[_userId]?['yaml'],
        endsWith('one'),
      );
      final draft = await db.readPublicationDraft(_userId);
      expect(utf8.decode(draft!.bytes), endsWith('one'));

      // A second write of the same profile.
      await db.upsertVpnProfile(
        _userId,
        await _profile('mode: rule\n# two'),
        expectedRevision: 3,
      );
      expect(
        (await _readFresh(db)).profiles[_userId]?['yaml'],
        endsWith('two'),
      );
      await expectLater(
        db.checkPublicationDraft(draft),
        throwsA(isA<SyncMergeFailure>()),
      );

      // A user patch over the latest document, then the snapshot boundary
      // folds the overlay into the document.
      await db.upsertVpnUser(
        VpnUser(id: _userId, login: 'first', name: 'Folded'),
        expectedRevision: 4,
      );
      expect(_overlayRows(path), greaterThan(0));
      expect((await _readFresh(db)).users.single.name, 'Folded');
      await db.createBackup('vpn-projection-cache-password');
      expect(_overlayRows(path), 0);
      final folded = await _readFresh(db);
      expect(folded.users.single.name, 'Folded');
      expect(folded.profiles[_userId]?['yaml'], endsWith('two'));
      expect((await db.readVpn()).revision, 5);

      // Full document write.
      await db.writeVpnWorkspace(
        folded.copy(
          users: [VpnUser(id: _userId, login: 'first', name: 'Full')],
        ),
        expectedRevision: 5,
      );
      expect(_overlayRows(path), 0);
      expect((await _readFresh(db)).users.single.name, 'Full');
    });
  }

  test('a write by another connection refreshes the projection', () async {
    final (_, path) = await _temp();
    WorkspaceDatabase open() =>
        WorkspaceDatabase.open(path, key: SecretKeyData(List.filled(32, 62)));
    final first = open();
    addTearDown(first.close);
    final id = (await first.readWorkspaceIdentity()).workspaceId;
    await first.writeVpnWorkspace(
      VpnWorkspace(
        id: id,
        users: [VpnUser(id: _userId, login: 'first', name: 'First')],
      ),
      expectedRevision: 0,
    );
    expect((await _readFresh(first)).users.single.name, 'First');
    final second = open();
    addTearDown(second.close);
    await second.upsertVpnUser(
      VpnUser(id: _userId, login: 'first', name: 'Other device'),
      expectedRevision: 1,
    );
    expect((await _readFresh(first)).users.single.name, 'Other device');
    await second.writeVpnWorkspace(
      VpnWorkspace(
        id: id,
        users: [VpnUser(id: _userId, login: 'first', name: 'Other full')],
      ),
      expectedRevision: 2,
    );
    expect((await _readFresh(first)).users.single.name, 'Other full');
  });

  test('a same-revision, same-size replacement by another connection is '
      'read, and a damaged payload still fails after caching', () async {
    final (temp, path) = await _temp();
    final key = List<int>.filled(32, 63);
    final db = WorkspaceDatabase.open(path, key: SecretKeyData(key));
    addTearDown(db.close);
    final id = (await db.readWorkspaceIdentity()).workspaceId;
    await db.writeVpnWorkspace(
      VpnWorkspace(
        id: id,
        users: [VpnUser(id: _userId, login: 'aaaa', name: 'Same')],
      ),
      expectedRevision: 0,
    );
    expect((await _readFresh(db)).users.single.login, 'aaaa');

    // The same key and revision in another file: a valid payload of equal
    // size with other content, like a restore that reuses revisions.
    final otherPath = '${temp.path}/other.sqlite';
    final other = WorkspaceDatabase.open(otherPath, key: SecretKeyData(key));
    final otherId = (await other.readWorkspaceIdentity()).workspaceId;
    await other.writeVpnWorkspace(
      VpnWorkspace(
        id: otherId,
        users: [VpnUser(id: _userId, login: 'bbbb', name: 'Same')],
      ),
      expectedRevision: 0,
    );
    await other.close();
    final rawOther = sqlite3.open(otherPath);
    final replacement = _payload(rawOther);
    rawOther.dispose();
    final raw = sqlite3.open(path);
    final original = _payload(raw);
    raw.dispose();
    expect(replacement.length, original.length);

    _replacePayload(path, replacement);
    final replaced = await db.readVpn();
    expect(replaced.revision, 1);
    expect(VpnWorkspace.decode(replaced.source!).users.single.login, 'bbbb');
    await _expectCached(db);

    final damaged = Uint8List.fromList(replacement);
    damaged[damaged.length - 1] ^= 1;
    _replacePayload(path, damaged);
    await expectLater(
      db.readVpn(),
      throwsA(
        isA<VaultFailure>().having((e) => e.issue, 'issue', VaultIssue.corrupt),
      ),
    );
  });
}
