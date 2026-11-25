import 'dart:async';
import 'dart:math';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/sync/auto_sync_controller.dart';
import 'package:antirkn_manager/sync/google_account_panel.dart';
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

/// Upper end of the jitter range: retry delays equal their exponential base.
final class _NoJitter implements Random {
  @override
  double nextDouble() => 1;
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
}

class Session implements AutoSyncSession {
  final modes = <bool>[];
  Completer<void>? hold;
  SyncCancellation? cancellation;
  int active = 0, maxActive = 0, closed = 0;
  bool fail = false;
  final failures = <Object>[];
  AutoSyncResult? next;
  @override
  Future<AutoSyncResult> exchange({
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
    bool forceRecovery = false,
  }) async {
    modes.add(forceRecovery);
    this.cancellation = cancellation;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (hold != null) await hold!.future;
      cancellation.check();
      if (fail) throw const SyncTransportFailure(SyncTransportIssue.network);
      if (failures.isNotEmpty) throw failures.removeAt(0);
      return next ?? AutoSyncResult(lastSuccess: DateTime(2026, 9, 23));
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
    'startup retries only pending state; changes and foreground do not upload',
    (tester) async {
      final account = AccountService();
      await account.signIn();
      final changes = StreamController<void>.broadcast();
      final session = Session();
      final controller = AutoSyncController(
        accountService: account,
        settings: Settings(),
        changes: changes.stream,
        openSession: () async => session,
        apply: (_) async => true,
      );
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(session.modes, [true]);
      changes.add(null);
      await tester.pump(const Duration(minutes: 2));
      expect(session.modes, [true]);
      controller.foreground(false);
      await tester.pump(Duration.zero);
      expect(session.modes, [true, false]);
      controller.foreground(true);
      await tester.pump(const Duration(minutes: 2));
      expect(session.modes, [true, false]);
      await tester.runAsync(controller.stop);
      controller.dispose();
      await changes.close();
    },
  );

  testWidgets('disabled auto sync does not upload on background', (
    tester,
  ) async {
    final account = AccountService();
    await account.signIn();
    final settings = Settings();
    final controller = AutoSyncController(
      accountService: account,
      settings: settings,
      changes: const Stream<void>.empty(),
      openSession: () async => Session(),
      apply: (_) async => true,
    );
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
    await tester.runAsync(() => controller.setEnabled(false));
    controller.foreground(false);
    await tester.pump(const Duration(seconds: 2));
    expect(settings.values['googleAutoSync'], 'false');
    expect(controller.phase, AutoSyncPhase.disabled);
    await tester.runAsync(controller.stop);
    controller.dispose();
  });

  testWidgets('exit joins the current worker and saves one latest snapshot', (
    tester,
  ) async {
    final account = AccountService();
    await account.signIn();
    final session = Session()..hold = Completer<void>();
    final controller = AutoSyncController(
      accountService: account,
      settings: Settings(),
      changes: const Stream<void>.empty(),
      openSession: () async => session,
      apply: (_) async => true,
    );
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
    var exited = false;
    final exit = controller.flushOnExit().then((_) => exited = true);
    await tester.pump(Duration.zero);
    expect(exited, isFalse);
    session.hold!.complete();
    session.hold = null;
    await tester.pump(Duration.zero);
    await exit;
    expect(session.modes, [true, false]);
    expect(session.maxActive, 1);
    await tester.runAsync(controller.stop);
    controller.dispose();
  });

  testWidgets('diagnostic pause stops an active worker without a timer retry', (
    tester,
  ) async {
    final account = AccountService();
    await account.signIn();
    final session = Session()..hold = Completer<void>();
    final controller = AutoSyncController(
      accountService: account,
      settings: Settings(),
      changes: const Stream<void>.empty(),
      openSession: () async => session,
      apply: (_) async => true,
    );
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
    final pause = controller.pauseDiagnostics(true);
    await tester.pump(Duration.zero);
    expect(
      () => session.cancellation!.check(),
      throwsA(isA<SyncTransportFailure>()),
    );
    session.hold!.complete();
    session.hold = null;
    await tester.pump(Duration.zero);
    await pause;
    controller.foreground(false);
    await tester.pump(const Duration(minutes: 2));
    expect(session.modes, [true]);
    await tester.runAsync(controller.stop);
    controller.dispose();
  });

  Future<(AutoSyncController, Session)> started(
    WidgetTester tester, [
    Session? value,
  ]) async {
    final account = AccountService();
    await account.signIn();
    final session = value ?? Session();
    final controller = AutoSyncController(
      accountService: account,
      settings: Settings(),
      changes: const Stream<void>.empty(),
      openSession: () async => session,
      apply: (_) async => true,
      random: _NoJitter(),
    );
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
    expect(session.modes, [true]);
    return (controller, session);
  }

