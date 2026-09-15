import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/sync/sync_conflicts_panel.dart';
import 'package:antirkn_manager/sync/guarded_runner_transport.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

class MergeStore implements SyncMergeStore, SyncEffectGuard {
  final conflict = SyncConflict(
    kind: ChangeEntityKind.template,
    entityId: 'default',
    variants: [
      for (final id in ['a', 'b'])
        LocalChange(
          header: ChangeHeader(
            workspaceId: 'c' * 32,
            deviceId: id * 32,
            changeId: id * 32,
            sequence: 1,
            transactionId: id * 32,
            transactionIndex: 0,
            transactionSize: 1,
            entityKind: ChangeEntityKind.template,
            entityId: 'default',
            baseChangeId: null,
            baseRevision: 0,
            revision: 1,
            deleted: false,
          ),
          source: 'private-$id-template',
        ),
    ],
  );
  String? selected;
  bool fail = false, blocked = true;
  @override
  Future<void> checkSyncEffects() async {
    if (blocked) throw const SyncMergeFailure(SyncMergeIssue.conflict);
  }

  @override
  Future<SyncMergeStatus> readSyncMergeStatus() async => SyncMergeStatus(
    conflicts: selected == null ? [conflict] : [],
    missingChangeIds: [],
    waitingGroups: 0,
    blockedGroups: 0,
  );
  @override
  Future<SyncMergeStatus> receiveSyncPackets(List<Uint8List> packets) =>
      readSyncMergeStatus();
  @override
  Future<SyncMergeStatus> retrySyncMerge() => readSyncMergeStatus();
  @override
  Future<void> resolveSyncConflict(SyncConflict conflict, String choice) async {
    if (fail) throw const SyncMergeFailure(SyncMergeIssue.changed);
    selected = choice;
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    MergeStore store, {
    String locale = 'ru',
    bool canResolve = true,
    VoidCallback? saved,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ListView(
            children: [
              SyncConflictsPanel(
                store: store,
                canResolve: () => canResolve,
                onResolved: () async => saved?.call(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'RU conflict hides secrets, requires selection and saves explicit choice',
    (tester) async {
      final store = MergeStore();
      var reopened = false;
      await mount(tester, store, saved: () => reopened = true);
      await tester.tap(find.text('Базовый шаблон'));
      await tester.pumpAndSettle();
      expect(find.text('private-a-template'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Сохранить решение'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Показать содержимое и секреты').first);
      await tester.pumpAndSettle();
      expect(find.text('private-a-template'), findsOneWidget);
      await tester.tap(find.text('Выбрать эту версию').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить решение'));
      await tester.pumpAndSettle();
      expect(store.selected, 'b' * 32);
      expect(reopened, isTrue);
    },
  );
  testWidgets('cancel and active work leave conflict untouched', (
    tester,
  ) async {
    final store = MergeStore();
    await mount(tester, store, canResolve: false);
    await tester.tap(find.text('Базовый шаблон'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(store.selected, isNull);
    await tester.tap(find.text('Базовый шаблон'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать эту версию').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить решение'));
    await tester.pumpAndSettle();
    expect(store.selected, isNull);
    expect(find.textContaining('Дождитесь завершения'), findsOneWidget);
  });
  testWidgets(
    'EN narrow screen with large text retains errors and both versions',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = MergeStore()..fail = true;
      await mount(tester, store, locale: 'en');
      await tester.tap(find.text('Base template'));
      await tester.pumpAndSettle();
      final choose = find.text('Choose this version').first;
      await tester.ensureVisible(choose);
      await tester.tap(choose);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save decision'));
      await tester.pumpAndSettle();
      expect(store.selected, isNull);
      expect(find.textContaining('The conflict has changed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'persisted conflict blocks bootstrap and submission in a running controller',
    () async {
      final journal = MemoryRunnerJournal(), guard = MergeStore();
      final remote = FakeRunnerTransport(journal);
      final controller = RunnerController(
        serverId: 'one',
        transport: () => GuardedRunnerTransport(remote, guard),
        identity: () => 'fixture-host',
        password: () => null,
        accessFailure: (_) {},
        store: journal,
      );
      addTearDown(controller.dispose);
      await controller.refresh(prepare: true);
      expect(remote.installs, 0);
      expect(remote.requests, isEmpty);
      expect(controller.responseCode, 'sync_conflict');
      guard.blocked = false;
      await controller.refresh(prepare: true);
      expect(remote.installs, 1);
      guard.blocked = true;
      await controller.startDiagnostic();
      expect(remote.submissions, 0);
      expect(controller.responseCode, 'sync_conflict');
    },
  );
}
