import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

void main() {
  testWidgets('late jobs keep scroll and do not restore removed history UI', (
    tester,
  ) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
    final store = MemoryRunnerJournal();
    final remote = FakeRunnerTransport(store)..installed = true;
    final c = RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture|key',
      password: () => null,
      accessFailure: (_) {},
      store: store,
    );
    await c.refresh();
    final bucket = PageStorageBucket();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Future<void> show({bool visible = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: PageStorage(
              bucket: bucket,
              child: visible
                  ? ListView(
                      key: const PageStorageKey('network-workbench'),
                      controller: scroll,
                      children: [
                        const SizedBox(height: 300),
                        RunnerPanel(
                          controller: c,
                          motion: MotionPreference.system,
                        ),
                        const SizedBox(height: 1000),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show();
    scroll.jumpTo(250);
    await tester.pumpAndSettle();
    // The first job arrives after the containing list saved a double offset.
    remote.job = runnerJob('a' * 32, status: 'cancelled', progress: 4);
    await c.refresh();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Job events'), findsNothing);
    expect(find.text('Recent jobs'), findsNothing);

    // A second job creates the history tile after scrolling as well.
    remote.job = null;
    await c.startDiagnostic();
    remote.job = runnerJob(
      c.selected!.id,
      status: 'succeeded',
      progress: 10,
      sequence: 3,
    );
    await c.selectJob(remote.job!.id);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Server check passed'), findsNothing);
    final offset = scroll.offset;
    await show(visible: false);
    await show();
    expect(tester.takeException(), isNull);
    expect(scroll.offset, offset);
    expect(find.text('Job events'), findsNothing);
    expect(find.text('Recent jobs'), findsNothing);
    expect(find.text('Completed · 10/10'), findsNothing);
    await show(visible: false);
    c.dispose();
  });
}
