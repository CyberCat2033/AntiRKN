import 'dart:io';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'exit immediately after committing restore without checkpoint',
    () async {
      final path = Platform.environment['ANTIRKN_BACKUP_CRASH_DB']!;
      final bytes = await File(
        Platform.environment['ANTIRKN_BACKUP_CRASH_FILE']!,
      ).readAsBytes();
      final db = WorkspaceDatabase.open(
        path,
        key: SecretKeyData(List.filled(32, 51)),
      );
      await db.restoreBackup(
        await db.prepareRestore(bytes, 'portable-backup-test-password'),
      );
      stdout.writeln('backup_fixture_committed_without_close');
      await stdout.flush();
      exit(73);
    },
  );
}
