import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/sync/auto_sync_controller.dart';
import 'package:antirkn_manager/sync/google_account_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'google_account_test.dart' show AccountService;

class Settings implements SettingsStore {
  final values = <String, String>{};
  @override
  Future<String?> readSetting(String key) async => values[key];
  @override
  Future<void> writeSetting(String key, String value) async {
    values[key] = value;
  }
}

class Session implements AutoSyncSession {
  int calls = 0, closed = 0, active = 0, maxActive = 0;
  bool fail = false, receive = false;
  Completer<void>? hold;
  SyncCancellation? cancellation;
  @override
  Future<AutoSyncResult> exchange({
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
  }) async {
    this.cancellation = cancellation;
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (hold != null) await hold!.future;
      cancellation.check();
      if (fail) throw const SyncTransportFailure(SyncTransportIssue.network);
      final accepted = !receive || await apply(() async {});
      return AutoSyncResult(
        waitingForEditor: !accepted,
        lastSuccess: DateTime(2026, 9, 15, 12),
      );
    } finally {
      active--;
    }
  }

  @override
  Future<void> close() async {
    closed++;
  }
}

void main() {
  testWidgets(
    'startup, debounced saves, retry and foreground resume run one worker',
    (tester) async {
      final account = AccountService();
      await account.signIn();
      final changes = StreamController<void>.broadcast();
      final session = Session(), settings = Settings();
      final controller = AutoSyncController(
        accountService: account,
        settings: settings,
        changes: changes.stream,
        openSession: () async => session,
        apply: (receive) async {
          await receive();
          return true;
        },
      );
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(session.calls, 1);
      changes.add(null);
      changes.add(null);
      changes.add(null);
      await tester.pump(Duration.zero);
      await tester.pump(const Duration(milliseconds: 999));
      expect(session.calls, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(session.calls, 2);
      controller.foreground(false);
      await tester.pump(const Duration(minutes: 2));
      expect(session.calls, 2);
      session.fail = true;
      controller.foreground(true);
      await tester.pump(Duration.zero);
      expect(controller.phase, AutoSyncPhase.error);
      session.fail = false;
      await tester.pump(const Duration(seconds: 5));
      expect(controller.phase, AutoSyncPhase.synced);
      expect(session.maxActive, 1);
      await tester.runAsync(controller.stop);
      controller.dispose();
      await tester.runAsync(changes.close);
    },
  );

  testWidgets(
    'sign out joins canceled exchange; disabled preference survives reopening',
    (tester) async {
      final account = AccountService();
      await account.signIn();
      final settings = Settings(),
          session = Session()..hold = Completer<void>();
      final changes = StreamController<void>.broadcast();
      final controller = AutoSyncController(
        accountService: account,
        settings: settings,
        changes: changes.stream,
        openSession: () async => session,
        apply: (_) async => false,
      );
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      var suspended = false;
      final suspending = controller.suspendAccount().then(
        (_) => suspended = true,
      );
      await tester.pump(Duration.zero);
      expect(suspended, isFalse);
      expect(
        () => session.cancellation!.check(),
        throwsA(isA<SyncTransportFailure>()),
      );
      session.hold!.complete();
      await tester.pump(Duration.zero);
      await suspending;
      expect(session.closed, 1);
      await account.signOut();
      await controller.accountChanged(null);
      await tester.pump(const Duration(minutes: 2));
      expect(session.calls, 1);
      await controller.setEnabled(false);
      await tester.runAsync(controller.stop);
      controller.dispose();
      final reopened = AutoSyncController(
        accountService: account,
        settings: settings,
        changes: changes.stream,
        openSession: () async => Session(),
        apply: (_) async => false,
      );
      await tester.pump(Duration.zero);
      expect(reopened.enabled, isFalse);
      await tester.runAsync(reopened.stop);
      reopened.dispose();
      await tester.runAsync(changes.close);
    },
  );

  for (final locale in ['ru', 'en']) {
    testWidgets(
      '$locale settings display auto switch, pending editor status and manual retry',
      (tester) async {
        tester.view.physicalSize = const Size(390, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final account = AccountService();
        await account.signIn();
        final changes = StreamController<void>.broadcast();
        final session = Session()..receive = true;
        final controller = AutoSyncController(
          accountService: account,
          settings: Settings(),
          changes: changes.stream,
          openSession: () async => session,
          apply: (_) async => false,
        );
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: ListView(
                children: [
                  GoogleAccountPanel(service: account, sync: controller),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('google-auto-sync')), findsOneWidget);
        expect(controller.phase, AutoSyncPhase.editing);
        await tester.ensureVisible(
          find.byKey(const ValueKey('google-sync-now')),
        );
        await tester.tap(find.byKey(const ValueKey('google-sync-now')));
        await tester.pumpAndSettle();
        expect(session.calls, 2);
        await tester.ensureVisible(
          find.byKey(const ValueKey('google-auto-sync')),
        );
        await tester.tap(find.byKey(const ValueKey('google-auto-sync')));
        await tester.pumpAndSettle();
        expect(controller.enabled, isFalse);
        expect(
          find.text(
            locale == 'ru'
                ? 'Автосинхронизация выключена.'
                : 'Automatic sync is off.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(controller.stop);
        controller.dispose();
        await tester.runAsync(changes.close);
      },
    );
  }
}
