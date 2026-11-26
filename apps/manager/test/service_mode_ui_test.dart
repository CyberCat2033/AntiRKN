import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/ssh/server_about_view.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:antirkn_manager/ssh/server_service_mode_view.dart';
import 'package:antirkn_manager/vpn/connection_check_view.dart';
import 'package:antirkn_manager/vpn/server_operations_banner.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:antirkn_manager/vpn/vpn_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'service_mode_flow_test.dart' as sm;
import 'ssh_support.dart' as ssh;
import 'vpn_controller_test.dart' as f;

SwitchListTile _switch(WidgetTester tester) => tester.widget<SwitchListTile>(
  find.byKey(const ValueKey('service-mode-switch')),
);
bool switchOn(WidgetTester tester) => _switch(tester).value;
bool switchEnabled(WidgetTester tester) => _switch(tester).onChanged != null;

void main() {
  Widget app(Widget child, {required String locale, required double scale}) =>
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
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      );

  Widget section(VpnController c, {bool relay = false}) =>
      ServerServiceModeSection(
        vpn: c,
        serverId: 'two',
        serverName: 'Server two',
        relay: relay,
        motion: MotionPreference.off,
      );

  // A progress bar keeps animating: frames instead of pumpAndSettle.
  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Lets the controller's real async work run until [done].
  Future<void> until(
    WidgetTester tester,
    VpnController c,
    bool Function() condition,
  ) async {
    bool done() => condition() && c.canMutate;
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done(), isTrue);
    await frames(tester);
  }

  Future<void> tap(WidgetTester tester, Key key) async {
    final target = find.byKey(key);
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.runAsync(() => tester.tap(target));
    await frames(tester);
  }

  void noOverflow(WidgetTester tester) =>
      expect(tester.takeException(), isNull);

  for (final (width, scale, locale) in [
    (390.0, 2.0, 'ru'),
    (700.0, 1.0, 'en'),
    (1000.0, 2.0, 'en'),
    (1400.0, 1.0, 'ru'),
  ]) {
    final label = '$width x$scale $locale';
    void size(WidgetTester tester) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
    }

    final l = lookupAppLocalizations(Locale(locale));

    testWidgets('enter, exit with a stalled return, cancel: $label', (
      tester,
    ) async {
      size(tester);
      final (c, _, remotes) = (await tester.runAsync(sm.applied))!;
      await tester.pumpWidget(app(section(c), locale: locale, scale: scale));
      await frames(tester);
      noOverflow(tester);
      expect(find.text(l.serviceModeTitle), findsOneWidget);
      expect(find.text(l.serviceModeOff), findsOneWidget);
      expect(switchOn(tester), isFalse);

      // Entering asks first and names every consequence.
      await tap(tester, const ValueKey('service-mode-switch'));
      noOverflow(tester);
      expect(find.text(l.serviceModeEnterTitle), findsOneWidget);
      for (final text in [
        l.serviceModeEnterIntro('Server two'),
        l.serviceModeEnterProfiles,
        l.serviceModeEnterPublication,
        l.serviceModeEnterNewClients,
        l.serviceModeEnterRevocations,
        l.serviceModeEnterEgressUnknown,
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(find.byKey(const ValueKey('service-mode-egress')), findsNothing);
      // Cancelling changes nothing.
      await tester.runAsync(() => tester.tap(find.text(l.sshCancel)));
      await frames(tester);
      expect(c.serviceModeOf('two'), isNull);

      await tap(tester, const ValueKey('service-mode-switch'));
      await tap(tester, const ValueKey('service-mode-enter-confirm'));
      await until(tester, c, () => c.serviceModeOf('two') != null);
      noOverflow(tester);
      final mode = c.serviceModeOf('two')!;
      expect(mode.state, ServerServiceState.active);
      expect(
        find.text(
          l.serviceModeSince(
            DateFormat.yMd(locale).add_Hm().format(mode.since.toLocal()),
          ),
        ),
        findsOneWidget,
      );
      expect(switchOn(tester), isTrue);

      // A client added meanwhile is counted for the way back.
      await tester.runAsync(() async {
        await c.saveUser(sm.client(sm.carol));
        await c.prepareAndApply();
      });
      await frames(tester);
      expect(c.serviceModeExitNewClients('two'), 1);
      await tap(tester, const ValueKey('service-mode-switch'));
      noOverflow(tester);
      expect(find.text(l.serviceModeExitTitle), findsOneWidget);
      expect(find.text(l.serviceModeExitClients(1)), findsOneWidget);
      expect(find.text(l.serviceModeExitHelp), findsOneWidget);

      // The server is unreachable: the return stalls with its reason.
      final two = remotes.remove('two')!;
      await tap(tester, const ValueKey('service-mode-exit-confirm'));
      await until(
        tester,
        c,
        () =>
            c.serviceModeOf('two')?.state == ServerServiceState.returning &&
            c.serviceModeExitIssue('two') != null,
      );
      noOverflow(tester);
      expect(find.byKey(const ValueKey('service-mode-issue')), findsOneWidget);
      expect(find.text(l.serviceModeReturnStalled), findsOneWidget);
      expect(
        find.text(vpnMessage(l, c.serviceModeExitIssue('two')!)),
        findsOneWidget,
      );
      expect(find.text(l.serviceModeReturningBadge), findsOne);
      expect(switchOn(tester), isTrue);
      expect(switchEnabled(tester), isFalse);
      expect(
        find.byKey(const ValueKey('service-mode-cancel-exit')),
        findsOneWidget,
      );

      // Cancelling keeps it in service mode.
      await tap(tester, const ValueKey('service-mode-cancel-exit'));
      await until(
        tester,
        c,
        () => c.serviceModeOf('two')?.state == ServerServiceState.active,
      );
      noOverflow(tester);
      expect(switchEnabled(tester), isTrue);

      // Reachable again: the exit runs to the end and the section is off.
      remotes['two'] = two;
      await tap(tester, const ValueKey('service-mode-switch'));
      await tap(tester, const ValueKey('service-mode-exit-confirm'));
      await until(tester, c, () => c.serviceModeOf('two') == null);
      noOverflow(tester);
      expect(find.text(l.serviceModeOff), findsOneWidget);
      expect(c.error, isNull);
    });

    testWidgets('a resource gives its test link in the mode: $label', (
      tester,
    ) async {
      size(tester);
      final (c, _, _) = (await tester.runAsync(sm.applied))!;
      final key = (target: 'two', resource: '3' * 32);
      const button = ValueKey(
        'service-test-link-two-33333333333333333333333333333333',
      );
      await tester.pumpWidget(
        app(
          ConnectionCheckView(controller: c, target: key, onEdit: () {}),
          locale: locale,
          scale: scale,
        ),
      );
      await frames(tester);
      expect(find.byKey(button), findsNothing);

      await tester.runAsync(() async {
        await c.enterServiceMode('two');
        await c.reconcile();
      });
      await frames(tester);
      noOverflow(tester);
      await tap(tester, button);
      noOverflow(tester);
      expect(find.text(l.serviceTestLinkHelp), findsOneWidget);
      expect(find.text(l.serviceTestLinkVless), findsOneWidget);
      // Hidden until shown: it grants access.
      expect(
        find.byKey(const ValueKey('service-test-link-hidden')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('service-test-link-qr')), findsNothing);
      await tap(tester, const ValueKey('service-test-link-reveal'));
      noOverflow(tester);
      final text = tester.widget<SelectableText>(
        find.byKey(const ValueKey('service-test-link-text')),
      );
      expect(text.data, c.connections.serviceTestLink(key)!.text);
      expect(text.data, startsWith('vless://'));
      expect(
        find.byKey(const ValueKey('service-test-link-qr')),
        findsOneWidget,
      );
    });

    testWidgets('relay servers are named in the entry dialog: $label', (
      tester,
    ) async {
      size(tester);
      final (c, _, _) = (await tester.runAsync(sm.applied))!;
      await tester.pumpWidget(
        app(section(c, relay: true), locale: locale, scale: scale),
      );
      await frames(tester);
      await tap(tester, const ValueKey('service-mode-switch'));
      noOverflow(tester);
      expect(find.byKey(const ValueKey('service-mode-egress')), findsOneWidget);
      expect(find.text(l.serviceModeEnterEgress), findsOneWidget);
      expect(find.text(l.serviceModeEnterEgressUnknown), findsNothing);
    });

    testWidgets('a return run by another device is taken over: $label', (
      tester,
    ) async {
      size(tester);
      final store = sm.Devices();
      final (a, _, remotes) = (await tester.runAsync(
        () => sm.applied(store: store),
      ))!;
      late VpnController b;
      await tester.runAsync(() async {
        final two = remotes.remove('two')!;
        await a.enterServiceMode('two');
        await a.exitServiceMode('two');
        remotes['two'] = two;
        store.device = sm.deviceB;
        b = f.controller(store, remotes);
        addTearDown(b.dispose);
        await b.load();
      });
      expect(b.serviceModeExitElsewhere('two'), isTrue);
      await tester.pumpWidget(app(section(b), locale: locale, scale: scale));
      await frames(tester);
      noOverflow(tester);
      expect(
        find.byKey(const ValueKey('service-mode-elsewhere')),
        findsOneWidget,
      );
      expect(find.text(l.vpnServiceModeOtherDevice), findsOneWidget);
      expect(find.byKey(const ValueKey('service-mode-issue')), findsNothing);
      expect(find.byKey(const ValueKey('service-mode-progress')), findsNothing);

      await tap(tester, const ValueKey('service-mode-take-over'));
      await until(tester, b, () => b.serviceModeOf('two') == null);
      noOverflow(tester);
      expect(b.error, isNull);
      expect(find.text(l.serviceModeOff), findsOneWidget);
    });

    testWidgets('waiting access changes are shown and sent now: $label', (
      tester,
    ) async {
      size(tester);
      final (c, _, remotes) = (await tester.runAsync(sm.applied))!;
      final two = remotes.remove('two')!;
      await tester.runAsync(() async {
        await c.enterServiceMode('two');
        await c.saveUser(
          c.workspace.userById(f.alice)!.copyWith(enabled: false),
        );
        await c.reconcile();
      });
      expect(c.serviceAccessWaiting('two'), 1);
      expect(c.serviceAccessIssue('two'), isNotNull);
      await tester.pumpWidget(app(section(c), locale: locale, scale: scale));
      await frames(tester);
      noOverflow(tester);
      final notice = find.byKey(const ValueKey('service-access-waiting'));
      expect(notice, findsOneWidget);
      expect(
        tester.widget<AppNotice>(notice).message,
        '${l.serviceAccessWaiting(1)} '
        '${vpnMessage(l, c.serviceAccessIssue('two')!)}',
      );
      expect(tester.widget<AppNotice>(notice).error, isTrue);

      remotes['two'] = two;
      await tap(tester, const ValueKey('service-access-retry'));
      await until(tester, c, () => c.serviceAccessWaiting('two') == 0);
      noOverflow(tester);
      expect(notice, findsNothing);
      // Still in service mode: only the access change went there.
      expect(c.serviceModeOf('two')?.state, ServerServiceState.active);
    });
  }

  testWidgets('busy controller disables the actions with a reason', (
    tester,
  ) async {
    final (c, _, _) = (await tester.runAsync(sm.applied))!;
    c.busy = true;
    addTearDown(() => c.busy = false);
    await tester.pumpWidget(app(section(c), locale: 'en', scale: 1));
    await frames(tester);
    final button = find.byKey(const ValueKey('service-mode-switch'));
    expect(switchEnabled(tester), isFalse);
    final l = lookupAppLocalizations(const Locale('en'));
    expect(
      find.ancestor(of: button, matching: find.byType(Tooltip)),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(of: button, matching: find.byType(Tooltip)),
          )
          .message,
      l.uiBusyChanges,
    );
  });

  testWidgets('About holds the section when VPN state is known', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final (c, _, _) = (await tester.runAsync(sm.applied))!;
    await tester.runAsync(() => c.enterServiceMode('two'));
    final saved = ssh.FakeVault()
      ..mode = VaultMode.system
      ..saved = SshProfile(
        host: 'two.example',
        port: 22,
        username: 'root',
        authMethod: SshAuthMethod.password,
        secrets: const {ServerSecret.sshPassword: 'fixture-password'},
      );
    final session = ssh.controller(saved, ssh.FakeConnector(), serverId: 'two');
    await tester.runAsync(session.initialise);
    await tester.pumpWidget(
      app(
        ServerAboutView(
          controller: session,
          vpn: c,
          clientEgress: const SizedBox.shrink(),
          motion: MotionPreference.off,
        ),
        locale: 'ru',
        scale: 1,
      ),
    );
    await frames(tester);
    noOverflow(tester);
    expect(find.byKey(const ValueKey('service-mode-section')), findsOneWidget);
    expect(switchOn(tester), isTrue);
    // The restart goes last, under every section of the tab.
    final reboot = tester.getTopLeft(
      find.byKey(const ValueKey('server-reboot')),
    );
    for (final above in [
      find.byKey(const ValueKey('service-mode-section')),
      find.text(lookupAppLocalizations(const Locale('ru')).uiDiskSpace),
    ]) {
      expect(tester.getBottomLeft(above).dy, lessThan(reboot.dy));
    }
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    session.network.dispose();
  });

  for (final (width, scale, locale) in [
    (390.0, 2.0, 'ru'),
    (1000.0, 1.0, 'en'),
  ]) {
    testWidgets('the overview names the mode: $width x$scale $locale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final (c, _, _) = (await tester.runAsync(sm.applied))!;
      final session = ssh.controller(
        ssh.FakeVault(),
        ssh.FakeConnector(),
        serverId: 'two',
      );
      await tester.runAsync(() async {
        await ssh.prepare(session);
        session.serverName.text = 'Server two';
        await session.save();
      });
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
            body: ServerDetailView(
              session: session,
              vpn: c,
              motion: MotionPreference.off,
              onBack: () {},
            ),
          ),
        ),
      );
      await frames(tester);
      final badge = find.byKey(const ValueKey('server-overview-service-mode'));
      expect(badge, findsNothing);
      await tester.runAsync(() => c.enterServiceMode('two'));
      expect(c.error, isNull);
      await frames(tester);
      noOverflow(tester);
      final l = lookupAppLocalizations(Locale(locale));
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text(l.serviceModeTitle)),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      session.network.dispose();
    });
  }

  testWidgets('waiting work of a server in service mode says so', (
    tester,
  ) async {
    final (c, _, remotes) = (await tester.runAsync(sm.applied))!;
    // An approved payload left for an unreachable server, then the mode.
    await tester.runAsync(() async {
      remotes.remove('two');
      await c.saveUser(sm.client(sm.carol));
      await c.prepareAndApply();
      await c.enterServiceMode('two');
    });
    final l = lookupAppLocalizations(const Locale('en'));
    expect(c.attention.map((i) => i.serverId), ['two']);
    expect(c.attention.single.needsUser, isFalse);
    await tester.pumpWidget(
      app(
        ServerOperationsBanner(controller: c, serverName: (id) => 'Server $id'),
        locale: 'en',
        scale: 1,
      ),
    );
    await frames(tester);
    noOverflow(tester);
    // Held, not "applying".
    expect(find.text(l.serviceModeHeld), findsOneWidget);
    expect(find.text(l.opsApplying), findsNothing);
    await tester.tap(find.byKey(const ValueKey('server-operations-banner')));
    await frames(tester);
    noOverflow(tester);
    expect(find.widgetWithText(StatusChip, l.serviceModeTitle), findsOne);
    expect(find.text(l.vpnServiceMode), findsWidgets);
  });

  test('service mode codes have their own messages', () {
    for (final l in [
      lookupAppLocalizations(const Locale('ru')),
      lookupAppLocalizations(const Locale('en')),
    ]) {
      expect(vpnMessage(l, 'vpn_service_mode'), l.vpnServiceMode);
      expect(
        vpnMessage(l, 'vpn_service_mode_other_device'),
        l.vpnServiceModeOtherDevice,
      );
      expect(
        vpnMessage(l, 'service_mode_group_empty'),
        l.diagnosticServiceModeGroupEmpty,
      );
    }
  });
}
