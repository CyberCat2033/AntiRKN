import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/vpn/connection_check_view.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as f;
import 'adopt_resource_test.dart' as a;

class Net implements IpProbeTransport {
  @override
  Future<ProbeNetwork> network() async => const ProbeNetwork('wifi', 'wifi');
  @override
  Future<void> cancel() async {}
  @override
  Future<IpProbeResult> probe(
    IpProbeTarget target,
    ProbeNetwork network,
    Duration timeout,
    CancellationToken cancellation,
  ) async => const IpProbeResult(IpProbeStatus.reachable, 1);
}

class Probe implements CoreProbeTransport {
  final types = <String>[];
  final proxies = <Map<String, Object?>?>[];
  final downloads = <bool>[];
  Completer<void>? hold;
  @override
  Future<CoreTrafficCheck> probe(
    Map<String, Object?>? proxy,
    CancellationToken cancellation, {
    required bool udp,
    String directInterface = '',
    bool download = false,
  }) async {
    types.add(proxy?['type'] as String? ?? 'direct');
    proxies.add(proxy);
    downloads.add(download);
    if (hold != null) await cancellation.bind(hold!.future);
    cancellation.check();
    return const CoreTrafficCheck(
      status: CoreTrafficStatus.success,
      code: 'connected',
      tcp: true,
      udp: true,
      udpTested: true,
    );
  }
}

class DiagnosticRemote extends f.Remote {
  DiagnosticRemote(super.store, this.cleanup);
  final Map<String, Object?> cleanup;
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    final action = request.json['action'];
    if (action != 'probe_begin' && action != 'probe_end') {
      return super.request(request, token, sudoPassword: sudoPassword);
    }
    actions.add(action as String);
    if (action == 'probe_end') {
      return RunnerResponse.fromJson({
        ...response(),
        'connectionProbe': cleanup,
      });
    }
    final payload = jsonDecode(request.json['payload'] as String) as Map;
    return RunnerResponse.fromJson({
      ...response(),
      'connectionProbe': {
        'user': {
          'id': request.json['id'],
          'login': 'probe',
          'name': 'Probe',
          'enabled': true,
        },
        'observation': {
          'id': payload['resource'],
          'workspaceId': payload['workspace'],
          'spec': payload['spec'],
          'confirmed': true,
          'revision': 'fixture',
          'proxy': {
            'type': 'vless',
            'network': 'tcp',
            'tls': false,
            'udp': true,
            'servername': '',
          },
          'clients': [
            {
              'id': request.json['id'],
              'uuid': '22222222-2222-4222-8222-222222222222',
              'enabled': true,
            },
          ],
        },
      },
    });
  }
}

/// The runner side of a REALITY target check (connectivity_probe).
class TargetRemote extends f.Remote {
  TargetRemote(
    super.store, {
    this.begin = 'ok',
    this.cleanup = const {'closed': true, 'stable': true},
  });
  final String begin;
  final Map<String, Object?> cleanup;
  Map? payload;
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    final action = request.json['action'];
    if (action != 'probe_begin' && action != 'probe_end') {
      return super.request(request, token, sudoPassword: sudoPassword);
    }
    actions.add(action as String);
    if (action == 'probe_end') {
      return RunnerResponse.fromJson({
        ...response(),
        'connectionProbe': cleanup,
      });
    }
    payload = jsonDecode(request.json['payload'] as String) as Map;
    if (begin != 'ok') {
      return RunnerResponse.fromJson({...response(), 'code': begin});
    }
    final key = request.json['id'];
    return RunnerResponse.fromJson({
      ...response(),
      'connectionProbe': {
        'id': key,
        'expires': 1,
        'user': {
          'id': key,
          'login': 'probe-$key',
          'name': 'Probe',
          'enabled': true,
        },
        'observation': {
          'id': key,
          'workspaceId': 'probe',
          'confirmed': true,
          'revision': 'fixture',
          'publicKey': 'B' * 43,
          'shortId': '0123456789abcdef',
          'spec': {
            'id': key,
            'enabled': true,
            'listen': '',
            'port': 23456,
            'transport': 'raw',
            'security': 'reality',
            'target': 'alpha.example:443',
            'sni': 'alpha.example',
            'fingerprint': 'chrome',
            'endpoint': '',
            'externalPort': 23456,
          },
          'clients': [
            {
              'id': key,
              'uuid': '33333333-3333-4333-8333-333333333333',
              'enabled': true,
            },
          ],
        },
      },
    });
  }
}

