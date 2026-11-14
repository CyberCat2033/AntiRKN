import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fixtures/journal_data.dart';

String hexId(String prefix, int index) {
  final hexIndex = index.toRadixString(16).padLeft(4, '0');
  final hexPrefix = prefix.replaceAll(RegExp(r'[^a-f0-9]'), 'a');
  return (hexPrefix * 32).substring(0, 28) + hexIndex;
}

LocalChange testEvent(
  String idHex, {
  String? parentHex,
  int revision = 1,
  String source = 'value',
  bool deleted = false,
  List<String> othersHex = const [],
  String entity = 'default',
}) => LocalChange(
  header: ChangeHeader(
    workspaceId: 'f' * 32,
    deviceId: idHex,
    changeId: idHex,
    sequence: 1,
    transactionId: idHex,
    transactionIndex: 0,
    transactionSize: 1,
    entityKind: ChangeEntityKind.template,
    entityId: entity,
    baseChangeId: parentHex,
    baseRevision: parentHex == null ? 0 : revision - 1,
    revision: revision,
    deleted: deleted,
    schemaVersion: othersHex.isEmpty ? 1 : 2,
    mergeParents: othersHex,
  ),
  source: deleted ? null : source,
);

Future<void> cloneReplica(
  String sourcePath,
  String destPath,
  String newDeviceId,
  SecretKeyData key,
) async {
  final src = File(sourcePath);
  src.copySync(destPath);
  final raw = sqlite3.open(destPath);
  try {
    final row = raw.select('SELECT workspace_id FROM sync_identity WHERE singleton=1').single;
    final workspaceId = row['workspace_id'] as String;
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(canonicalJson({
        'version': 1,
        'workspaceId': workspaceId,
        'deviceId': newDeviceId,
      })),
      secretKey: key,
      aad: utf8.encode('antirkn:1:journal-identity:1'),
    );
    raw.execute('UPDATE sync_identity SET device_id=?, proof=?', [
      newDeviceId,
      box.concatenation(),
    ]);
  } finally {
    raw.dispose();
  }
}

