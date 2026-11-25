import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/sync/auto_sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'auto_sync_test.dart' show Session, Settings;
import 'desktop_lifecycle_sync_test.dart'
    show AndroidAccountService, TestLanguageStore;
import 'google_account_test.dart' show AccountService;

/// A session holding a downloaded newer snapshot, as the storage keeps it.
final class _ReceivingSession implements AutoSyncSession {
  bool offer = false;
  int offered = 0, received = 0;
  @override
  Future<AutoSyncResult> exchange({
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
    bool forceRecovery = false,
    bool enter = false,
  }) async {
    if (!offer || received > 0) return const AutoSyncResult();
    offered++;
    final applied = await apply(() async => received++);
    return applied
        ? const AutoSyncResult(received: true)
        : const AutoSyncResult(waitingForEditor: true);
  }

  @override
  Future<AutoSyncResult> resolve(
    SyncDivergenceChoice choice, {
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
  }) async => const AutoSyncResult();

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('a received snapshot waits for an open dialog, then reopens', (
    tester,
  ) async {
    final account = AccountService();
    await account.signIn();
    final session = _ReceivingSession();
    final sync = AutoSyncController(
      accountService: account,
      settings: Settings(),
      changes: const Stream<void>.empty(),
      openSession: () async => session,
      apply: (_) async => false,
    );
    var reopened = 0;
    await tester.pumpWidget(
      AntiRknApp(
        source: '',
        languages: LanguageController(TestLanguageStore()),
        googleAccount: AndroidAccountService(),
        autoSync: sync,
        onRestored: () async => reopened++,
      ),
    );
    await tester.pump();
    await tester.pump();
    final context = tester.element(find.byType(Scaffold).first);
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(content: Text('editor')),
    );
    await tester.pumpAndSettle();
    // The phone returns while a dialog is open; the PC uploaded meanwhile.
    session.offer = true;
    await tester.pump(const Duration(seconds: 30));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(session.offered, 1);
    expect(sync.phase, AutoSyncPhase.editing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(session.received, 0);
    expect(sync.phase, AutoSyncPhase.editing);
    expect(reopened, 0);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();
    expect(session.received, 1);
    expect(reopened, 1);
    expect(sync.phase, AutoSyncPhase.synced);
    await tester.runAsync(sync.stop);
    sync.dispose();
  });

  testWidgets('a divergence is announced once, without a modal dialog', (
    tester,
  ) async {
    final account = AccountService();
    await account.signIn();
    final divergence = SyncDivergence(
      local: SyncVersionInfo(savedAt: DateTime.utc(2026, 11, 25, 9)),
      cloud: SyncVersionInfo(savedAt: DateTime.utc(2026, 11, 25, 10)),
    );
    final session = Session()..next = AutoSyncResult(divergence: divergence);
    final sync = AutoSyncController(
      accountService: account,
      settings: Settings(),
      changes: const Stream<void>.empty(),
      openSession: () async => session,
      apply: (_) async => false,
    );
    await tester.pumpWidget(
      AntiRknApp(
        source: '',
        languages: LanguageController(TestLanguageStore()),
        googleAccount: AndroidAccountService(),
        autoSync: sync,
      ),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
    expect(sync.phase, AutoSyncPhase.diverged);
    final snackbar = find.byKey(const ValueKey('sync-divergence-snackbar'));
    expect(snackbar, findsOneWidget);
    final l = AppLocalizations.of(tester.element(snackbar));
    expect(find.text(l.autoSyncDivergedShort), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    ScaffoldMessenger.of(tester.element(snackbar)).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    // The same divergence found again on return is not announced again.
    await tester.pump(const Duration(seconds: 30));
    sync.resumed();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(session.enters.length, greaterThan(1));
    expect(
      find.byKey(const ValueKey('sync-divergence-snackbar')),
      findsNothing,
    );
    await tester.runAsync(sync.stop);
    sync.dispose();
  });
}
