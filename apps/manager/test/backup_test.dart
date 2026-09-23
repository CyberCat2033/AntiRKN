import 'dart:async';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/backup/backup_controller.dart';
import 'package:antirkn_manager/backup/backup_panel.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Plan implements WorkspaceRestorePlan {
  bool disposed = false;
  @override
  BackupSummary get summary => BackupSummary(
    createdAt: DateTime.utc(2026, 9, 15),
    workspaceId: 'a' * 32,
    servers: 2,
    users: 3,
  );
  @override
  void dispose() => disposed = true;
}

class Store implements WorkspaceBackupStore {
  final plan = Plan();
  final bytes = Uint8List.fromList([4, 5, 6]);
  int creates = 0, prepares = 0, restores = 0;
  Completer<WorkspaceRestorePlan>? delayed;
  BackupIssue? failure;
  @override
  Future<Uint8List> createBackup(String password) async {
    creates++;
    return bytes;
  }

  @override
  Future<WorkspaceRestorePlan> prepareRestore(
    Uint8List bytes,
    String password,
  ) async {
    prepares++;
    if (failure != null) throw BackupFailure(failure!);
    return delayed?.future ?? plan;
  }

  @override
  Future<void> restoreBackup(WorkspaceRestorePlan plan) async {
    restores++;
    if (failure != null) throw BackupFailure(failure!);
  }
}

class Files implements BackupFileStore {
  Uint8List? bytes = Uint8List.fromList([1, 2, 3]);
  List<int>? saved;
  bool failSave = false;
  @override
  Future<Uint8List?> pick() async => bytes;
  @override
  Future<bool> save(Uint8List bytes) async {
    if (failSave) throw const BackupFailure(BackupIssue.file);
    saved = List.of(bytes);
    return true;
  }
}

void main() {
  test(
    'cancelled picker does not prepare or restore; export only sends ciphertext and clears its buffer',
    () async {
      final store = Store(), files = Files()..bytes = null;
      final controller = BackupController(store: store, files: files);
      addTearDown(controller.dispose);
      await controller.prepare('fixture-password');
      expect(store.prepares, 0);
      expect(store.restores, 0);
      await controller.export('fixture-password');
      expect(files.saved, [4, 5, 6]);
      expect(store.bytes, [0, 0, 0]);
      expect(controller.completed, isTrue);
    },
  );

  test(
    'failed export clears bytes and reports failure instead of success',
    () async {
      final store = Store(), files = Files()..failSave = true;
      final controller = BackupController(store: store, files: files);
      addTearDown(controller.dispose);
      await controller.export('fixture-password');
      expect(controller.error, BackupIssue.file);
      expect(controller.completed, isFalse);
      expect(store.bytes, [0, 0, 0]);
    },
  );

  test(
    'late preview is discarded after dispose and overlapping work is ignored',
    () async {
      final store = Store()..delayed = Completer<WorkspaceRestorePlan>();
      final files = Files(),
          controller = BackupController(store: store, files: Files());
      final work = controller.prepare('fixture-password');
      await Future<void>.delayed(Duration.zero);
      await controller.export('fixture-password');
      expect(store.creates, 0);
      controller.dispose();
      store.delayed!.complete(store.plan);
      await work;
      expect(store.plan.disposed, isTrue);
      expect(store.restores, 0);
      expect(files.saved, isNull);
    },
  );

  test(
    'failed or stale restore releases its plan and requires a new preview',
    () async {
      final store = Store(), files = Files();
      final controller = BackupController(store: store, files: files);
      addTearDown(controller.dispose);
      await controller.prepare('fixture-password');
      expect(files.bytes, [0, 0, 0]);
      expect(store.restores, 0);
      store.failure = BackupIssue.changed;
      await controller.restore();
      expect(controller.error, BackupIssue.changed);
      expect(controller.summary, isNull);
      expect(controller.completed, isFalse);
      expect(store.plan.disposed, isTrue);
    },
  );

  for (final language in ['ru', 'en']) {
    testWidgets(
      'backup $language at 390px and text x2 requires preview and explicit replacement',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final store = Store(), files = Files();
        var reloaded = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: ListView(
                children: [
                  BackupPanel(
                    store: store,
                    files: files,
                    onRestored: () async {
                      reloaded++;
                    },
                    canRestore: () => true,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('backup-import')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('backup-password')),
          'fixture-password',
        );
        await tester.tap(find.byKey(const ValueKey('backup-proceed')));
        await tester.pumpAndSettle();
        expect(store.prepares, 1);
        expect(store.restores, 0);
        expect(reloaded, 0);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('backup-proceed')));
        await tester.pumpAndSettle();
        expect(store.restores, 1);
        expect(reloaded, 1);
        expect(store.plan.disposed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'password mismatch and active work block their respective operations; cancel releases preview',
    (tester) async {
      final store = Store(), files = Files();
      var ready = false;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: BackupPanel(
              store: store,
              files: files,
              onRestored: () async {},
              canRestore: () => ready,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('backup-export')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('backup-password')),
        'fixture-password',
      );
      await tester.enterText(
        find.byKey(const ValueKey('backup-repeat')),
        'different-password',
      );
      await tester.tap(find.byKey(const ValueKey('backup-proceed')));
      await tester.pumpAndSettle();
      expect(store.creates, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup-import')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('backup-password')),
        'fixture-password',
      );
      await tester.tap(find.byKey(const ValueKey('backup-proceed')));
      await tester.pumpAndSettle();
      expect(store.prepares, 0);
      ready = true;
      await tester.tap(find.byKey(const ValueKey('backup-proceed')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.restores, 0);
      expect(store.plan.disposed, isTrue);
    },
  );
}
