import 'dart:convert';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/vpn/client_traffic_controller.dart';
import 'package:antirkn_manager/vpn/client_traffic_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final alice = 'c' * 32, bob = 'd' * 32;
const gib = 1024 * 1024 * 1024;

final months = trafficMonths(DateTime.now());
final current = months.last, previous = months[10];

Map<String, dynamic> user(
  String id,
  int down,
  int up,
  Map<String, List<int>> byMonth,
) => {
  'id': id,
  'down': down,
  'up': up,
  'months': [
    for (final e in byMonth.entries)
      {'month': e.key, 'down': e.value[0], 'up': e.value[1]},
  ],
};

Map<String, dynamic> runnerAnswer() => {
  'readAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  'resources': [
    {
      'protocol': 'vless',
      'id': '1' * 32,
      'state': 'ok',
      'users': [
        user(alice, 10 * gib, gib, {
          current: [3 * gib, gib ~/ 2],
          previous: [5 * gib, gib ~/ 4],
        }),
        user(bob, 1, 1, {}),
      ],
    },
    {
      'protocol': 'awg',
      'id': '2' * 32,
      'state': 'ok',
      'users': [
        user(alice, 2 * gib, 0, {
          current: [gib, 0],
        }),
      ],
    },
    {'protocol': 'tt', 'id': '3' * 32, 'state': 'off', 'users': <Object>[]},
  ],
};

class MemorySettings implements SettingsStore {
  final values = <String, String>{};
  @override
  Future<String?> readSetting(String key) async => values[key];
  @override
  Future<void> writeSetting(String key, String value) async =>
      values[key] = value;
}

ClientTrafficController controller({
  MemorySettings? store,
  Set<String> servers = const {'s1', 's2'},
  Future<ServerTrafficReading> Function(String id, bool connect)? read,
}) => ClientTrafficController(
  servers: () => servers,
  store: store,
  read: (id, token, {connect = false}) async {
    if (read != null) return read(id, connect);
    if (id == 's2' && !connect) {
      throw const FormatException('traffic_not_connected');
    }
    return ServerTrafficReading.fromRunner(runnerAnswer());
  },
);