VpnController create(
  f.MemoryVpn store,
  f.Remote remote,
  Probe probe,
  String target,
) => VpnController(
  repository: store,
  remote: (id) =>
      VpnRemote(transport: remote, panelId: f.panel, identity: 'identity-$id'),
  template: () => f.template,
  connectionProbe: ConnectionProbeEngine(
    core: probe,
    network: Net(),
    controls: [
      for (var i = 1; i <= 10; i++)
        IpControl('c$i', 'p$i', IpProbeTarget('192.0.2.$i', 443)),
    ],
  ),
  timer: (d, f) => Timer(Duration.zero, () {}),
);
Future<void> idle(VpnController c) async {
  for (var i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (!c.busy) return;
  }
  throw StateError('did not finish');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('REALITY target check', () {
    Future<(ConnectionCheck, TargetRemote, Probe)> run(
      TargetRemote Function(f.MemoryVpn) remote,
    ) async {
      final store = f.MemoryVpn(), probe = Probe(), r = remote(store);
      final c = create(store, r, probe, 'one');
      addTearDown(c.dispose);
      await c.load();
      final check = await c.connections.checkRealityTarget(
        serverId: 'one',
        panelId: f.panel,
        endpoint: '203.0.113.10',
        target: 'alpha.example:443',
        sni: 'alpha.example',
      );
      return (check, r, probe);
    }

    test('traffic and 100 KB go through the temporary inbound', () async {
      final (check, remote, probe) = await run(TargetRemote.new);
      expect(check.status, ConnectionCheckStatus.working, reason: check.code);
      expect(remote.actions, ['probe_begin', 'probe_end']);
      expect(remote.payload, {
        'protocol': 'reality_target',
        'panel': f.panel,
        'target': 'alpha.example:443',
        'sni': 'alpha.example',
      });
      final index = probe.proxies.indexWhere((p) => p != null);
      final proxy = probe.proxies[index]!;
      expect(proxy['server'], '203.0.113.10');
      expect(proxy['port'], 23456);
      expect(proxy['servername'], 'alpha.example');
      expect(proxy['flow'], 'xtls-rprx-vision');
      expect((proxy['reality-opts'] as Map)['short-id'], '0123456789abcdef');
      expect(probe.downloads[index], isTrue);
    });

    test('a refused lease is reported and still ended', () async {
      final (check, remote, probe) = await run(
        (s) => TargetRemote(s, begin: 'probe_failed'),
      );
      expect(
        (check.status, check.code),
        (ConnectionCheckStatus.notTested, 'probe_failed'),
      );
      expect(remote.actions, ['probe_begin', 'probe_end']);
      expect(probe.proxies.whereType<Map>(), isEmpty);
    });

    test('an unfinished cleanup replaces a working result', () async {
      final (check, _, _) = await run(
        (s) =>
            TargetRemote(s, cleanup: const {'closed': false, 'stable': false}),
      );
      expect(
        (check.status, check.code),
        (ConnectionCheckStatus.notTested, 'cleanup_pending'),
      );
    });
  });

  for (final (cleanup, expected) in [
    ({'closed': true, 'stable': true}, 'connected'),
    ({'closed': true, 'stable': false}, 'changed'),
    ({'closed': false, 'stable': false}, 'cleanup_pending'),
  ]) {
    test('external VLESS reports $expected after diagnostic cleanup', () async {
      final store = f.MemoryVpn(), probe = Probe();
      final remote = DiagnosticRemote(store, cleanup);
      final c = create(store, remote, probe, 'one');
      addTearDown(c.dispose);
      await c.load();
      final key = c.connections.registerExternal(
        'one',
        a.spec('vless'),
        'identity-one',
      );
      await c.connections.check(key);
      expect(
        probe.types,
        ['vless'],
        reason: '${remote.actions}: ${c.connections.result(key)?.code}',
      );
      expect(remote.actions, ['probe_begin', 'probe_end']);
      expect(c.connections.result(key)?.code, expected);
      expect(c.workspace.users, isEmpty);
      expect(c.workspace.inbounds, isEmpty);
    });
  }
  test(
    'local auto-check waits for successful readback; reload alone does not probe',
    () async {
      final store = f.MemoryVpn(),
          remote = f.Remote(f.MemoryVpn()),
          probe = Probe();
      final realRemote = f.Remote(store);
      final c = create(store, realRemote, probe, 'one');
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      await c.saveInbound(f.inbound('one', '1' * 32));
      await idle(c);
      expect(probe.types, isEmpty);
      await c.prepare();
      await c.apply();
      await idle(c);
      expect(probe.types, ['vless']);
      final bytes = store.raw;
      expect(
        c.connections.result((target: 'one', resource: '1' * 32))?.status,
        ConnectionCheckStatus.working,
      );
      await c.connections.check((target: 'one', resource: '1' * 32));
      expect(store.raw, bytes);
      final freshProbe = Probe(),
          fresh = create(store, realRemote, freshProbe, 'one');
      addTearDown(fresh.dispose);
      await fresh.load();
      await idle(fresh);
      expect(freshProbe.types, isEmpty);
      expect(remote.actions, isEmpty);
    },
  );
  for (final protocol in ['vless', 'awg', 'tt']) {
    test(
      'manual check uses compiled $protocol outbound and discards a stale result',
      () async {
        final store = f.MemoryVpn(), probe = Probe();
        final remote = a.AdoptionRemote(store, protocol);
        final target = protocol == 'awg'
            ? awgTarget('one')
            : protocol == 'tt'
            ? ttTarget('one')
            : 'one';
        final c = create(store, remote, probe, target);
        addTearDown(c.dispose);
        c.connections.setForeground(false);
        await c.load();
        await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
        await c.adoptResource(
          target: target,
          expectedIdentity: 'identity-$target',
          spec: a.spec(protocol),
        );
        expect(c.error, isNull);
        // Adoption is already read back; no local save queue was involved.
        c.connections.setForeground(true);
        await idle(c);
        final key = (target: target, resource: 'd' * 32);
        await c.connections.check(key);
        expect(
          probe.types.last,
          protocol == 'awg'
              ? 'wireguard'
              : protocol == 'tt'
              ? 'trusttunnel'
              : 'vless',
        );
        expect(
          c.connections.result(key)?.status,
          ConnectionCheckStatus.working,
        );
        c.workspace = c.workspace.copy(
          servers: {
            ...c.workspace.servers,
            target: {...c.workspace.servers[target]!, 'identity': 'changed'},
          },
        );
        expect(c.connections.result(key), isNull);
      },
    );
  }
  for (final locale in ['ru', 'en']) {
    testWidgets('connection buttons fit 390px at text scale 2: $locale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = f.MemoryVpn(),
          probe = Probe(),
          remote = f.Remote(f.MemoryVpn());
      final c = create(store, remote, probe, 'one');
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                ConnectionCheckAll(controller: c, targets: const []),
                ConnectionCheckView(
                  controller: c,
                  target: (target: 'one', resource: '1' * 32),
                  onEdit: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'ConnectionCheckView shows unavailable reason when resource unconfirmed',
    (tester) async {
      final store = f.MemoryVpn(),
          probe = Probe(),
          remote = f.Remote(f.MemoryVpn());
      final c = create(store, remote, probe, 'one');
      addTearDown(c.dispose);
      await c.load();
      final inboundId = '1' * 32;
      c.workspace = c.workspace.copy(
        inbounds: [f.inbound('one', inboundId)],
        servers: {
          'one': {
            'identity': 'identity-one',
            'observed': <dynamic>[],
            'pending': null,
            'error': null,
          },
        },
      );
      final key = (target: 'one', resource: inboundId);
      expect(c.connections.available(key), isFalse);
      expect(c.connections.unavailableReasonCode(key), 'vpn_pending_readback');

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: ConnectionCheckView(
              controller: c,
              target: key,
              onEdit: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Сервер ещё не подтвердил этот ресурс.'),
        findsOneWidget,
      );

      c.workspace = c.workspace.copy(
        servers: {
          'one': {
            'identity': 'identity-one',
            'observed': <dynamic>[],
            'pending': null,
            'error': 'vless_conflict',
          },
        },
      );
      expect(c.connections.unavailableReasonCode(key), 'vless_conflict');
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: ConnectionCheckView(
              controller: c,
              target: key,
              onEdit: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Конфигурация сервера изменилась. Обновите сведения и разберите конфликт перед повторным применением.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('connectionCheckMessage formats busy and timeout explicitly', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final l = AppLocalizations.of(ctx);
    final now = DateTime.now().toUtc();
    expect(
      connectionCheckMessage(
        l,
        ConnectionCheck(
          status: ConnectionCheckStatus.notTested,
          code: 'busy',
          at: now,
        ),
      ),
      'Сервер или служба проверки заняты. Повторите попытку через несколько секунд.',
    );
    expect(
      connectionCheckMessage(
        l,
        ConnectionCheck(
          status: ConnectionCheckStatus.notTested,
          code: 'timeout',
          at: now,
        ),
      ),
      'Время ожидания ответа сервера истекло. Проверьте доступность порта и сервера.',
    );
  });

  testWidgets('ConnectionCheckView disables button when another check is busy', (
    tester,
  ) async {
    final store = f.MemoryVpn(),
        probe = Probe(),
        remote = f.Remote(f.MemoryVpn());
    final c = create(store, remote, probe, 'one');
    addTearDown(c.dispose);
    await c.load();
    final inboundId = '1' * 32;
    c.workspace = c.workspace.copy(
      inbounds: [f.inbound('one', inboundId)],
      servers: {
        'one': {
          'identity': 'identity-one',
          'workspaceId': c.workspace.resourceWorkspaceId('one'),
          'observed': [
            {
              'id': inboundId,
              'workspaceId': c.workspace.resourceWorkspaceId('one'),
              'spec': f.inbound('one', inboundId).spec,
              'confirmed': true,
              'revision': '1',
            },
          ],
          'pending': null,
          'error': null,
        },
      },
    );
    final target1 = (target: 'one', resource: inboundId);
    final target2 = (target: 'one', resource: '2' * 32);
    expect(c.connections.available(target1), isTrue);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ConnectionCheckView(
            controller: c,
            target: target1,
            onEdit: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final buttonFinder = find.byKey(
      ValueKey('connection-check-one-$inboundId'),
    );
    expect(tester.widget<TextButton>(buttonFinder).onPressed, isNotNull);

    // Simulate another check in progress (target2 is running, so c.connections.busy is true)
    c.connections.current = target2;
    c.notifyListeners();
    await tester.pump();
    expect(c.connections.busy, isTrue);
    // Button for target1 must now be disabled because c.busy is true
    expect(tester.widget<TextButton>(buttonFinder).onPressed, isNull);

    // When check completes, button becomes enabled again
    c.connections.current = null;
    c.notifyListeners();
    await tester.pump();
    expect(tester.widget<TextButton>(buttonFinder).onPressed, isNotNull);
  });

  test(
    'transient busy does not discard target from pending and expires after 15s',
    () async {
      final store = f.MemoryVpn(), probe = Probe();
      final realRemote = DiagnosticRemote(store, {
        'closed': true,
        'stable': true,
      });
      final c = VpnController(
        repository: store,
        remote: (id) => VpnRemote(
          transport: realRemote,
          panelId: f.panel,
          identity: 'identity-$id',
        ),
        template: () => f.template,
        enterConnectionTraffic: () async => false, // Always busy
        connectionProbe: ConnectionProbeEngine(
          core: probe,
          network: Net(),
          controls: [
            for (var i = 1; i <= 10; i++)
              IpControl('c$i', 'p$i', IpProbeTarget('192.0.2.$i', 443)),
          ],
        ),
        timer: (d, f) => Timer(Duration.zero, () {}),
      );
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      final inbound = f.inbound('one', '1' * 32);
      await c.saveInbound(inbound);
      c.workspace = c.workspace.copy(
        servers: {
          'one': {
            'identity': 'identity-one',
            'workspaceId': c.workspace.resourceWorkspaceId('one'),
            'observed': [
              {
                'id': inbound.id,
                'workspaceId': c.workspace.resourceWorkspaceId('one'),
                'spec': inbound.spec,
                'confirmed': true,
                'revision': '1',
              },
            ],
            'pending': null,
            'error': null,
          },
        },
      );
      final key = (target: 'one', resource: inbound.id);
      expect(c.connections.available(key), isTrue);

      // Running check will encounter enterConnectionTraffic == false
      final result = await c.connections.check(key);
      expect(result?.code, 'busy');
      expect(c.connections.result(key)?.code, 'busy');
    },
  );
}
