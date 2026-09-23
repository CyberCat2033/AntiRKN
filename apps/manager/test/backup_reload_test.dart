import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class SelectedBackup implements BackupFileStore {
  SelectedBackup(this.bytes);
  final Uint8List bytes;
  @override
  Future<Uint8List?> pick() async => Uint8List.fromList(bytes);
  @override
  Future<bool> save(Uint8List bytes) async => false;
}

void main() {
  testWidgets(
    'confirmed restore reopens the actual database and replaces shell controllers',
    (tester) async {
      late Directory directory;
      late Uint8List backup;
      final opened = <WorkspaceDatabase>[];
      Future<WorkspaceDatabase> open() async {
        final db = WorkspaceDatabase.open(
          '${directory.path}/target.sqlite',
          key: SecretKeyData(List.filled(32, 24)),
        );
        opened.add(db);
        return db;
      }

      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('backup-shell-test-');
        final source = WorkspaceDatabase.open(
          '${directory.path}/source.sqlite',
          key: SecretKeyData(List.filled(32, 8)),
        );
        await source.writeDraft('restored-template-fixture');
        await (await source.openServer('restored-server')).saveProfile(
          SshProfile(
            host: 'restored.example',
            port: 22,
            username: 'fixture',
            authMethod: SshAuthMethod.password,
            secrets: const {ServerSecret.sshPassword: 'fixture-only-secret'},
          ),
        );
        backup = await source.createBackup('fixture-backup-password');
        await source.close();
        final current = await open();
        await current.writeSetting('componentUpdatesAutomatic', 'false');
        await current.writeLanguage(AppLanguage.en);
        await current.writeDraft('old-template-fixture');
        await current.close();
      });
      addTearDown(
        () => tester.runAsync(() async {
          for (var i = 0; i < opened.length; i++) {
            await opened[i].close();
          }
          await directory.delete(recursive: true);
        }),
      );
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        WorkspaceLauncher(
          openWorkspace: open,
          backupFiles: SelectedBackup(backup),
        ),
      );
      await settle();
      await tester.tap(find.text('Settings').last);
      await settle();
      await tester.ensureVisible(find.text('Backups').last);
      await tester.tap(find.text('Backups').last);
      await settle();
      await tester.ensureVisible(find.byKey(const ValueKey('backup-import')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('backup-import')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('backup-password')),
        'fixture-backup-password',
      );
      await tester.tap(find.byKey(const ValueKey('backup-proceed')));
      await settle();
      expect(find.text('Replace and restore'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('backup-proceed')));
      await settle();
      expect(opened.length, 3);
      expect(find.text('restored.example'), findsWidgets);
      expect(
        await tester.runAsync(() => opened.last.readDraft()),
        'restored-template-fixture',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle();
    },
  );
}