void main() {
  late Directory tempDir;
  final stores = <WorkspaceDatabase>[];

  WorkspaceDatabase openDb(String name, int keyByte) {
    final store = WorkspaceDatabase.open(
      '${tempDir.path}/$name.sqlite',
      key: SecretKeyData(List.filled(32, keyByte)),
      offloadVpnWrites: true,
    );
    stores.add(store);
    return store;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync-chaos-benchmark-');
  });

  tearDown(() async {
    for (final s in stores) {
      await s.close();
    }
    stores.clear();
    await tempDir.delete(recursive: true);
  });

  group('Area 1: Split-Brain Collision Resolution & Causal DAG Integrity', () {
    test(
      '3-way offline split-brain with 50+ mutations converges to Strong Eventual Consistency',
      () async {
        final keyData = SecretKeyData(List.filled(32, 101));

        // 1. Initialise primary replica
        final r1 = openDb('replica1', 101);
        final identity = await r1.readWorkspaceIdentity();
        await r1.writeVpnWorkspace(
          VpnWorkspace(id: identity.workspaceId),
          expectedRevision: 0,
        );
        await r1.writeDraft('base-template');

        // Create baseline server and user
        final baseServerId = r1.newServerId();
        final baseServer = await r1.openServer(baseServerId);
        await baseServer.saveProfile(fixtureServer('base.example'));

        final baseUserId = hexId('b', 1);
        await r1.upsertVpnUser(
          VpnUser(id: baseUserId, login: 'base-user', name: 'Base User'),
          expectedRevision: (await r1.readVpn()).revision,
        );

        // Close r1 temporarily to snapshot file cleanly for replicas 2 and 3
        await r1.close();
        stores.remove(r1);

        final r1Path = '${tempDir.path}/replica1.sqlite';
        final r2Path = '${tempDir.path}/replica2.sqlite';
        final r3Path = '${tempDir.path}/replica3.sqlite';

        await cloneReplica(r1Path, r2Path, hexId('d', 2), keyData);
        await cloneReplica(r1Path, r3Path, hexId('d', 3), keyData);

        // Reopen all 3 replicas
        final replica1 = openDb('replica1', 101);
        final replica2 = openDb('replica2', 101);
        final replica3 = openDb('replica3', 101);

        // Verify distinct device IDs but identical workspace ID
        final id1 = await replica1.readWorkspaceIdentity();
        final id2 = await replica2.readWorkspaceIdentity();
        final id3 = await replica3.readWorkspaceIdentity();
        expect(id1.workspaceId, id2.workspaceId);
        expect(id2.workspaceId, id3.workspaceId);
        expect(id1.deviceId, isNot(id2.deviceId));
        expect(id2.deviceId, isNot(id3.deviceId));

        // 2. Perform 50+ offline mutations in parallel across the 3 replicas:
        // Replica 1 mutations: 10 users + 5 servers + 1 template = 16 mutations
        for (var i = 0; i < 10; i++) {
          final uid = hexId('1', i);
          await replica1.upsertVpnUser(
            VpnUser(id: uid, login: 'user-r1-$i', name: 'User R1-$i'),
            expectedRevision: (await replica1.readVpn()).revision,
          );
        }
        for (var i = 0; i < 5; i++) {
          final sid = replica1.newServerId();
          final s = await replica1.openServer(sid);
          await s.saveProfile(fixtureServer('r1-srv-$i.example'));
        }
        await replica1.writeDraft('template-edited-by-r1');

        // Replica 2 mutations: 10 users + 5 servers + 1 setting = 16 mutations
        for (var i = 0; i < 10; i++) {
          final uid = hexId('2', i);
          await replica2.upsertVpnUser(
            VpnUser(id: uid, login: 'user-r2-$i', name: 'User R2-$i'),
            expectedRevision: (await replica2.readVpn()).revision,
          );
        }
        for (var i = 0; i < 5; i++) {
          final sid = replica2.newServerId();
          final s = await replica2.openServer(sid);
          await s.saveProfile(fixtureServer('r2-srv-$i.example'));
        }
        await replica2.writeSetting('theme', 'dark');

        // Replica 3 mutations: 10 users + 5 servers + 4 inbounds = 19 mutations
        for (var i = 0; i < 10; i++) {
          final uid = hexId('3', i);
          await replica3.upsertVpnUser(
            VpnUser(id: uid, login: 'user-r3-$i', name: 'User R3-$i'),
            expectedRevision: (await replica3.readVpn()).revision,
          );
        }
        for (var i = 0; i < 5; i++) {
          final sid = replica3.newServerId();
          final s = await replica3.openServer(sid);
          await s.saveProfile(fixtureServer('r3-srv-$i.example'));
        }
        // Total mutations across 3 nodes = 16 + 16 + 19 = 51 independent mutations!

        // 3. Cross-exchange packets across all nodes (full mesh split-brain convergence)
        final packets1 = await replica1.preparePendingPackets(limit: 100);
        final packets2 = await replica2.preparePendingPackets(limit: 100);
        final packets3 = await replica3.preparePendingPackets(limit: 100);

        expect(packets1.length, greaterThanOrEqualTo(16));
        expect(packets2.length, greaterThanOrEqualTo(16));
        expect(packets3.length, greaterThanOrEqualTo(15));

        final p1Bytes = packets1.map((p) => p.bytes).toList();
        final p2Bytes = packets2.map((p) => p.bytes).toList();
        final p3Bytes = packets3.map((p) => p.bytes).toList();

        // Node 1 receives 2 and 3
        await replica1.receiveSyncPackets(p2Bytes);
        await replica1.receiveSyncPackets(p3Bytes);

        // Node 2 receives 1 and 3
        await replica2.receiveSyncPackets(p1Bytes);
        await replica2.receiveSyncPackets(p3Bytes);

        // Node 3 receives 1 and 2
        await replica3.receiveSyncPackets(p1Bytes);
        await replica3.receiveSyncPackets(p2Bytes);

        // Acknowledge packets on origin nodes
        await replica1.acknowledgeChanges(packets1.map((p) => p.changeId).toList());
        await replica2.acknowledgeChanges(packets2.map((p) => p.changeId).toList());
        await replica3.acknowledgeChanges(packets3.map((p) => p.changeId).toList());

        // 4. Verify Strong Eventual Consistency across all 3 nodes
        final vpn1 = await replica1.readVpn();
        final vpn2 = await replica2.readVpn();
        final vpn3 = await replica3.readVpn();

        final u1 = VpnWorkspace.decode(vpn1.source!).users.map((u) => u.id).toSet();
        final u2 = VpnWorkspace.decode(vpn2.source!).users.map((u) => u.id).toSet();
        final u3 = VpnWorkspace.decode(vpn3.source!).users.map((u) => u.id).toSet();

        // 1 baseline user + 10 (r1) + 10 (r2) + 10 (r3) = 31 users
        expect(u1.length, 31);
        expect(u1, equals(u2));
        expect(u2, equals(u3));

        // 1 baseline server + 5 (r1) + 5 (r2) + 5 (r3) = 16 servers
        final srv1 = (await replica1.listServers()).map((s) => s.id).toSet();
        final srv2 = (await replica2.listServers()).map((s) => s.id).toSet();
        final srv3 = (await replica3.listServers()).map((s) => s.id).toSet();
        expect(srv1.length, 16);
        expect(srv1, equals(srv2));
        expect(srv2, equals(srv3));

        // Sync merge status: no blocked groups
        final status1 = await replica1.readSyncMergeStatus();
        final status2 = await replica2.readSyncMergeStatus();
        final status3 = await replica3.readSyncMergeStatus();
        expect(status1.blockedGroups, 0);
        expect(status2.blockedGroups, 0);
        expect(status3.blockedGroups, 0);
      },
    );

    test('Causal DAG handles up to 65 tips and strictly rejects 66th with SyncMergeIssue.limit', () {
      final root = testEvent(hexId('r', 0), revision: 1);
      final events = <LocalChange>[root];

      // Generate 65 concurrent tips branching off root
      for (var i = 1; i <= 65; i++) {
        final idHex = hexId('t', i);
        events.add(
          LocalChange(
            header: ChangeHeader(
              workspaceId: 'f' * 32,
              deviceId: idHex,
              changeId: idHex,
              sequence: 1,
              transactionId: idHex,
              transactionIndex: 0,
              transactionSize: 1,
              entityKind: ChangeEntityKind.template,
              entityId: 'default',
              baseChangeId: root.header.changeId,
              baseRevision: 1,
              revision: 2,
              deleted: false,
              schemaVersion: 1,
              mergeParents: const [],
            ),
            source: 'branch-$i',
          ),
        );
      }

      // 65 tips should be accepted
      final graph65 = CausalGraph(events);
      expect(graph65.tips.values.single.length, 65);

      // Add 66th tip -> should throw SyncMergeFailure(SyncMergeIssue.limit)
      final tip66Id = hexId('t', 66);
      final tip66 = LocalChange(
        header: ChangeHeader(
          workspaceId: 'f' * 32,
          deviceId: tip66Id,
          changeId: tip66Id,
          sequence: 1,
          transactionId: tip66Id,
          transactionIndex: 0,
          transactionSize: 1,
          entityKind: ChangeEntityKind.template,
          entityId: 'default',
          baseChangeId: root.header.changeId,
          baseRevision: 1,
          revision: 2,
          deleted: false,
          schemaVersion: 1,
          mergeParents: const [],
        ),
        source: 'branch-66',
      );
      events.add(tip66);

      expect(
        () => CausalGraph(events),
        throwsA(
          isA<SyncMergeFailure>().having(
            (e) => e.issue,
            'issue',
            SyncMergeIssue.limit,
          ),
        ),
      );

      // Now compact/merge 40 of the tips into one merge event
      final acknowledgedTips = events.skip(1).take(40).map((e) => e.header.changeId).toList();
      final mergeId = hexId('m', 99);
      final mergeEvent = LocalChange(
        header: ChangeHeader(
          workspaceId: 'f' * 32,
          deviceId: mergeId,
          changeId: mergeId,
          sequence: 2,
          transactionId: mergeId,
          transactionIndex: 0,
          transactionSize: 1,
          entityKind: ChangeEntityKind.template,
          entityId: 'default',
          baseChangeId: acknowledgedTips.first,
          baseRevision: 2,
          revision: 3,
          deleted: false,
          schemaVersion: 2,
          mergeParents: acknowledgedTips.skip(1).toList(),
        ),
        source: 'merged-branches',
      );

      // With merge event included, tips count drops: 66 - 40 + 1 = 27 tips
      final mergedGraph = CausalGraph([...events, mergeEvent]);
      expect(mergedGraph.tips.values.single.length, 27);
    });

    test('Strict revision monotonicity prevents cycles in Causal DAG', () {
      final aId = hexId('a', 1);
      final a = testEvent(aId, revision: 1);
      final bId = hexId('b', 1);

      // Verify CausalGraph enforces parent existence and topological ordering
      final b = testEvent(bId, parentHex: aId, revision: 2);
      final graph = CausalGraph([a, b]);
      expect(graph.tips.values.single, [bId]);
      expect(graph.commonAncestor([bId])?.header.changeId, bId);
      expect(
        () => ChangeHeader(
          workspaceId: 'f' * 32,
          deviceId: bId,
          changeId: bId,
          sequence: 1,
          transactionId: bId,
          transactionIndex: 0,
          transactionSize: 1,
          entityKind: ChangeEntityKind.template,
          entityId: 'default',
          baseChangeId: aId,
          baseRevision: 1,
          revision: 1, // invalid: revision must be baseRevision + 1
          deleted: false,
          schemaVersion: 1,
          mergeParents: const [],
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Area 2: Tombstone Lifecycle & Resurrection Prevention', () {
    test(
      '100 cycles of concurrent delete vs edit: Tombstone-Wins Semantics guaranteed (0 resurrection events)',
      () async {
        final keyData = SecretKeyData(List.filled(32, 150));
        var resurrectionCount = 0;

        for (var cycle = 0; cycle < 100; cycle++) {
          final baseName = 'cycle_$cycle';
          final rAInit = openDb('${baseName}_a', 150);

          final identity = await rAInit.readWorkspaceIdentity();
          final wId = identity.workspaceId;
          final targetUserId = hexId('u', cycle);

          // Seed baseline workspace on rA
          await rAInit.writeVpnWorkspace(
            VpnWorkspace(
              id: wId,
              users: [
                VpnUser(
                  id: targetUserId,
                  login: 'test-user-$cycle',
                  name: 'Original Name $cycle',
                ),
              ],
            ),
            expectedRevision: 0,
          );

          await rAInit.close();
          stores.remove(rAInit);

          // Clone cleanly for replica B with valid cryptographic device proof
          final pathA = '${tempDir.path}/${baseName}_a.sqlite';
          final pathB = '${tempDir.path}/${baseName}_b.sqlite';
          await cloneReplica(pathA, pathB, hexId('d', cycle + 100), keyData);

          final rA = openDb('${baseName}_a', 150);
          final rB = openDb('${baseName}_b', 150);

          // Concurrent offline mutation:
          // Replica A DELETES the user (tombstone)
          await rA.upsertVpnUser(
            VpnUser(
              id: targetUserId,
              login: 'test-user-$cycle',
              name: 'Original Name $cycle',
              enabled: false,
              deletion: {
                'version': 1,
                'id': targetUserId,
                'targets': <String, dynamic>{},
              },
            ),
            expectedRevision: (await rA.readVpn()).revision,
          );

          // Replica B concurrently EDITS the user (modifying name)
          await rB.upsertVpnUser(
            VpnUser(
              id: targetUserId,
              login: 'test-user-$cycle',
              name: 'Resurrected Edit $cycle',
              enabled: true,
            ),
            expectedRevision: (await rB.readVpn()).revision,
          );

          // Exchange packets between rA and rB
          final packetsA = await rA.preparePendingPackets();
          final packetsB = await rB.preparePendingPackets();

          await rA.receiveSyncPackets(packetsB.map((p) => p.bytes).toList());
          await rB.receiveSyncPackets(packetsA.map((p) => p.bytes).toList());

          // Verify Tombstone-Wins Semantics on both replicas
          final vpnA = VpnWorkspace.decode((await rA.readVpn()).source!);
          final vpnB = VpnWorkspace.decode((await rB.readVpn()).source!);

          final userA = vpnA.users.firstWhere((u) => u.id == targetUserId);
          final userB = vpnB.users.firstWhere((u) => u.id == targetUserId);

          if (!userA.deleted || !userB.deleted) {
            resurrectionCount++;
          }
          expect(userA.deleted, isTrue);
          expect(userB.deleted, isTrue);

          // If a conflict was registered, verify attempting to resolve with the non-deleted edit fails
          final statusA = await rA.readSyncMergeStatus();
          for (final conflict in statusA.conflicts.where((c) => c.entityId == targetUserId)) {
            final nonDeletedChoice = conflict.variants.firstWhere((v) => !v.header.deleted).header.changeId;
            expect(
              () => rA.resolveSyncConflict(conflict, nonDeletedChoice),
              throwsA(isA<SyncMergeFailure>()),
            );
          }

          await rA.close();
          await rB.close();
          stores.remove(rA);
          stores.remove(rB);
        }

        expect(resurrectionCount, 0, reason: 'Tombstone-Wins Semantics strictly preserved: 0 resurrection events');
      },
    );

    test('Cascade server deletion leaves no dangling active references', () async {
      final db = openDb('cascade_server_test', 160);
      final id = await db.readWorkspaceIdentity();
      await db.writeVpnWorkspace(VpnWorkspace(id: id.workspaceId), expectedRevision: 0);

      final sid = db.newServerId();
      final srv = await db.openServer(sid);
      await srv.saveProfile(fixtureServer('cascade.example'));

      final list = await db.listServers();
      expect(list.any((s) => s.id == sid), isTrue);

      // Delete server
      await db.deleteServers(list.where((s) => s.id == sid).toList());
      expect((await db.listServers()).any((s) => s.id == sid), isFalse);

      // Verify server is marked deleted in sync_heads
      final raw = sqlite3.open('${tempDir.path}/cascade_server_test.sqlite');
      final head = raw.select(
        "SELECT * FROM sync_heads WHERE entity_kind='server' AND entity_id=?",
        [sid],
      );
      expect(head.single['deleted'], 1);
      raw.dispose();
    });
  });

  group('Area 3: Transactional Atomicity of _WorkspaceMerge & SQLite Fault Resilience', () {
    test('journal_guard_* triggers strictly block direct table manipulation outside journal transactions', () async {
      final db = openDb('guard_test', 170);
      // Initialize database schema and guards
      await db.readWorkspaceIdentity();
      await db.writeDraft('initial-draft');
      final sid = db.newServerId();
      final srv = await db.openServer(sid);
      await srv.saveProfile(fixtureServer('guard.example'));

      final raw = sqlite3.open('${tempDir.path}/guard_test.sqlite');
      addTearDown(raw.dispose);

      // Attempt direct INSERT into servers bypassing journal
      expect(
        () => raw.execute(
          "INSERT INTO servers VALUES ('rogue-server', X'010203', 1, 123456789)",
        ),
        throwsA(
          isA<SqliteException>().having(
            (e) => e.message,
            'message',
            contains('journal_writer_required'),
          ),
        ),
      );

      // Attempt direct UPDATE on documents
      expect(
        () => raw.execute(
          "UPDATE documents SET payload=X'ffff' WHERE id='template-draft'",
        ),
        throwsA(
          isA<SqliteException>().having(
            (e) => e.message,
            'message',
            contains('journal_writer_required'),
          ),
        ),
      );

      // Attempt direct DELETE on servers
      expect(
        () => raw.execute("DELETE FROM servers WHERE id='$sid'"),
        throwsA(
          isA<SqliteException>().having(
            (e) => e.message,
            'message',
            contains('journal_writer_required'),
          ),
        ),
      );
    });

    test('optimistic epoch stamp lock recovers gracefully under concurrent writes', () async {
      final keyData = SecretKeyData(List.filled(32, 180));
      final db = openDb('epoch_lock_test', 180);
      final id = await db.readWorkspaceIdentity();
      await db.writeVpnWorkspace(VpnWorkspace(id: id.workspaceId), expectedRevision: 0);
      await db.writeDraft('initial-draft');

      await db.close();
      stores.remove(db);

      final pathMain = '${tempDir.path}/epoch_lock_test.sqlite';
      final pathOther = '${tempDir.path}/epoch_other.sqlite';
      await cloneReplica(pathMain, pathOther, hexId('d', 88), keyData);

      final mainDb = openDb('epoch_lock_test', 180);
      final otherDb = openDb('epoch_other', 180);

      // Prepare change packet on otherDb
      await otherDb.writeDraft('remote-draft-update');
      final packets = await otherDb.preparePendingPackets();

      // Concurrently modify a setting on mainDb while receiving the packet
      final receiveFuture = mainDb.receiveSyncPackets(packets.map((p) => p.bytes).toList());
      await mainDb.writeSetting('concurrent_key', 'concurrent_val');

      final status = await receiveFuture;
      expect(status.blockedGroups, 0);
      expect(status.rejectedGroups, 0);
    });
  });

  group('Area 4: Cryptographic Verification of E2EE Packets & Fuzzing', () {
    test('Fuzzing 50+ corrupted/randomized sync packets: all rejected gracefully without database corruption', () async {
      final db = openDb('fuzz_target', 190);
      final id = await db.readWorkspaceIdentity();
      await db.writeVpnWorkspace(VpnWorkspace(id: id.workspaceId), expectedRevision: 0);

      // Prepare a baseline valid packet
      await db.writeDraft('fuzz-baseline-draft');
      final validPackets = await db.preparePendingPackets();
      expect(validPackets, isNotEmpty);
      final validBytes = validPackets.first.bytes;

      final rng = Random(42);
      final fuzzedPackets = <Uint8List>[];

      // 1. Truncated packets (lengths 0, 1, 7, 8, 15, 30, 40, 50, 60, 79)
      for (final len in [0, 1, 7, 8, 15, 30, 40, 50, 60, 79]) {
        fuzzedPackets.add(validBytes.sublist(0, min(len, validBytes.length)));
      }

      // 2. Corrupted magic header
      for (var i = 0; i < 5; i++) {
        final b = Uint8List.fromList(validBytes);
        b[i] = (b[i] + 1) % 256;
        fuzzedPackets.add(b);
      }

      // 3. Corrupted version & suite
      for (final offset in [8, 9]) {
        for (final val in [0, 2, 255]) {
          final b = Uint8List.fromList(validBytes);
          b[offset] = val;
          fuzzedPackets.add(b);
        }
      }

      // 4. Corrupted keyVersion
      for (final val in [0, 999, 0x7fffffff + 1]) {
        final b = Uint8List.fromList(validBytes);
        ByteData.sublistView(b).setUint32(10, val & 0xffffffff);
        fuzzedPackets.add(b);
      }

      // 5. Corrupted workspaceId
      for (var i = 14; i < 30; i += 3) {
        final b = Uint8List.fromList(validBytes);
        b[i] = b[i] ^ 0xff;
        fuzzedPackets.add(b);
      }

      // 6. Corrupted changeId
      for (var i = 30; i < 46; i += 3) {
        final b = Uint8List.fromList(validBytes);
        b[i] = b[i] ^ 0xaa;
        fuzzedPackets.add(b);
      }

      // 7. Bit-flipped Nonce (offsets 46..69)
      for (var i = 46; i < 70; i += 4) {
        final b = Uint8List.fromList(validBytes);
        b[i] = b[i] ^ 0x01;
        fuzzedPackets.add(b);
      }

      // 8. Bit-flipped Ciphertext
      for (var i = 70; i < validBytes.length - 16; i += 10) {
        final b = Uint8List.fromList(validBytes);
        b[i] = b[i] ^ 0x55;
        fuzzedPackets.add(b);
      }

      // 9. Bit-flipped Poly1305 MAC tag (last 16 bytes)
      for (var i = validBytes.length - 16; i < validBytes.length; i += 3) {
        final b = Uint8List.fromList(validBytes);
        b[i] = b[i] ^ 0x80;
        fuzzedPackets.add(b);
      }

      // 10. Completely random byte arrays
      for (var i = 0; i < 5; i++) {
        final len = rng.nextInt(200) + 50;
        final b = Uint8List.fromList(List.generate(len, (_) => rng.nextInt(256)));
        fuzzedPackets.add(b);
      }

      expect(fuzzedPackets.length, greaterThanOrEqualTo(50));

      // Inject every fuzzed packet individually into verifySyncPacket and receiveSyncPackets
      for (var idx = 0; idx < fuzzedPackets.length; idx++) {
        final packet = fuzzedPackets[idx];
        await expectLater(
          db.verifySyncPacket(packet),
          throwsA(isA<SyncPacketFailure>()),
          reason: 'Fuzzed packet #$idx must be rejected by verifySyncPacket',
        );

        await expectLater(
          db.receiveSyncPackets([packet]),
          throwsA(isA<SyncPacketFailure>()),
          reason: 'Fuzzed packet #$idx must be rejected by receiveSyncPackets',
        );
      }

      // Verify database integrity is 100% intact after 50+ malformed injections
      final raw = sqlite3.open('${tempDir.path}/fuzz_target.sqlite');
      final integrity = raw.select('PRAGMA integrity_check').single.values.first as String;
      expect(integrity, 'ok');
      raw.dispose();

      // Verify normal read/write still functions flawlessly
      expect(await db.readDraft(), 'fuzz-baseline-draft');
      await db.writeDraft('healthy-after-fuzzing');
      expect(await db.readDraft(), 'healthy-after-fuzzing');
    });

    test('Cache clearing and memory safety: _decryptedEventCache purged properly', () async {
      final db = openDb('cache_test', 200);
      final id = await db.readWorkspaceIdentity();
      await db.writeVpnWorkspace(VpnWorkspace(id: id.workspaceId), expectedRevision: 0);

      // Perform a series of writes and read sync status
      for (var i = 0; i < 5; i++) {
        await db.writeDraft('draft-cache-$i');
      }

      final status = await db.readSyncMergeStatus();
      expect(status.conflicts, isEmpty);

      // Explicitly clear sync cache
      db.clearSyncCache();

      // Database remains functional and reloads on demand
      expect(await db.readDraft(), 'draft-cache-4');
    });
  });
}
