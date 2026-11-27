import 'dart:async';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A launcher over a real workspace whose opens can be held.
class _Fixture {
  _Fixture(this.tester);
  final WidgetTester tester;
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

  Future<void> start() async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('reopen-shell-');
      final db = await open();
      await db.writeLanguage(AppLanguage.en);
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
    await tester.pumpWidget(
      WorkspaceLauncher(openWorkspace: open, backgroundChecks: false),
    );
    await settle();
    await tester.tap(find.text('Settings').last);
    await settle();
    await tester.tap(find.text('Interface').last);
    await settle();
    expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);
  }

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  /// A few frames with real time between them, as a reopen needs.
  Future<void> frames() async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }
  }

  /// Closed databases end their change stream.
  Future<bool> closed(WorkspaceDatabase db) async =>
      await tester.runAsync(
        () => db.localChanges
            .drain<void>()
            .then((_) => true)
            .timeout(const Duration(seconds: 1), onTimeout: () => false),
      ) ??
      false;
}

void main() {
  testWidgets(
    'a reopen after a received cloud version keeps the shell on screen, '
    'in the saved theme, on the same page',
    (tester) async {
      final f = _Fixture(tester);
      await f.start();
      final before = tester.widget<AntiRknApp>(find.byType(AntiRknApp));

      // What the auto-sync gate does once a received version replaced the
      // workspace (and a restored backup does too).
      f.held = Completer<void>();
      unawaited(before.onRestored!());
      await f.frames();
      // Until the new shell is ready the previous one stays visible, with
      // progress that blocks nothing else, in the saved theme.
      expect(find.byKey(const ValueKey('workspace-reopening')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(RawImage), findsOneWidget);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );

      f.held!.complete();
      await f.settle();
      final after = tester.widget<AntiRknApp>(find.byType(AntiRknApp));
      expect(identical(after, before), isFalse);
      expect(f.opened.length, 3);
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
      await f.settle();
    },
  );

  testWidgets('two reopen requests at once make one reopen', (tester) async {
    final f = _Fixture(tester);
    await f.start();
    final before = tester.widget<AntiRknApp>(find.byType(AntiRknApp));
    f.held = Completer<void>();
    unawaited(before.onRestored!());
    unawaited(before.onRestored!());
    await f.frames();
    // A request while the reopen runs is answered by it.
    unawaited(before.onRestored!());
    await f.frames();
    expect(find.byKey(const ValueKey('workspace-reopening')), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
    f.held!.complete();
    await f.settle();
    expect(f.opened.length, 3);
    expect(await f.closed(f.opened[1]), isTrue);
    expect(await f.closed(f.opened[2]), isFalse);
    expect(find.byType(AntiRknApp), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await f.settle();
  });

  testWidgets('a workspace opened after the launcher is gone is closed', (
    tester,
  ) async {
    final f = _Fixture(tester);
    await f.start();
    final before = tester.widget<AntiRknApp>(find.byType(AntiRknApp));
    f.held = Completer<void>();
    unawaited(before.onRestored!());
    await f.frames();
    await tester.pumpWidget(const SizedBox.shrink());
    await f.settle();
    // The reopen was waiting for the database; it arrives too late.
    f.held!.complete();
    await f.settle();
    expect(f.opened.length, 3);
    expect(await f.closed(f.opened[1]), isTrue);
    expect(await f.closed(f.opened[2]), isTrue);
    expect(tester.takeException(), isNull);
  });
}
