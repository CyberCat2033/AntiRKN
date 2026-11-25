import 'dart:convert';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/l10n/app_localizations_en.dart';
import 'package:antirkn_manager/l10n/app_localizations_ru.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/runner/relay_strings.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:antirkn_manager/ssh/client_egress_card.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:antirkn_manager/vpn/relay_inbound_view.dart';
import 'package:antirkn_manager/vpn/vpn_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runner_support.dart';

const uuid = '11111111-2222-3333-4444-555555555555';
const link = 'vless://$uuid@relay.example:443?type=tcp&security=reality';
final panelId = 'a' * 32;

class RelayTransport extends FakeRunnerTransport {
  RelayTransport(super.store);
  String planCode = 'ok', stateCode = 'ok', linkCode = 'ok';
  String observedHash = 'f' * 64;
  List<Map<String, Object?>> inbounds = [];
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    final action = request.json['action'] as String;
    if (!action.startsWith('relay_')) {
      return super.request(request, cancellation, sudoPassword: sudoPassword);
    }
    requests.add(request);
    final code = switch (action) {
      'relay_plan' => planCode,
      'relay_state' => stateCode,
      _ => linkCode,
    };
    return RunnerResponse.fromJson({
      'version': 1,
      'code': code,
      'alive': true,
      'jobs': <Object?>[],
      if (code == 'ok')
        'relay': switch (action) {
          'relay_plan' => {'fingerprint': 'e' * 64},
          'relay_link' => {'uri': link},
          _ => {'inbounds': inbounds, 'observedHash': observedHash},
        },
    });
  }

  int count(String action) =>
      requests.where((r) => r.json['action'] == action).length;
}

Map<String, Object?> entry({int id = 7, bool stale = false}) => {
  'panelId': panelId,
  'inboundId': id,
  'tag': 'inbound-443',
  'stale': stale,
};

RelayTarget target({
  bool clientFacing = false,
  bool enabled = true,
  int id = 7,
}) => RelayTarget(
  inboundId: id,
  title: 'Relay',
  linkName: 'Moscow · Relay',
  row: {'id': id, 'listen': '', 'port': 443, 'enabled': enabled},
  clientFacing: clientFacing,
);

