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
  Completer<void>? hold;
  @override
  Future<CoreTrafficCheck> probe(
    Map<String, Object?>? proxy,
    CancellationToken cancellation, {
    required bool udp,
  }) async {
    types.add(proxy?['type'] as String? ?? 'direct');
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
}
