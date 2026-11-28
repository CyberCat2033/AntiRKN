import 'dart:convert';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:antirkn_manager/vpn/reality_search_controller.dart';
import 'package:antirkn_manager/vpn/reality_target_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime.utc(2026, 11, 28);

class Settings implements SettingsStore {
  final values = <String, String>{};
  @override
  Future<String?> readSetting(String key) async => values[key];
  @override
  Future<void> writeSetting(String key, String value) async =>
      values[key] = value;
}

TlsProbeResult observe(TlsScanTarget t) {
  if (t.ip.bytes.last != 10) {
    return TlsProbeResult(target: t, reach: TlsReach.refused);
  }
  return TlsProbeResult(
    target: t,
    reach: TlsReach.ok,
    handshake: TlsHandshake.ok,
    tls: const Duration(milliseconds: 35),
    version: '1.3',
    alpn: 'h2',
    group: 'X25519MLKEM768',
    dns: t.sni.isEmpty ? TlsDnsCheck.notChecked : TlsDnsCheck.match,
    certificate: TlsCertificateInfo(
      names: const ['alpha.example'],
      namesTotal: 1,
      commonName: 'alpha.example',
      issuer: '=HYPERLINK("x")',
      notBefore: DateTime.utc(2026),
      notAfter: DateTime.utc(2027, 6),
      check: t.sni.isEmpty
          ? TlsCertificateCheck.chainOnly
          : TlsCertificateCheck.valid,
    ),
  );
}

final class World implements TlsScanTransport {
  int probes = 0;
  int batches = 0;

  /// Called before each batch answers, e.g. to stop the search at batch N.
  void Function(int batch)? onBatch;
  @override
  Future<TlsScanBatch> scan(
    List<TlsScanTarget> targets,
    CancellationToken cancellation, {
    TlsScanLimits limits = const TlsScanLimits(),
    bool resolve = true,
    String directInterface = '',
  }) async {
    onBatch?.call(++batches);
    if (cancellation.isCancelled) {
      return TlsScanBatch(status: TlsScanStatus.cancelled, code: 'cancelled');
    }
    probes += targets.length;
    return TlsScanBatch(
      status: TlsScanStatus.scanned,
      code: 'scanned',
      probes: [for (final t in targets) observe(t)],
    );
  }
}

RealitySearchController controller(
  World world,
  Settings settings, {
  ProbeNetwork network = const ProbeNetwork('wifi-1', 'wifi'),
  Future<Map<String, dynamic>?> Function(String, String)? fromServer,
}) => RealitySearchController(
  serverId: 'server-1',
  store: settings,
  checkFromServer: fromServer,
  clock: () => now,
  search: RealityTargetSearch(
    transport: world,
    network: () async => network,
    pause: Duration.zero,
    clock: () => now,
  ),
);