void main() {
  late MemoryRunnerJournal store;
  late RelayTransport remote;
  late RunnerController c;
  setUp(() {
    store = MemoryRunnerJournal();
    remote = RelayTransport(store);
    c = RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture|key',
      password: () => null,
      accessFailure: (_) {},
      store: store,
    );
  });
  tearDown(() => c.dispose());

  Future<void> ready() async {
    await c.prepareInstall();
    await c.applyInstall();
    remote.recoveredAccess = {
      'id': panelId,
      'port': 2053,
      'basePath': '/',
      'username': 'antirkn',
      'password': 'A' * 43,
      'panelVersion': '3.7.0',
      'xrayVersion': '26.7.28',
    };
    await c.discoverPanel();
  }

  group('controller', () {
    test('panel verification reads the relay state of this panel', () async {
      remote.inbounds = [
        entry(),
        {...entry(id: 9), 'panelId': 'b' * 32},
      ];
      await ready();
      expect(remote.count('relay_state'), 1);
      expect(c.relayInbounds, [entry()]);
      expect(c.relayEntry(7)?['tag'], 'inbound-443');
      expect(c.relayEntry(9), isNull);
    });

    test('plan, then a durable relay_apply submission', () async {
      await ready();
      expect(
        await c.applyRelay(inboundId: 7, enabled: true),
        isTrue,
        reason: c.responseCode,
      );
      final plan = remote.requests.lastWhere(
        (r) => r.json['action'] == 'relay_plan',
      );
      final submit = remote.requests.lastWhere(
        (r) => r.json['action'] == 'submit',
      );
      final payload = {
        'panelId': panelId,
        'inboundId': 7,
        'enabled': true,
        'observedHash': 'f' * 64,
      };
      expect(jsonDecode(plan.json['payload'] as String), payload);
      expect(submit.json['kind'], 'relay_apply');
      expect(submit.json['count'], 3);
      expect(submit.json['interval'], 1);
      expect(submit.json['fingerprint'], 'e' * 64);
      expect(jsonDecode(submit.json['payload'] as String), payload);
      expect(remote.submitWithoutPersistence, isFalse);
      expect(c.selected?.kind, 'relay_apply');
    });

    test('the observation shown is the one applied; a conflict never '
        'submits', () async {
      await ready();
      remote.observedHash = '0' * 64;
      remote.planCode = 'relay_conflict';
      expect(
        await c.applyRelay(
          inboundId: 7,
          enabled: false,
          observedHash: '1' * 64,
        ),
        isFalse,
      );
      final plan = remote.requests.lastWhere(
        (r) => r.json['action'] == 'relay_plan',
      );
      expect(
        (jsonDecode(plan.json['payload'] as String) as Map)['observedHash'],
        '1' * 64,
      );
      expect(c.responseCode, 'relay_conflict');
      expect(remote.submissions, 0);
      expect(c.pending, isNull);
    });

    test('a terminal relay_apply reads the relay state again', () async {
      await ready();
      await c.applyRelay(inboundId: 7, enabled: true);
      final id = c.selected!.id;
      final before = remote.count('relay_state');
      remote.inbounds = [entry()];
      remote.job = runnerJob(
        id,
        kind: 'relay_apply',
        status: 'succeeded',
        progress: 3,
        count: 3,
        interval: 1,
      );
      await c.selectJob(id);
      expect(remote.count('relay_state'), before + 1);
      expect(c.relayEntry(7), isNotNull);
    });

    test('the link is returned named and never reaches the journal', () async {
      remote.inbounds = [entry()];
      await ready();
      final uri = await c.relayLink(
        inboundId: 7,
        endpoint: 'relay.example',
        externalPort: 443,
        label: 'Moscow · Relay',
      );
      expect(uri, '$link#Moscow%20%C2%B7%20Relay');
      final request = remote.requests.lastWhere(
        (r) => r.json['action'] == 'relay_link',
      );
      expect(jsonDecode(request.json['payload'] as String), {
        'panelId': panelId,
        'inboundId': 7,
        'endpoint': 'relay.example',
        'externalPort': 443,
      });
      final journal = store.value!;
      expect(journal, isNot(contains(uuid)));
      expect(journal, isNot(contains('vless://')));
      expect((jsonDecode(journal) as Map)['relay'], {
        'inbounds': [entry()],
        'observedHash': 'f' * 64,
      });
    });

    test('a rejected panel login asks for the panel login again', () async {
      await ready();
      remote.planCode = 'panel_auth_failed';
      expect(await c.applyRelay(inboundId: 7, enabled: true), isFalse);
      expect(c.responseCode, 'panel_auth_failed');
      expect(c.panelLoginRequired, isTrue);
      expect(remote.submissions, 0);
    });

    test('an unreachable panel keeps the last known state', () async {
      remote.inbounds = [entry()];
      await ready();
      remote.stateCode = 'panel_unreachable';
      remote.inbounds = [];
      await c.refreshRelay();
      expect(c.relayStateIssue, 'panel_unreachable');
      expect(c.relayEntry(7), isNotNull);
      remote.stateCode = 'ok';
      await c.refreshRelay();
      expect(c.relayStateIssue, isNull);
      expect(c.relayEntry(7), isNull);
    });
  });

  test('relay codes have their own messages in every flow', () {
    for (final l in <AppLocalizations>[
      AppLocalizationsRu(),
      AppLocalizationsEn(),
    ]) {
      expect(relayIssue(l, 'relay_client_inbound'), l.relayClientInbound);
      expect(relayIssue(l, 'relay_conflict'), l.relayConflict);
      expect(relayIssue(l, 'relay_missing'), l.relayMissing);
      expect(relayIssue(l, 'relay_unknown_later'), l.relayFailed);
      // vless plan, inbound_remove and protocol_remove refuse with it too.
      expect(runnerCodeLabel(l, 'relay_disable_first'), l.relayDisableFirst);
      expect(vpnMessage(l, 'relay_disable_first'), l.relayDisableFirst);
      expect(runnerEventLabel(l, 'relay_applying'), l.relayApplying);
      expect(runnerEventLabel(l, 'relay_config_failed'), l.relayConfigFailed);
    }
  });

  Widget app(Widget child, {String locale = 'en', double scale = 1}) =>
      MaterialApp(
        locale: Locale(locale),
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

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    // A running job keeps its progress bar moving: no pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  bool switchEnabled(WidgetTester tester) =>
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('relay-switch')))
          .onChanged !=
      null;

  testWidgets('only internal or observed enabled inbounds can turn it on', (
    tester,
  ) async {
    await tester.runAsync(ready);
    c.egress = {'enabled': false, 'observedHash': 'f' * 64};
    for (final (t, enabled) in [
      (target(clientFacing: true), false),
      (target(enabled: false), false),
      (target(), true),
    ]) {
      await tester.pumpWidget(
        app(
          RelayInboundSection(
            key: UniqueKey(),
            controller: c,
            target: t,
            sshHost: 'ssh.example',
            refreshOnOpen: false,
          ),
        ),
      );
      expect(switchEnabled(tester), enabled);
      expect(
        find.byKey(const ValueKey('relay-blocked')),
        findsNWidgets(enabled ? 0 : 1),
      );
    }
    // Egress is off: the explanation says traffic already goes direct.
    expect(find.byKey(const ValueKey('relay-egress-off')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('relay-switch')));
    await settle(tester);
    expect(remote.submissions, 1);
    expect(c.selected?.kind, 'relay_apply');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a relay on a client-facing inbound can still be turned off', (
    tester,
  ) async {
    remote.inbounds = [entry()];
    await tester.runAsync(ready);
    await tester.pumpWidget(
      app(
        RelayInboundSection(
          controller: c,
          target: target(clientFacing: true, enabled: false),
          sshHost: 'ssh.example',
          refreshOnOpen: false,
        ),
      ),
    );
    expect(switchEnabled(tester), isTrue);
    expect(find.byKey(const ValueKey('relay-link')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a stale relay offers to apply again and hides the link', (
    tester,
  ) async {
    remote.inbounds = [entry(stale: true)];
    await tester.runAsync(ready);
    await tester.pumpWidget(
      app(
        RelayInboundSection(
          controller: c,
          target: target(),
          sshHost: 'ssh.example',
          refreshOnOpen: false,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('relay-stale')), findsOneWidget);
    expect(find.byKey(const ValueKey('relay-link')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('relay-apply-again')));
    await settle(tester);
    final plan = remote.requests.lastWhere(
      (r) => r.json['action'] == 'relay_plan',
    );
    expect(
      (jsonDecode(plan.json['payload'] as String) as Map)['enabled'],
      true,
    );
    expect(remote.submissions, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a refused plan shows its localized reason', (tester) async {
    await tester.runAsync(ready);
    remote.planCode = 'relay_client_inbound';
    await tester.pumpWidget(
      app(
        RelayInboundSection(
          controller: c,
          target: target(),
          sshHost: 'ssh.example',
          refreshOnOpen: false,
        ),
        locale: 'ru',
      ),
    );
    await tester.tap(find.byKey(const ValueKey('relay-switch')));
    await settle(tester);
    expect(find.text(AppLocalizationsRu().relayClientInbound), findsOneWidget);
    expect(remote.submissions, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the link is hidden until shown and copied without haptics', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    remote.inbounds = [entry()];
    await tester.runAsync(ready);
    final clipboard = <String>[], haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      app(
        RelayLinkView(
          controller: c,
          inboundId: 7,
          endpoint: 'relay.example',
          externalPort: 443,
          name: 'Moscow · Relay',
        ),
        scale: 2,
      ),
    );
    await settle(tester);
    final named = '$link#Moscow%20%C2%B7%20Relay';
    expect(find.byKey(const ValueKey('relay-link-hidden')), findsOneWidget);
    expect(find.text(named), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('relay-link-reveal')));
    await tester.pumpAndSettle();
    expect(find.text(named), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('relay-link-copy')));
    await tester.pumpAndSettle();
    expect(clipboard, [named]);
    expect(haptics, isEmpty);
    expect(find.text('Link copied'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a lost relay link shows the runner reason', (tester) async {
    remote.inbounds = [entry()];
    await tester.runAsync(ready);
    remote.linkCode = 'relay_missing';
    await tester.pumpWidget(
      app(
        RelayLinkView(
          controller: c,
          inboundId: 7,
          endpoint: 'relay.example',
          externalPort: 443,
          name: 'Relay',
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('relay-link-issue')), findsOneWidget);
    expect(find.text(AppLocalizationsEn().relayMissing), findsOneWidget);
    expect(find.byKey(const ValueKey('relay-link-copy')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the row action opens the settings sheet and reads the state', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(ready);
    final before = remote.count('relay_state');
    await tester.pumpWidget(
      app(
        RelayInboundButton(
          controller: c,
          target: target(),
          sshHost: 'ssh.example',
        ),
        locale: 'ru',
        scale: 2,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('relay-inbound-7')));
    await tester.pump();
    await settle(tester);
    expect(find.byKey(const ValueKey('relay-switch')), findsOneWidget);
    expect(find.text(AppLocalizationsRu().relayHelp), findsOneWidget);
    expect(remote.count('relay_state'), before + 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the internal switch is locked while relay is on', (
    tester,
  ) async {
    final network = NetworkController(reader: const SampleInventoryReader());
    addTearDown(network.dispose);
    final inbound = VlessInbound(
      serverId: 'one',
      spec: {
        ...VlessInbound.defaults(),
        'name': 'Relay',
        'listen': '10.0.0.2',
        'port': 443,
        'endpoint': 'vpn.example',
        'externalPort': 2443,
        'sni': 'example.com',
        'target': 'example.com:443',
        'internal': true,
      },
    );
    await tester.pumpWidget(
      app(
        InboundForm(
          serverId: 'one',
          network: network,
          motion: MotionPreference.off,
          inbound: inbound,
          internalLocked: true,
        ),
      ),
    );
    final tile = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('Internal use'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(tile.value, isTrue);
    expect(tile.onChanged, isNull);
    expect(find.text(AppLocalizationsEn().relayInternalLocked), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final locale in ['ru', 'en']) {
    for (final width in [390.0, 700.0, 1000.0, 1400.0]) {
      testWidgets('relay row, card and settings fit $width at 2x ($locale)', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1600);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        remote.inbounds = [entry(stale: true), entry(id: 8)];
        await tester.runAsync(ready);
        await tester.pumpWidget(
          app(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ResourceTile(
                  title: 'Relay for my servers',
                  subtitle: 'RAW · REALITY',
                  storageId: 'relay',
                  tags: const [RelayInboundBadge(stale: true)],
                  badge: 'On',
                  switchValue: true,
                  note: 'Internal use',
                  actions: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RelayInboundButton(
                        controller: c,
                        target: target(),
                        sshHost: 'ssh.example',
                      ),
                      IconButton(
                        tooltip: 'Internal',
                        onPressed: null,
                        icon: const Icon(Icons.lock_outline),
                      ),
                      IconButton(
                        tooltip: 'Edit',
                        onPressed: () {},
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ],
                  ),
                ),
                ClientEgressCard(controller: c),
                RelayInboundSection(
                  controller: c,
                  target: target(),
                  sshHost: 'ssh.example',
                  refreshOnOpen: false,
                ),
              ],
            ),
            locale: locale,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('client-egress-relay')),
          findsOneWidget,
        );
        final l = locale == 'ru' ? AppLocalizationsRu() : AppLocalizationsEn();
        expect(find.text(l.relayDirectCount(2)), findsOneWidget);
        expect(find.text(l.relayStaleBadge), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
