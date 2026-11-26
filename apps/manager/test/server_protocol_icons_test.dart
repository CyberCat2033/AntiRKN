// Protocol icons, the protocol "more" menu and the software list of a
// server: one icon per protocol everywhere, a menu that stays over its own
// card with a surface apart from it, and the Xray core updated from the
// 3x-ui / Xray row instead of a standalone block.
// ANTIRKN_UI_EVIDENCE=<dir> saves screenshots.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/protocol_icon.dart';
import 'package:antirkn_manager/runner/component_updates_controller.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'component_updates_test.dart' show Source;
import 'runner_support.dart';
import 'ssh_support.dart' as ssh;

Future<void> _loadFonts(WidgetTester tester) => tester.runAsync(() async {
  for (final entry in {
    'Roboto': '/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf',
    'MaterialIcons':
        '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  }.entries) {
    final file = File(entry.value);
    if (!file.existsSync()) continue;
    await (FontLoader(
      entry.key,
    )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
  }
});

Future<void> _evidence(WidgetTester tester, GlobalKey key, String name) async {
  final dir = Platform.environment['ANTIRKN_UI_EVIDENCE'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

// The boundary holds the navigator's overlay, so an open menu is captured.
Widget _app(GlobalKey key, Widget body, {double scale = 1}) => MaterialApp(
  theme: AppTheme.create(Brightness.dark),
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  builder: (context, child) => RepaintBoundary(
    key: key,
    child: MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: child!,
    ),
  ),
  home: Scaffold(body: body),
);

void main() {
  test('each protocol has its own icon', () {
    final icons = {
      for (final c in ['panel', 'trusttunnel', 'amneziawg']) protocolIcon(c),
    };
    expect(icons, hasLength(3));
    expect(protocolIcon('xray'), protocolIcon('panel'));
  });

  for (final width in [390.0, 1000.0]) {
    testWidgets('protocol cards: icons and an end-aligned menu at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = ssh.controller(ssh.FakeVault(), ssh.FakeConnector());
      await tester.runAsync(() async {
        await ssh.prepare(session);
        await session.save();
      });
      await _loadFonts(tester);
      ServerProtocolSection section(String name, int count) =>
          ServerProtocolSection(
            name: name,
            count: count,
            detected: true,
            onRemove: () async => false,
            child: Text(name),
          );
      final key = GlobalKey();
      await tester.pumpWidget(
        _app(
          key,
          ServerDetailView(
            session: session,
            motion: MotionPreference.off,
            sections: [
              section('VLESS', 2),
              section('AmneziaWG', 1),
              section('TrustTunnel', 1),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final (name, component) in [
        ('VLESS', 'panel'),
        ('AmneziaWG', 'amneziawg'),
        ('TrustTunnel', 'trusttunnel'),
      ]) {
        final card = find
            .ancestor(of: find.text(name), matching: find.byType(Card))
            .first;
        expect(
          find.descendant(
            of: card,
            matching: find.byIcon(protocolIcon(component)),
          ),
          findsOneWidget,
        );
      }
      for (final letter in ['V', 'W', 'T']) {
        expect(find.text(letter), findsNothing);
      }
      // The right-hand card at 390, the middle one at 1000: room on the
      // start side, so the menu ends where its button ends.
      final menu = find.byKey(const ValueKey('protocol-menu-AmneziaWG'));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final item = find.byKey(const ValueKey('protocol-remove-AmneziaWG'));
      expect(item, findsOneWidget);
      final colors = AppTheme.create(Brightness.dark).colorScheme;
      final panel = tester
          .widgetList<Material>(
            find.ancestor(of: item, matching: find.byType(Material)),
          )
          .firstWhere((m) => m.color == colors.surfaceContainerHighest);
      expect(panel.elevation, 3);
      final panelRect = tester.getRect(
        find.byWidgetPredicate((w) => identical(w, panel)),
      );
      final button = tester.getRect(menu);
      expect(panelRect.right, closeTo(button.right, 1));
      expect(panelRect.top, greaterThanOrEqualTo(button.bottom - 1));
      // The item keeps the page's reading direction.
      expect(
        Directionality.of(tester.element(find.text('Remove protocol'))),
        TextDirection.ltr,
      );
      expect(tester.takeException(), isNull);
      await _evidence(tester, key, 'server-protocols-menu-${width.toInt()}');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(item, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      session.network.dispose();
    });
  }

  Future<RunnerController> runner(
    WidgetTester tester, {
    String panel = '3.7.0',
  }) async {
    final store = MemoryRunnerJournal();
    final remote = FakeRunnerTransport(store)..installed = true;
    final versions = {
      VpnComponent.panel: panel,
      VpnComponent.xray: '26.7.28',
      VpnComponent.trustTunnel: '1.1.0',
      VpnComponent.amneziaWg: '3.1.20260828',
    };
    final c = RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture',
      password: () => null,
      accessFailure: (_) {},
      store: store,
      software: () => ServerSoftwareInventory(
        observedAt: DateTime.now(),
        facts: {},
        sockets: [],
        components: [
          for (final MapEntry(key: component, value: version)
              in versions.entries)
            ComponentObservation(
              component: component,
              presence: ComponentPresence.detected,
              issues: [],
              installations: [
                ComponentInstallation(
                  source: InstallationSource.binary,
                  identity: '/bin/component',
                  version: InventoryValue.ok(version),
                ),
              ],
            ),
        ],
      ),
    );
    await tester.runAsync(c.refresh);
    c.panelAccess = PanelAccess.fromJson({
      'id': 'a' * 32,
      'port': 43127,
      'basePath': '/${'b' * 24}/',
      'username': 'antirkn',
      'password': 'A' * 43,
      'panelVersion': panel,
      'xrayVersion': '26.7.28',
    });
    return c;
  }

  Widget software(
    GlobalKey key,
    RunnerController c,
    ComponentUpdatesController updates, {
    double scale = 1,
  }) => ComponentUpdatesScope(
    controller: updates,
    child: _app(
      key,
      SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: RunnerPanel(controller: c, motion: MotionPreference.off),
      ),
      scale: scale,
    ),
  );

  for (final width in [390.0, 1000.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('software list at $width, text ×$scale', (tester) async {
        tester.view.physicalSize = Size(width, scale > 1 ? 2000 : 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _loadFonts(tester);
        final c = await runner(tester);
        final updates = ComponentUpdatesController(source: Source())
          ..latest = {
            'panel': '3.11.0',
            'xray': '26.11.9',
            'trusttunnel': '1.3.1',
            'amneziawg': '3.1.20261116',
          };
        final key = GlobalKey();
        await tester.pumpWidget(software(key, c, updates, scale: scale));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final l = AppLocalizations.of(tester.element(find.byType(RunnerPanel)));
        final icons = [
          for (final tile in tester.widgetList<AppIconTile>(
            find.descendant(
              of: find.byType(SummaryCard),
              matching: find.byType(AppIconTile),
            ),
          ))
            tile.icon,
        ];
        expect(icons, [
          protocolIcon('panel'),
          protocolIcon('trusttunnel'),
          protocolIcon('amneziawg'),
        ]);
        // No standalone Xray block and no orphaned caption.
        expect(find.text(l.xrayUpgradeTitle), findsNothing);
        expect(find.text('Components installed on this server'), findsNothing);
        // Every row's Update stays inside its card.
        for (final card in tester.widgetList<SummaryCard>(
          find.byType(SummaryCard),
        )) {
          final rect = tester.getRect(find.byWidget(card));
          for (final button in [
            ...find
                .descendant(
                  of: find.byWidget(card),
                  matching: find.byType(OutlinedButton),
                )
                .evaluate(),
            ...find
                .descendant(
                  of: find.byWidget(card),
                  matching: find.byType(TextButton),
                )
                .evaluate(),
          ]) {
            final r = tester.getRect(find.byWidget(button.widget));
            expect(
              rect.contains(r.topLeft) &&
                  rect.contains(r.bottomRight - const Offset(1, 1)),
              isTrue,
            );
          }
        }
        await _evidence(
          tester,
          key,
          'server-software-${width.toInt()}-x${scale.toInt()}',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        updates.dispose();
      });
    }
  }

  testWidgets('only the core behind: Update runs the checked Xray update', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 3x-ui is at the verified version; only Xray has a newer release.
    final c = await runner(tester, panel: verifiedComponentVersions['panel']!);
    var ready = true, runs = 0;
    c.xrayVersionChoice = XrayVersionChoice(
      install: (_) async {},
      update: () async => runs++,
      ready: () => ready,
      previous: () => null,
    );
    final updates = ComponentUpdatesController(source: Source())
      ..latest = {
        'panel': verifiedComponentVersions['panel']!,
        'xray': '26.11.9',
      };
    await tester.pumpWidget(software(GlobalKey(), c, updates));
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(RunnerPanel)));
    final update = find.byKey(const ValueKey('panel-update'));
    expect(update, findsOneWidget);
    await tester.tap(update);
    await tester.pumpAndSettle();
    expect(runs, 1);
    // Without the connection check the core is not changed.
    ready = false;
    await tester.tap(update);
    await tester.pump();
    expect(runs, 1);
    expect(find.text(l.versionsXrayUnavailable), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    updates.dispose();
  });
}