  testWidgets(
    'network failure retries with backoff without a lifecycle event',
    (tester) async {
      final (controller, session) = await started(tester);
      session.failures.addAll([
        const SyncTransportFailure(SyncTransportIssue.network),
        const GoogleAccountFailure(GoogleAccountIssue.network),
      ]);
      controller.foreground(false);
      await tester.pump(Duration.zero);
      expect(session.modes, [true, false]);
      expect(controller.phase, AutoSyncPhase.retrying);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(session.modes, [true, false]);
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.modes, [true, false, false]);
      expect(controller.phase, AutoSyncPhase.retrying);
      await tester.pump(const Duration(seconds: 3));
      expect(session.modes, [true, false, false]);
      await tester.pump(const Duration(seconds: 1));
      expect(session.modes, [true, false, false, false]);
      expect(controller.phase, AutoSyncPhase.synced);
      await tester.pump(const Duration(minutes: 10));
      expect(session.modes, hasLength(4));
      await tester.runAsync(controller.stop);
      controller.dispose();
    },
  );

  testWidgets('retry delay grows to five minutes and keeps going', (
    tester,
  ) async {
    final (controller, session) = await started(tester);
    session.failures.addAll(
      List.filled(
        12,
        const SyncTransportFailure(SyncTransportIssue.unavailable),
      ),
    );
    controller.foreground(false);
    await tester.pump(Duration.zero);
    for (var attempt = 0; attempt < 12; attempt++) {
      await tester.pump(const Duration(minutes: 5));
    }
    expect(session.modes.length, 14);
    expect(controller.phase, AutoSyncPhase.synced);
    session.failures.addAll(
      List.filled(9, const SyncTransportFailure(SyncTransportIssue.network)),
    );
    controller.foreground(true);
    controller.foreground(false);
    await tester.pump(Duration.zero);
    // 2+4+…+256 s before the ninth retry; the tenth waits the 5 minute cap.
    await tester.pump(const Duration(seconds: 510));
    expect(session.modes.length, 23);
    await tester.pump(const Duration(minutes: 3));
    expect(session.modes.length, 23);
    await tester.pump(const Duration(minutes: 2));
    expect(session.modes.length, 24);
    await tester.runAsync(controller.stop);
    controller.dispose();
  });

  testWidgets('a failed startup recovery is retried as recovery', (
    tester,
  ) async {
    final account = AccountService();
    await account.signIn();
    final session = Session()
      ..failures.add(const SyncTransportFailure(SyncTransportIssue.network));
    final controller = AutoSyncController(
      accountService: account,
      settings: Settings(),
      changes: const Stream<void>.empty(),
      openSession: () async => session,
      apply: (_) async => true,
      random: _NoJitter(),
    );
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
    expect(session.modes, [true]);
    await tester.pump(const Duration(seconds: 2));
    expect(session.modes, [true, true]);
    expect(controller.phase, AutoSyncPhase.synced);
    await tester.runAsync(controller.stop);
    controller.dispose();
  });

  for (final (name, failure, phase) in [
    (
      'conflict',
      const SyncTransportFailure(SyncTransportIssue.conflict),
      AutoSyncPhase.conflict,
    ),
    (
      'reauthorize',
      const GoogleAccountFailure(GoogleAccountIssue.reauthorize),
      AutoSyncPhase.error,
    ),
    (
      'denied',
      const GoogleAccountFailure(GoogleAccountIssue.denied),
      AutoSyncPhase.error,
    ),
    (
      'repeated unauthorized',
      const SyncTransportFailure(SyncTransportIssue.unauthorized),
      AutoSyncPhase.error,
    ),
    (
      'a newer cloud format',
      const SyncTransportFailure(SyncTransportIssue.unsupportedVersion),
      AutoSyncPhase.error,
    ),
  ]) {
    testWidgets('$name is not retried automatically', (tester) async {
      final (controller, session) = await started(tester);
      session.failures.addAll([failure, failure]);
      controller.foreground(false);
      await tester.pump(Duration.zero);
      if (name == 'repeated unauthorized') {
        // The first 401 invalidated the token and earns one retry.
        expect(controller.phase, AutoSyncPhase.retrying);
        await tester.pump(const Duration(seconds: 2));
      }
      expect(controller.phase, phase);
      final attempts = session.modes.length;
      await tester.pump(const Duration(minutes: 30));
      expect(session.modes, hasLength(attempts));
      expect(controller.phase, phase);
      await tester.runAsync(controller.stop);
      controller.dispose();
    });
  }

  testWidgets('newer cloud snapshot is reported, not as an error', (
    tester,
  ) async {
    final (controller, session) = await started(tester);
    session.next = const AutoSyncResult(remoteNewer: true);
    controller.foreground(false);
    await tester.pump(Duration.zero);
    expect(controller.phase, AutoSyncPhase.remoteNewer);
    expect(controller.transportError, isNull);
    await tester.pump(const Duration(minutes: 10));
    expect(session.modes, [true, false]);
    await tester.runAsync(controller.stop);
    controller.dispose();
  });

  testWidgets('a newer cloud format asks to update the app', (tester) async {
    final (controller, session) = await started(tester);
    session.failures.add(
      const SyncTransportFailure(SyncTransportIssue.unsupportedVersion),
    );
    controller.foreground(false);
    await tester.pump(Duration.zero);
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      expect(syncStatusLabel(l, controller), l.autoSyncUpdateRequired);
    }
    await tester.runAsync(controller.stop);
    controller.dispose();
  });
}
