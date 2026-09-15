import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transport commit survives abrupt process exit', () async {
    final db = await SyncTransportDatabase.open(
      Platform.environment['ANTIRKN_TRANSPORT_CRASH_DB']!,
      key: SecretKeyData(List.filled(32, 29)),
      accountKey: 'crash-account',
      workspaceId: 'crash-workspace',
      deviceId: 'crash-device',
    );
    final bytes = Uint8List.fromList([41, 42, 43]);
    final digest = (await Sha256().hash(
      bytes,
    )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final receipt = await db.reserveUpload(
      SyncUploadReceipt(
        changeId: 'crash-change',
        fileId: 'crash-file',
        digest: digest,
        size: bytes.length,
      ),
    );
    await db.confirmUpload(receipt);
    await db.stageObject(
      StagedSyncObject(
        fileId: 'crash-file',
        version: '1',
        digest: digest,
        bytes: bytes,
      ),
    );
    final cursor = await db.readCursor();
    await db.saveCursor(
      const SyncTransportCursor(startToken: 'crash-cursor', listing: false),
      expectedRevision: cursor.revision,
    );
    stdout.writeln('transport_committed_without_close');
    await stdout.flush();
    exit(73);
  });
}
