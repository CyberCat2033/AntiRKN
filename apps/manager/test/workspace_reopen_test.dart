import 'dart:async';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a reopen after a received cloud version keeps the shell on screen, '
    'in the saved theme, on the same page',
    (tester) async {
      late Directory directory;
      final opened = <WorkspaceDatabase>[];
      Completer<void>? held;
      Future<WorkspaceDatabase> open() async {
        await held?.future;
        final db = await WorkspaceDatabase.openIsolated(
          '${directory.path}/workspace.sqlite',
          key: SecretKeyData(List.filled(32, 31)),
        );
        opened.add(db);
        return db;
      }

      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('reopen-shell-');
        final db = await open();
        await db.writeLanguage(AppLanguage.en);
        await db.writeSetting('componentUpdatesAutomatic', 'false');
        await db.writeSetting('googleAutoSync', 'false');
        // A dark app on a light system (the platform default in tests).
        await db.writeSetting('theme', ThemeMode.dark.name);
        await db.close();
      });
      addTearDown(
        () => tester.runAsync(() async {
          for (final db in opened) {
            await db.close();
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

      await tester.pumpWidget(WorkspaceLauncher(openWorkspace: open));
      await settle();
      await tester.tap(find.text('Settings').last);
      await settle();
      await tester.tap(find.text('Interface').last);
      await settle();
      expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);
      final before = tester.widget<AntiRknApp>(find.byType(AntiRknApp));

      // What the auto-sync gate does once a received version replaced the
      // workspace (and a restored backup does too).
      held = Completer<void>();
      final reopen = before.onRestored!();
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
      }
      // Until the new shell is ready the previous one stays visible, with
      // progress that blocks nothing else, in the saved theme.
      expect(find.byKey(const ValueKey('workspace-reopening')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(RawImage), findsOneWidget);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );

      held.complete();
      await tester.runAsync(() => reopen);
      await settle();
      final after = tester.widget<AntiRknApp>(find.byType(AntiRknApp));
      expect(identical(after, before), isFalse);
      expect(opened.length, 3);
      expect(find.byKey(const ValueKey('workspace-reopening')), findsNothing);
      // The same page: Settings, with its Interface page open.
      expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);
      expect(find.text('Interface'), findsWidgets);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle();
    },
  );
}