Widget app(Widget home, {Locale locale = const Locale('en')}) => MaterialApp(
  theme: AppTheme.create(Brightness.light),
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void main() {
  group('controller', () {
    test('a finished search is saved and offered after a restart', () async {
      final settings = Settings(), world = World();
      final first = controller(world, settings);
      await first.ready;
      await first.start(RealitySearchPlan.neighbors('8.8.8.37'));
      expect(first.state!.phase, RealitySearchPhase.done);
      expect(first.best!.target.key, '8.8.8.10|443|alpha.example');
      expect(realityChoice(first.best!), (
        target: 'alpha.example:443',
        sni: 'alpha.example',
      ));
      await Future<void>.delayed(Duration.zero);
      final again = controller(world, settings);
      await again.ready;
      expect(again.best!.target.key, first.best!.target.key);
      await again.checkNetwork();
      expect(again.otherNetwork, isFalse);
      final elsewhere = controller(
        world,
        settings,
        network: const ProbeNetwork('lte-2', 'cellular'),
      );
      await elsewhere.ready;
      await elsewhere.checkNetwork();
      expect(elsewhere.otherNetwork, isTrue);
      expect(elsewhere.resumable, isFalse);
    });

    test('an interrupted search continues without probing again', () async {
      final settings = Settings(), world = World();
      final first = controller(world, settings);
      world.onBatch = (n) {
        if (n == 4) first.stop();
      };
      await first.start(RealitySearchPlan.neighbors('8.8.8.37'));
      expect(first.state!.phase, RealitySearchPhase.cancelled);
      final done = first.state!.discoveries.length;
      expect(done, 3 * 16);
      world.onBatch = null;
      await Future<void>.delayed(Duration.zero);
      final probed = world.probes;
      final again = controller(world, settings);
      await again.ready;
      expect(again.resumable, isTrue);
      await again.resume();
      expect(again.state!.phase, RealitySearchPhase.done);
      expect(world.probes - probed, 253 - done + 1 + 1);
    });

    test('exports carry observations and keep spreadsheets inert', () async {
      final c = controller(World(), Settings());
      await c.start(RealitySearchPlan.explicit(['8.8.8.10']));
      final csv = c.exportCsv();
      expect(csv, contains('"8.8.8.10","443","alpha.example","criteria"'));
      expect(csv, contains('"\'=HYPERLINK(""x"")"'));
      final json = jsonDecode(c.exportJson()) as Map<String, dynamic>;
      expect((json['candidates'] as List).single['level'], 'criteria');
      expect(json.keys, isNot(contains('checkpoint')));
    });
  });

  group('server check', () {
    test('the best pairs are checked by the server after a search', () async {
      final settings = Settings(), calls = <(String, String)>[];
      final c = controller(
        World(),
        settings,
        fromServer: (target, sni) async {
          calls.add((target, sni));
          return {'feasible': true, 'latencyMs': 18};
        },
      );
      await c.start(RealitySearchPlan.neighbors('8.8.8.37'));
      expect(calls, [('alpha.example:443', 'alpha.example')]);
      expect(c.best!.level, RealityLevel.serverChecked);
      expect(c.best!.fromServer!.latency, const Duration(milliseconds: 18));
      expect(c.serverUnavailable, isFalse);
      expect(c.exportCsv(), contains('"18"'));
      await Future<void>.delayed(Duration.zero);
      final again = controller(World(), settings);
      await again.ready;
      expect(again.best!.level, RealityLevel.serverChecked);
    });

    test('an unreachable panel is stated and nothing is recorded', () async {
      var calls = 0;
      final c = controller(
        World(),
        Settings(),
        fromServer: (_, _) async {
          calls++;
          return null;
        },
      );
      await c.start(RealitySearchPlan.neighbors('8.8.8.37'));
      expect(calls, 1);
      expect(c.serverUnavailable, isTrue);
      expect(c.best!.level, RealityLevel.criteria);
    });

    test('a pair the server rejects is no longer recommended', () async {
      final c = controller(
        World(),
        Settings(),
        fromServer: (_, _) async => {'feasible': false, 'latencyMs': 30},
      );
      await c.start(RealitySearchPlan.neighbors('8.8.8.37'));
      expect(c.best, isNull);
      expect(
        c.candidates.single.reasons,
        contains(RealityReason.serverRejected),
      );
    });
  });

  group('page', () {
    RealityTargetChoice? chosen;
    Future<void> open(
      WidgetTester tester,
      RealitySearchController c, {
      String server = '8.8.8.37',
      Locale locale = const Locale('en'),
    }) async {
      chosen = null;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => chosen = await showRealityTargetSearch(
                  context,
                  controller: c,
                  serverAddress: server,
                  motion: MotionPreference.off,
                ),
                child: const Text('open'),
              ),
            ),
          ),
          locale: locale,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    for (final width in [390.0, 700.0, 1000.0, 1400.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('finds and uses a target at $width dp, text ×$scale', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final c = controller(World(), Settings());
          await open(tester, c);
          expect(find.text('Server neighbours'), findsOneWidget);
          expect(find.textContaining('253 addresses'), findsOneWidget);
          final list = find.byType(Scrollable).first;
          final start = find.byKey(const ValueKey('reality-search-start'));
          await tester.scrollUntilVisible(start, 100, scrollable: list);
          await tester.ensureVisible(start);
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.tap(start);
            await tester.pump();
            while (c.running) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
          });
          await tester.pumpAndSettle();
          expect(find.text('Search finished'), findsOneWidget);
          // Details of the best candidate sit beside the list when wide.
          expect(
            find.text('Why'),
            width >= AppLayout.expanded ? findsOneWidget : findsNothing,
          );
          final use = find.byKey(
            const ValueKey('reality-use-8.8.8.10|443|alpha.example'),
          );
          await tester.scrollUntilVisible(use, 100, scrollable: list);
          expect(find.text('Recommended'), findsOneWidget);
          await tester.pumpAndSettle();
          await tester.tap(use);
          await tester.pumpAndSettle();
          expect(find.byType(RealityTargetPage), findsNothing);
          expect(chosen, (target: 'alpha.example:443', sni: 'alpha.example'));
        });
      }
    }

    testWidgets('a phone opens candidate details in a sheet', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = controller(World(), Settings());
      await tester.runAsync(() async {
        await c.start(RealitySearchPlan.neighbors('8.8.8.37'));
        await open(tester, c);
      });
      await tester.tap(find.text('alpha.example').first);
      await tester.pumpAndSettle();
      expect(find.text('Why'), findsOneWidget);
      expect(find.text('alpha.example:443'), findsOneWidget);
      expect(find.text('8.8.8.10:443'), findsOneWidget);
    });

    testWidgets('a server-checked pair shows its time; others can be checked', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const answer = <String, dynamic>{'feasible': true, 'latencyMs': 18};
      Map<String, dynamic>? reply;
      final c = controller(
        World(),
        Settings(),
        fromServer: (_, _) async => reply,
      );
      await tester.runAsync(
        () => c.start(RealitySearchPlan.neighbors('8.8.8.37')),
      );
      expect(c.serverUnavailable, isTrue);
      await open(tester, c);
      expect(
        find.textContaining('server check is unavailable'),
        findsOneWidget,
      );
      reply = answer;
      final check = find.byKey(
        const ValueKey('reality-server-8.8.8.10|443|alpha.example'),
      );
      await tester.scrollUntilVisible(
        check,
        100,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(find.text('From the server: 18 ms'), findsOneWidget);
      expect(find.textContaining('server check is unavailable'), findsNothing);
    });

    testWidgets('without a server address only own addresses are offered', (
      tester,
    ) async {
      final c = controller(World(), Settings());
      await tester.runAsync(() => open(tester, c, server: ''));
      expect(find.textContaining('public IPv4 is unknown'), findsOneWidget);
      expect(find.text('Own addresses'), findsOneWidget);
      final start = tester.widget<FilledButton>(
        find.byKey(const ValueKey('reality-search-start')),
      );
      expect(start.onPressed, isNull);
    });

    testWidgets('a VPN that could not be bypassed is stated', (tester) async {
      final c = controller(
        World(),
        Settings(),
        network: const ProbeNetwork('wifi-1', 'wifi', vpn: true),
      );
      await tester.runAsync(() async {
        await c.start(RealitySearchPlan.explicit(['8.8.8.10']));
        await open(tester, c, locale: const Locale('ru'));
      });
      expect(find.textContaining('включён VPN'), findsOneWidget);
    });
  });

  test('generated XHTTP paths look like site resources and differ', () {
    final paths = {for (var i = 0; i < 50; i++) newXhttpPath()};
    expect(paths.length, 50);
    for (final p in paths) {
      expect(p, matches(RegExp(r'^/[a-z0-9]+/[a-z0-9]{10}$')));
    }
    expect(isDefaultXhttpPath('/'), isTrue);
    expect(isDefaultXhttpPath(' '), isTrue);
    expect(isDefaultXhttpPath('/mine'), isFalse);
  });

  testWidgets('the form takes the chosen pair and the cached suggestion', (
    tester,
  ) async {
    final c = controller(World(), Settings());
    await tester.runAsync(
      () => c.start(RealitySearchPlan.explicit(['8.8.8.10'])),
    );
    final network = NetworkController(reader: const SampleInventoryReader());
    await tester.pumpWidget(
      app(
        Scaffold(
          body: InboundForm(
            serverId: 'server-1',
            network: network,
            motion: MotionPreference.off,
            findTarget: (_) async =>
                (target: '8.8.8.20:443', sni: 'beta.example'),
            suggested: c.best,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    TextField field(String key) => tester.widget<TextField>(
      find.descendant(
        of: find.byKey(ValueKey('vpn-inbound-$key')),
        matching: find.byType(TextField),
        matchRoot: true,
      ),
    );
    expect(
      find.textContaining('From the search: alpha.example'),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('vpn-reality-suggested')),
    );
    await tester.tap(find.byKey(const ValueKey('vpn-reality-suggested')));
    await tester.pumpAndSettle();
    expect(field('target').controller!.text, 'alpha.example:443');
    expect(field('sni').controller!.text, 'alpha.example');
    expect(find.byKey(const ValueKey('vpn-reality-suggested')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('vpn-reality-find')));
    await tester.pumpAndSettle();
    expect(field('target').controller!.text, '8.8.8.20:443');
    expect(field('sni').controller!.text, 'beta.example');
    expect(find.text('Check'), findsOneWidget);
  });

  for (final (path, generated) in [('/', true), ('/mine', false)]) {
    testWidgets('checking an XHTTP target with path $path', (tester) async {
      final network = NetworkController(reader: const SampleInventoryReader());
      await tester.pumpWidget(
        app(
          Scaffold(
            body: InboundForm(
              serverId: 'server-1',
              network: network,
              motion: MotionPreference.off,
              scanReality: (target, sni) async => {'feasible': true},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transport-raw')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('XHTTP').last);
      await tester.pumpAndSettle();
      Finder input(String key) => find.descendant(
        of: find.byKey(ValueKey('vpn-inbound-$key')),
        matching: find.byType(EditableText),
        matchRoot: true,
      );
      await tester.enterText(input('target'), 'alpha.example:443');
      if (path != '/') await tester.enterText(input('path'), path);
      await tester.pumpAndSettle();
      final scan = find.byKey(const ValueKey('vpn-reality-scan'));
      await tester.ensureVisible(scan);
      await tester.tap(scan);
      await tester.pumpAndSettle();
      final value = tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const ValueKey('vpn-inbound-path')),
              matching: find.byType(TextField),
              matchRoot: true,
            ),
          )
          .controller!
          .text;
      if (generated) {
        expect(value, matches(RegExp(r'^/[a-z0-9]+/[a-z0-9]{10}$')));
      } else {
        expect(value, '/mine');
      }
    });
  }
}
