import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exit after durable causal application', () async {
    final path = Platform.environment['ANTIRKN_MERGE_CRASH_PATH'];
    if (path == null) return;
    final db = WorkspaceDatabase.open(
      path,
      key: SecretKeyData(List.filled(32, 41)),
    );
    await db.readWorkspaceIdentity();
    final raw = jsonDecode(await File('$path.packets').readAsString()) as List;
    await db.receiveSyncPackets(
      raw.map((e) => Uint8List.fromList(base64Decode(e as String))).toList(),
    );
    stdout.writeln('merge_fixture_committed_without_close');
    await stdout.flush();
    exit(73);
  });
}
