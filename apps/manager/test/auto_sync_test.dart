import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/sync/auto_sync_controller.dart';
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
  final modes = <bool>[];
  Completer<void>? hold;
  SyncCancellation? cancellation;
  int active = 0, maxActive = 0, closed = 0;
  bool fail = false;
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
      return AutoSyncResult(lastSuccess: DateTime(2026, 9, 23));
    } finally {
      active--;
    }
  }
  @override
  Future<void> close() async { closed++; }
}

void main() {
  testWidgets('startup retries only pending state; changes and foreground do not upload',
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
  });

  testWidgets('disabled auto sync does not upload on background', (tester) async {
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

  testWidgets('exit joins the current worker and saves one latest snapshot',
      (tester) async {
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

  testWidgets('diagnostic pause stops an active worker without a timer retry',
      (tester) async {
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
    expect(() => session.cancellation!.check(),
        throwsA(isA<SyncTransportFailure>()));
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
}
