import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:antirkn_manager/ssh/server_activity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'runner_support.dart';

Map<String, Object?> _event(
  int sequence,
  DateTime at,
  String code,
  int count,
) => {
  'sequence': sequence,
  'timestamp': at.millisecondsSinceEpoch / 1000,
  'code': code,
  'progress': 0,
  'total': count,
};

RunnerJob _job(
  String digit,
  String kind,
  String status,
  int count,
  List<Map<String, Object?>> events, {
  int checkpoint = 0,
  int? sequence,
}) => RunnerJob.fromJson({
  'id': digit * 32,
  'kind': kind,
  'status': status,
  'checkpoint': checkpoint,
  'count': count,
  'interval': 1,
  'sequence': sequence ?? (events.lastOrNull?['sequence'] as int? ?? 1),
  'cancelRequested': false,
  'events': events,
});

void main() {
  final now = DateTime.now();
  final today = now.subtract(const Duration(seconds: 1));
  final yesterday = DateTime(now.year, now.month, now.day - 1, 12);
  final older = DateTime(now.year, now.month, now.day - 5, 9);
  final failedEvents = [
    _event(1, today, 'planned', 3),
    _event(2, today, 'running', 3),
    _event(3, today, 'awg_preparing', 3),
    _event(4, today, 'awg_port_busy', 3),
  ];
  // As the runner lists them: each job with only its last event.
  final failed = _job('a', 'awg_apply', 'failed', 3, failedEvents.sublist(3));
  final running = _job('b', 'vless_apply', 'running', 3, [
    _event(2, today.subtract(const Duration(minutes: 1)), 'vless_applying', 3),
  ], checkpoint: 1);
  final relay = _job('c', 'relay_apply', 'succeeded', 3, [
    _event(5, yesterday, 'succeeded', 3),
  ]);
  final panel = _job('d', 'panel_update', 'succeeded', 6, [
    _event(9, older, 'succeeded', 6),
  ]);
  // Cached before the runner listed events: no time, still shown.
  final reboot = _job('e', 'server_reboot', 'succeeded', 2, const []);

  for (final (width, scale, locale) in [
    (390.0, 2.0, 'ru'),
    (700.0, 1.0, 'en'),
    (1000.0, 2.0, 'en'),
    (1400.0, 1.0, 'ru'),
  ]) {
    testWidgets('recent activity, full list and job details at $width '
        'x$scale $locale', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final l = lookupAppLocalizations(Locale(locale));
      final remote = FakeRunnerTransport(MemoryRunnerJournal())
        ..job = _job('a', 'awg_apply', 'failed', 3, failedEvents);
      final c = RunnerController(
        serverId: 'fixture',
        transport: () => remote,
        identity: () => 'fixture|key',
        password: () => null,
        accessFailure: (_) {},
      );
      // The list order is not time order (a read job moves to the front).
      c.jobs = [relay, reboot, failed, panel, running];
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          theme: AppTheme.create(Brightness.light),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ServerActivitySection(
                runner: c,
                motion: MotionPreference.off,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final hm = DateFormat.Hm(locale);
      expect(find.text(l.uiRecentActivity), findsOneWidget);
      // The latest three, newest first, each naming what it did and when.
      final tiles = find.byType(RunnerJobTile);
      expect(tiles, findsNWidgets(3));
      expect(tester.widgetList<RunnerJobTile>(tiles).map((t) => t.job.id), [
        failed.id,
        running.id,
        relay.id,
      ]);
      expect(find.text('AmneziaWG · ${l.activityApply}'), findsOneWidget);
      expect(
        find.text(
          '${hm.format(today)} · ${l.runnerFailed} · '
          '${runnerEventLabel(l, 'awg_port_busy')}',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          '${hm.format(today.subtract(const Duration(minutes: 1)))} · '
          '${l.runnerRunning} · ${l.uiActivityStep(2, 3)}',
        ),
        findsOneWidget,
      );
      // A time outside today names its date.
      expect(find.textContaining(l.runnerSucceeded), findsOneWidget);
      expect(find.textContaining(hm.format(yesterday)), findsOneWidget);
      expect(
        tester.getSize(find.byType(RunnerJobIcon).first).width,
        lessThanOrEqualTo(24),
      );

      final viewAll = find.byKey(const ValueKey('activity-view-all'));
      await tester.ensureVisible(viewAll);
      await tester.tap(viewAll);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(l.uiActivity), findsOneWidget);
      for (final day in [
        l.uiActivityToday,
        l.uiActivityYesterday,
        DateFormat.yMMMMd(locale).format(older),
        l.uiActivityEarlier,
      ]) {
        expect(find.text(day), findsOneWidget, reason: day);
      }
      expect(find.text(l.serverReboot), findsOneWidget);
      expect(find.text('3x-ui · ${l.activityUpdate}'), findsOneWidget);
      // Inside the day group only the time is repeated.
      expect(
        find.text('${hm.format(yesterday)} · ${l.runnerSucceeded}'),
        findsOneWidget,
      );

      // A row opens the job: its full timeline is read by ID without
      // selecting it (no attention banner for an old failure).
      final row = find.byKey(ValueKey('activity-job-${failed.id}')).last;
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final status = remote.requests.where((r) => r.json['action'] == 'status');
      expect(status.single.id, failed.id);
      expect(status.single.json['cursor'], 0);
      expect(c.selected, isNull);
      expect(c.jobs.length, 5);
      for (final code in ['awg_preparing', 'awg_port_busy']) {
        expect(
          find.text(runnerEventLabel(l, code)),
          findsAtLeastNWidgets(1),
          reason: code,
        );
      }
      expect(find.text(runnerEventLabel(l, 'planned')), findsOneWidget);
      expect(find.text(l.uiActivityStepsUnavailable), findsNothing);
      // The ID only under technical details.
      expect(find.text(failed.id), findsNothing);
      final technical = find.text(l.uiTechnicalDetails);
      await tester.ensureVisible(technical);
      await tester.tap(technical);
      await tester.pumpAndSettle();
      expect(find.text(failed.id), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }

  testWidgets('a job whose timeline cannot be read keeps its last step', (
    tester,
  ) async {
    final l = lookupAppLocalizations(const Locale('en'));
    final remote = FakeRunnerTransport(MemoryRunnerJournal())
      ..failStatus = true;
    final c = RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture|key',
      password: () => null,
      accessFailure: (_) {},
    );
    c.jobs = [failed];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.create(Brightness.dark),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ServerActivitySection(runner: c, motion: MotionPreference.off),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Three or fewer jobs are all on the overview: no "View all".
    expect(find.byKey(const ValueKey('activity-view-all')), findsNothing);
    await tester.tap(find.byType(RunnerJobTile));
    await tester.pumpAndSettle();
    expect(find.text(l.uiActivityStepsUnavailable), findsOneWidget);
    expect(find.text(l.uiActivitySteps), findsOneWidget);
    expect(c.error, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  test('every job kind the runner reports has its own title', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      // The kinds RunnerJob accepts (schemas/runner-v1.json).
      const kinds = [
        'diagnostic',
        'panel_install',
        'panel_update',
        'vless_apply',
        'awg_apply',
        'awg_external_edit',
        'tt_apply',
        'tt_external_edit',
        'tt_certificate',
        'component_install',
        'component_upgrade_apply',
        'protocol_remove',
        'server_reboot',
        'egress_apply',
        'egress_access',
        'relay_apply',
        'inbound_update',
        'inbound_remove',
        'apt_update',
        'apt_upgrade',
        'ssh_harden',
      ];
      final titles = {for (final kind in kinds) runnerJobTitle(l, kind)};
      expect(titles, hasLength(kinds.length));
      expect(titles, isNot(contains(l.uiServerChanges)));
    }
  });

  test('jobs without a time follow the timed ones', () {
    final job = _job('f', 'tt_apply', 'running', 3, [
      _event(1, DateTime.now(), 'running', 3),
    ]);
    expect(runnerJobsByTime([reboot, job, panel]), [job, panel, reboot]);
  });
}
