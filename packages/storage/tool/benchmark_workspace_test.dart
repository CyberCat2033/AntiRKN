import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

int median(List<int> samples) {
  final sorted = [...samples]..sort();
  return sorted[sorted.length ~/ 2];
}

Future<int> timed(Future<dynamic> Function() action) async {
  final watch = Stopwatch()..start();
  await action();
  watch.stop();
  return watch.elapsedMicroseconds;
}

void main() {
  test('isolated SQLite read and client write benchmark', () async {
    for (final count in [1, 20, 100]) {
      final temp = await Directory.systemTemp.createTemp('workspace-bench-');
      final path = '${temp.path}/workspace.sqlite';
      final key = SecretKeyData(List.filled(32, 81));
      final startup = Stopwatch()..start();
      final db = await WorkspaceDatabase.openIsolated(path, key: key);
      startup.stop();
      try {
        final identity = await db.readWorkspaceIdentity();
        final users = [
          for (var i = 0; i < count; i++)
            VpnUser(
              id: i.toRadixString(16).padLeft(32, '0'),
              login: 'client-$i',
              name: 'Client $i',
            ),
        ];
        final profiles = {
          for (final user in users)
            user.id: <String, dynamic>{
              'yaml': 'proxy: ${'x' * 512}',
              'publicationWorkspaceId': identity.workspaceId,
            },
        };
        await db.writeVpnWorkspace(
          VpnWorkspace(
            id: identity.workspaceId,
            users: users,
            profiles: profiles,
          ),
          expectedRevision: 0,
        );
        var revision = 1;
        for (var i = 0; i < 2; i++) {
          revision = await db.upsertVpnUser(
            VpnUser(id: users.first.id, login: 'client-0', name: 'Warm $i'),
            expectedRevision: revision,
          );
          await db.readVpn();
        }
        final reads = <int>[], writes = <int>[];
        for (var i = 0; i < 9; i++) {
          writes.add(
            await timed(() async {
              revision = await db.upsertVpnUser(
                VpnUser(id: users.first.id, login: 'client-0', name: 'Run $i'),
                expectedRevision: revision,
              );
            }),
          );
          reads.add(await timed(() => db.readVpn()));
        }
        final sourceBytes = utf8.encode((await db.readVpn()).source!).length;
        // ignore: avoid_print
        print(
          jsonEncode({
            'clients': count,
            'sourceBytes': sourceBytes,
            'startupMicros': startup.elapsedMicroseconds,
            'writeMedianMicros': median(writes),
            'readMedianMicros': median(reads),
            'writeSamplesMicros': writes,
            'readSamplesMicros': reads,
          }),
        );
      } finally {
        await db.close();
        await temp.delete(recursive: true);
      }
    }
  });
}
