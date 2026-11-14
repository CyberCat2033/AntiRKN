import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/ssh/server_reboot_view.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runner_support.dart';
import 'ssh_support.dart';

class FailingThenSucceedingConnector extends FakeConnector {
  int attempts = 0;
  int failUntilAttempt = 4;
  final List<Duration> attemptIntervals = [];
  DateTime? lastAttemptTime;

  @override
  Future<SshConnection> connect(
    SshProfile profile, {
    required Future<bool> Function(TrustedHostKey) verifyHostKey,
    required CancellationToken cancellation,
    List<SshProfile> jumpHosts = const [],
    Future<bool> Function(SshProfile, TrustedHostKey)? verifyJumpHostKey,
  }) async {
    final now = DateTime.now();
    if (lastAttemptTime != null) {
      attemptIntervals.add(now.difference(lastAttemptTime!));
    }
    lastAttemptTime = now;
    attempts++;

    if (attempts < failUntilAttempt) {
      throw const SshFailure(SshIssue.network);
    }
    return super.connect(
      profile,
      verifyHostKey: verifyHostKey,
      cancellation: cancellation,
      jumpHosts: jumpHosts,
      verifyJumpHostKey: verifyJumpHostKey,
    );
  }
}

void main() {
  testWidgets(
    'server reboot polling uses adaptive exponential backoff (2s -> 4s -> 8s -> 15s) without blocking UI',
    (tester) async {
      final v = FakeVault();
      final connector = FailingThenSucceedingConnector();
      final c = controller(v, connector);
      await prepare(c);
      await v.saveProfile(
        SshProfile(
          host: 'fixture.example',
          port: 22,
          username: 'root',
          authMethod: SshAuthMethod.password,
          secrets: {ServerSecret.sshPassword: 'fixture-password-only'},
          hostKey: const TrustedHostKey('ssh-ed25519', 'SHA256:fixture'),
        ),
      );

      final runnerTransport = FakeRunnerTransport(MemoryRunnerJournal());
      runnerTransport.installed = true;
      connector.connection.runner = runnerTransport;

      // Simulate a pending reboot job
      final rebootJob = runnerJob(
        'a' * 32,
        kind: 'server_reboot',
        status: 'running',
        progress: 1,
        count: 2,
      );
      runnerTransport.job = rebootJob;

      // Set pending reboot job BEFORE pumping widget
      c.runner.selected = rebootJob;

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: ServerRebootView(controller: c)),
        ),
      );
      await tester.pump();

      // Initial check fires at 2s:
      // t=0s -> pump 1.9s: attempt 0
      await tester.pump(const Duration(milliseconds: 1900));
      expect(connector.attempts, 0);

      // t=2.0s: Attempt 1 fires and fails -> next backoff = 4s
      await tester.pump(const Duration(milliseconds: 200));
      expect(connector.attempts, 1);

      // t=2s + 3s = 5s: Still waiting on 4s backoff -> no new attempt
      await tester.pump(const Duration(seconds: 3));
      expect(connector.attempts, 1);

      // t=2s + 4s = 6s: Attempt 2 fires and fails -> next backoff = 8s
      await tester.pump(const Duration(seconds: 1));
      expect(connector.attempts, 2);

      // t=6s + 7s = 13s: Still waiting on 8s backoff -> no new attempt
      await tester.pump(const Duration(seconds: 7));
      expect(connector.attempts, 2);

      // t=6s + 8s = 14s: Attempt 3 fires and fails -> next backoff = 15s (clamped to max)
      await tester.pump(const Duration(seconds: 1));
      expect(connector.attempts, 3);

      // t=14s + 14s = 28s: Still waiting on 15s backoff
      await tester.pump(const Duration(seconds: 14));
      expect(connector.attempts, 3);

      // Transition the job to succeeded before attempt 4
      final finishedJob = runnerJob(
        'a' * 32,
        kind: 'server_reboot',
        status: 'succeeded',
        progress: 2,
        count: 2,
      );
      runnerTransport.job = finishedJob;

      // t=14s + 15s = 29s: Attempt 4 fires and succeeds!
      await tester.pump(const Duration(seconds: 1));
      expect(connector.attempts, 4);

      // Allow async refresh to settle
      await tester.pumpAndSettle();
      expect(c.stage, SshStage.connected);

      // Clean up
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