void main() {
  group('model', () {
    test('runner answer round-trips through the cache form', () {
      final reading = ServerTrafficReading.fromRunner(runnerAnswer());
      final again = ServerTrafficReading.fromRunner(
        jsonDecode(jsonEncode(reading.toJson())) as Map<String, dynamic>,
      );
      expect(again.resources.length, 3);
      expect(
        again.resources.first.users[alice]!.months[previous],
        TrafficUsage(5 * gib, gib ~/ 4),
      );
      expect(
        () =>
            ServerTrafficReading.fromRunner({...runnerAnswer(), 'readAt': -1}),
        throwsFormatException,
      );
      final bad = runnerAnswer();
      (bad['resources'] as List).first['protocol'] = 'vmess';
      expect(() => ServerTrafficReading.fromRunner(bad), throwsFormatException);
    });

    test(
      'summary adds protocols and servers, keeps a server that does not count',
      () {
        final reading = ServerTrafficReading.fromRunner(runnerAnswer());
        final s = ClientTrafficSummary.of(alice, {
          's1': reading,
          's2': reading,
        });
        expect(s.usage(null), TrafficUsage(24 * gib, 2 * gib));
        expect(s.usage(current), TrafficUsage(8 * gib, gib));
        final protocols = s.servers.first.protocols;
        expect(protocols.map((p) => p.protocol), ['vless', 'awg', 'tt']);
        expect(protocols.last.state, TrafficSourceState.off);
        expect(ClientTrafficSummary.of('e' * 32, {}).isEmpty, isTrue);
      },
    );

    test('months run oldest first across a year boundary', () {
      expect(trafficMonths(DateTime.utc(2026, 2, 3), count: 3), [
        '2025-12',
        '2026-01',
        '2026-02',
      ]);
    });
  });

  group('controller', () {
    test(
      'reads servers, keeps failures apart and caches only on the device',
      () async {
        final store = MemorySettings();
        final c = controller(store: store);
        await c.refresh();
        expect(c.readings.keys, ['s1']);
        expect(c.issues, {'s2': 'traffic_not_connected'});
        expect(c.busy, isFalse);
        await c.refresh(connect: true);
        expect(c.readings.keys.toSet(), {'s1', 's2'});
        expect(c.issues, isEmpty);
        final cached = controller(
          store: store,
          read: (id, _) async => throw const FormatException('traffic_failed'),
        );
        await cached.load();
        expect(
          cached.summary(alice).usage(null),
          TrafficUsage(24 * gib, 2 * gib),
        );
        await cached.refresh();
        expect(cached.issues.values.toSet(), {'traffic_failed'});
        expect(
          cached.readings.length,
          2,
        ); // A failed read keeps the last figures.
      },
    );

    test('a fresh reading is not read again on reopening', () async {
      var reads = 0;
      final c = controller(
        servers: {'s1'},
        read: (id, _) async {
          reads++;
          return ServerTrafficReading.fromRunner(runnerAnswer());
        },
      );
      await c.refresh(maxAge: const Duration(minutes: 1));
      await c.refresh(maxAge: const Duration(minutes: 1));
      expect(reads, 1);
      await c.refresh(connect: true); // An explicit refresh always reads.
      expect(reads, 2);
    });

    test('a removed server leaves the cache', () async {
      final store = MemorySettings();
      await controller(store: store).refresh(connect: true);
      final c = controller(store: store, servers: {'s1'});
      await c.refresh();
      expect(
        (jsonDecode(
                  store.values[ClientTrafficController.settingKey]!,
                )['servers']
                as Map)
            .keys,
        ['s1'],
      );
    });
  });

  group('view', () {
    Widget app(Widget child, {double scale = 1}) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    testWidgets(
      'cards show this month and all time; the chart picks the period',
      (tester) async {
        final c = controller(servers: {'s1'});
        await tester.runAsync(c.refresh);
        await tester.pumpWidget(
          app(
            ClientTrafficCards(
              controller: c,
              userId: alice,
              userName: 'Alice',
              serverName: (id) => 'Server $id',
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        expect(find.text('4.0 GiB'), findsOneWidget); // This month: 3 + 1.
        expect(find.text('12.0 GiB'), findsOneWidget); // All time: 10 + 2.
        expect(find.text('All time'), findsOneWidget);

        // The details open in place, under the cards.
        await tester.tap(find.byKey(const ValueKey('client-traffic-month')));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(
          find.byKey(const ValueKey('client-traffic-details-sheet')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('traffic-refresh')), findsOneWidget);
        expect(
          find.textContaining('Per-client statistics are off'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(ValueKey('traffic-bar-$previous')));
        await tester.pumpAndSettle();
        final sheet = find.byKey(
          const ValueKey('client-traffic-details-sheet'),
        );
        expect(
          find.descendant(of: sheet, matching: find.text('5.0 GiB')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Semantics>(
                find
                    .descendant(
                      of: find.byKey(ValueKey('traffic-bar-$previous')),
                      matching: find.byType(Semantics),
                    )
                    .first,
              )
              .properties
              .selected,
          isTrue,
        );

        await tester.tap(find.byKey(const ValueKey('traffic-details-all')));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: sheet,
            matching: find.textContaining('By server · All time'),
          ),
          findsOneWidget,
        );

        // The chosen card again folds the details back into the cards.
        await tester.ensureVisible(
          find.byKey(const ValueKey('traffic-details-all')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('traffic-details-all')));
        await tester.pumpAndSettle();
        expect(sheet, findsNothing);
        expect(
          find.byKey(const ValueKey('client-traffic-all')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('client-traffic-all')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('client-traffic-collapse')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('client-traffic-collapse')));
        await tester.pumpAndSettle();
        expect(sheet, findsNothing);
      },
    );

    testWidgets('only a failed read is named, on its server row', (
      tester,
    ) async {
      final store = MemorySettings();
      await controller(store: store).refresh(connect: true);
      final c = controller(
        store: store,
        read: (id, _) async => throw FormatException(
          id == 's1' ? 'traffic_failed' : 'traffic_not_connected',
        ),
      );
      await tester.runAsync(c.refresh);
      await tester.pumpWidget(
        app(
          ClientTrafficDetails(
            controller: c,
            userId: alice,
            serverName: (id) => 'Server $id',
            month: current,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Could not read now'), findsOneWidget);
      expect(find.byType(AppNotice), findsNothing);
      expect(find.text('Server s1'), findsOneWidget);
      expect(find.text('Server s2'), findsOneWidget);
    });

    for (final (width, scale) in [
      (390.0, 2.0),
      (700.0, 1.0),
      (1000.0, 1.5),
      (1400.0, 1.0),
    ]) {
      testWidgets('details fit at $width wide, text x$scale', (tester) async {
        final c = controller(servers: {'s1', 's2'});
        await tester.runAsync(() => c.refresh(connect: true));
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          app(
            ClientTrafficDetails(
              controller: c,
              userId: alice,
              serverName: (id) => 'A rather long server name $id',
              month: current,
            ),
            scale: scale,
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byType(TrafficChart), findsOneWidget);
      });
    }

    testWidgets('large text stacks the cards without overflow', (tester) async {
      final c = controller(servers: {'s1'});
      await tester.runAsync(c.refresh);
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(
          ClientTrafficCards(
            controller: c,
            userId: alice,
            userName: 'Alice',
            serverName: (id) => id,
          ),
          scale: 2,
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      final month = tester.getRect(
        find.byKey(const ValueKey('client-traffic-month')),
      );
      final all = tester.getRect(
        find.byKey(const ValueKey('client-traffic-all')),
      );
      expect(all.top, greaterThan(month.bottom - 1));
      expect(tester.takeException(), isNull);
    });
  });
}
