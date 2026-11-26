import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/catalog_selection.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:antirkn_manager/vpn/adopt_resource.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as f;
import 'ssh_support.dart' as ssh;

Map<String, Object?> spec(String protocol) => {
  'id': 'd' * 32,
  'name': 'Existing node',
  'enabled': true,
  'deleted': false,
  'endpoint': 'vpn.example.com',
  'port': 443,
  'externalPort': 443,
  'adoption': {
    'sourceId': protocol == 'vless' ? '7' : 'e' * 32,
    'observedHash': 'a' * 64,
    if (protocol == 'vless') ...{'panelId': f.panel, 'panelPort': 2053},
  },
  if (protocol == 'vless') ...{'transport': 'tcp', 'security': 'none'},
  if (protocol == 'awg') ...{
    'pool': '10.9.0.0/24',
    'pool6': '',
    'mtu': 1280,
    'keepalive': 0,
  },
  if (protocol == 'tt') ...{
    'domain': 'vpn.example.com',
    'listen': '0.0.0.0',
    'quic': false,
    'outbound': 'direct',
    'socksAddress': '127.0.0.1:1080',
  },
};

class ExistingInboundRunner extends RunnerController {
  ExistingInboundRunner()
    : super(
        serverId: 'one',
        transport: () => null,
        identity: () => 'identity-one',
        password: () => null,
        accessFailure: (_) {},
      ) {
    panelAccess = PanelAccess.fromJson({
      'id': f.panel,
      'port': 2053,
      'managed': false,
      'username': 'fixture',
      'password': 'synthetic-password',
      'panelVersion': '3.7.0',
      'xrayVersion': '26.7.28',
    });
    panelDiscovery = {
      'panels': [
        {
          'port': 2053,
          'source': 'systemd',
          'inbounds': [
            {
              'id': 7,
              'name': 'Existing node',
              'protocol': 'vless',
              'port': 443,
              'network': 'tcp',
              'security': 'none',
              'enabled': true,
            },
          ],
        },
      ],
    };
  }

  @override
  Future<bool> ensureReady() async => true;

  @override
  Future<Map<String, dynamic>?> readInbound(int id) async =>
      jsonDecode(
            jsonEncode({
              'fingerprint': 'a' * 64,
              'row': {
                'id': id,
                'remark': 'Existing node',
                'protocol': 'vless',
                'port': 443,
                'enable': true,
                'streamSettings': {'network': 'tcp', 'security': 'none'},
              },
            }),
          )
          as Map<String, dynamic>;
}

class AdoptionRemote extends f.Remote {
  AdoptionRemote(super.store, this.protocol);
  final String protocol;
  bool reject = false;
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    final r = request.json, action = r['action'];
    final response = <String, dynamic>{
      'version': 1,
      'code': 'ok',
      'alive': true,
      'jobs': <Object?>[],
    };
    actions.add(action as String);
    if (action == '${protocol}_plan') {
      if (reject) {
        return RunnerResponse.fromJson({
          ...response,
          'code': 'vpn_adoption_conflict',
        });
      }
      response[protocol == 'tt' ? 'tt' : '${protocol}Plan'] = {
        'fingerprint': 'e' * 64,
      };
    } else if (action == '${protocol}_state') {
      response[protocol == 'tt' ? 'tt' : '${protocol}State'] = protocol == 'tt'
          ? {'resources': state}
          : state;
    } else if (action == 'submit') {
      expect(
        store.raw,
        contains(r['id']),
        reason: 'Persist the same operation before contacting the server',
      );
      final p = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
      submissions[r['id'] as String] = p;
      state = [
        for (final row in p['resources'] as List)
          {
            'id': row['id'],
            'workspaceId': p['workspaceId'],
            'spec': row,
            'confirmed': true,
            'revision': vlessRevision(Map<String, Object?>.from(p)),
            'proxy': protocol == 'vless'
                ? {
                    'type': 'vless',
                    'tls': false,
                    'servername': '',
                    'network': 'tcp',
                    'udp': true,
                  }
                : protocol == 'awg'
                ? {
                    'type': 'wireguard',
                    'public-key': 'public',
                    'amnezia-wg-option': {'jc': 4},
                    'udp': true,
                  }
                : {
                    'type': 'trusttunnel',
                    'sni': 'vpn.example.com',
                    'quic': false,
                    'udp': true,
                  },
            'clients': [
              for (final u in p['users'] as List)
                {
                  'id': u['id'],
                  'enabled': u['enabled'],
                  'uuid': '22222222-2222-4222-8222-222222222222',
                  'username': u['login'] ?? 'alice',
                  'password': 'synthetic-password',
                  'address': '10.9.0.3',
                  'address6': '',
                  'privateKey': 'private',
                  'presharedKey': 'psk',
                },
            ],
          },
      ];
      jobs[r['id'] as String] = {
        'id': r['id'],
        'kind': '${protocol}_apply',
        'count': r['count'],
        'interval': 1,
        'status': running ? 'running' : 'succeeded',
        'checkpoint': running ? 1 : r['count'],
        'sequence': 1,
        'cancelRequested': false,
        'events': <Object?>[],
      };
      response['jobs'] = [jobs[r['id']]!];
      if (loseReply) {
        loseReply = false;
        throw const SshFailure(SshIssue.disconnected);
      }
    } else if (jobs[r['id']] != null) {
      if (!running) {
        jobs[r['id'] as String] = {
          ...jobs[r['id']]!,
          'status': 'succeeded',
          'checkpoint': jobs[r['id']]!['count'],
        };
      }
      response['jobs'] = [jobs[r['id']]!];
    } else {
      response['code'] = 'missing';
    }
    return RunnerResponse.fromJson(response);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final protocol in ['vless', 'awg', 'tt']) {
    final target = protocol == 'vless' ? 'one' : '$protocol/one';
    test(
      '$protocol: reject stale consent before persisting a resource or submitting',
      () async {
        final store = f.MemoryVpn(),
            remote = AdoptionRemote(f.MemoryVpn(), protocol);
        final c = f.controller(store, {target: remote});
        addTearDown(c.dispose);
        await c.load();
        remote.reject = true;
        await c.adoptResource(
          target: target,
          expectedIdentity: 'identity-$target',
          spec: spec(protocol),
        );
        expect(c.error, 'vpn_adoption_conflict');
        expect(c.workspace.serverIds, isEmpty);
        expect(remote.submissions, isEmpty);
      },
    );
    test(
      '$protocol: confirmed adoption exports access, remains durable after lost reply, rejects second claim',
      () async {
        final store = f.MemoryVpn();
        final remote = AdoptionRemote(store, protocol)..loseReply = true;
        final c = f.controller(store, {target: remote});
        addTearDown(c.dispose);
        await c.load();
        await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
        await c.adoptResource(
          target: target,
          expectedIdentity: 'identity-$target',
          spec: spec(protocol),
        );
        expect(c.adoptionConfirmed(target, 'd' * 32), false);
        expect(remote.submissions, hasLength(1));
        await c.reconcile();
        expect(c.adoptionConfirmed(target, 'd' * 32), true);
        expect(remote.submissions, hasLength(1));
        final restored = VpnWorkspace.decode(store.raw!);
        final serverNames = {vpnServerId(target): 'Managed server'};
        final accesses = protocol == 'vless'
            ? vlessUserAccesses(restored, f.alice, serverNames: serverNames)
            : protocol == 'awg'
            ? awgUserAccesses(restored, f.alice, serverNames: serverNames)
            : ttUserAccesses(restored, f.alice, serverNames: serverNames);
        expect(accesses, hasLength(1));
        expect(accesses.single.fields['server'], 'vpn.example.com');
        expect(
          accesses.single.fields['name'],
          endsWith('Alice_Managed server'),
        );
        final conflicted = restored.copy(
          servers: {
            ...restored.servers,
            target: {
              ...restored.servers[target]!,
              'error': 'vpn_adoption_conflict',
            },
          },
        );
        expect(
          () => protocol == 'vless'
              ? vlessUserAccesses(conflicted, f.alice)
              : protocol == 'awg'
              ? awgUserAccesses(conflicted, f.alice)
              : ttUserAccesses(conflicted, f.alice),
          throwsFormatException,
        );
        await c.adoptResource(
          target: target,
          expectedIdentity: 'identity-$target',
          spec: {...spec(protocol), 'id': 'f' * 32},
        );
        expect(c.error, 'vpn_adoption_conflict');
        expect(remote.submissions, hasLength(1));
      },
    );
  }
  testWidgets('direct exit is offered only with the client egress on', (
    tester,
  ) async {
    final store = f.MemoryVpn();
    final c = f.controller(store, {'one': AdoptionRemote(store, 'vless')});
    final network = NetworkController(reader: const SampleInventoryReader());
    addTearDown(c.dispose);
    addTearDown(network.dispose);
    await c.load();
    const button = ValueKey('relay-inbound-7');
    for (final (egress, relay, shown) in [
      (null, null, false),
      ({'enabled': false}, null, false),
      ({'enabled': true}, null, true),
      // Already a direct exit: it can still be turned off.
      (
        {'enabled': false},
        {
          'inbounds': [
            {'panelId': f.panel, 'inboundId': 7, 'tag': 'in-7', 'stale': false},
          ],
        },
        true,
      ),
    ]) {
      final runner = ExistingInboundRunner()
        ..egress = egress
        ..relay = relay;
      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: SingleChildScrollView(
              child: InboundsPanel(
                controller: c,
                runner: runner,
                serverId: 'one',
                serverHost: 'vpn.example.com',
                serverName: (id) => id,
                network: network,
                motion: MotionPreference.off,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(button),
        shown ? findsOneWidget : findsNothing,
        reason: '$egress $relay',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      runner.dispose();
    }
  });

  testWidgets('people icon opens consent and adopts without any clients', (
    tester,
  ) async {
    final store = f.MemoryVpn();
    final remote = AdoptionRemote(store, 'vless');
    final c = f.controller(store, {'one': remote});
    final runner = ExistingInboundRunner();
    final network = NetworkController(reader: const SampleInventoryReader());
    addTearDown(c.dispose);
    addTearDown(network.dispose);
    await c.load();
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: InboundsPanel(
              controller: c,
              runner: runner,
              serverId: 'one',
              serverHost: 'vpn.example.com',
              serverName: (id) => id,
              network: network,
              motion: MotionPreference.off,
            ),
          ),
        ),
      ),
    );
    final people = find.byKey(const ValueKey('adopt-vless-2053-7'));
    await tester.tap(people);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AdoptedResourceDialog), findsOneWidget);
    expect(remote.submissions, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(c.workspace.inbounds, isEmpty);
    await tester.tap(people);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('adopt-confirm')));
    await tester.pumpAndSettle();
    expect(c.error, isNull);
    expect(c.workspace.users, isEmpty);
    expect(c.workspace.inbounds, hasLength(1));
    expect(remote.submissions.values.single['users'], isEmpty);
    expect(
      c.workspace.inbounds.single.spec['adoption'],
      containsPair('panelId', f.panel),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    runner.dispose();
  });
  for (final language in ['ru', 'en']) {
    testWidgets(
      'adoption consent has no fields and preserves the observed settings: $language',
      (tester) async {
        Map<String, Object?>? result;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open'),
                  onPressed: () async {
                    result = await showDialog<Map<String, Object?>>(
                      context: context,
                      builder: (_) => AdoptedResourceDialog(
                        spec: spec('vless'),
                        consent: true,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            language == 'ru' ? 'Текущие настройки' : 'Existing settings',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text(language == 'ru' ? 'Отмена' : 'Cancel'));
        await tester.pumpAndSettle();
        expect(result, isNull);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.byKey(const ValueKey('adopt-confirm')));
        await tester.pumpAndSettle();
        expect(result, equals(spec('vless')));
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'VLESS selection pencil shares the top title row, selection still works',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = ssh.controller(ssh.FakeVault(), ssh.FakeConnector());
      final c = f.controller(f.MemoryVpn(), {}), selection = CatalogSelection();
      final panel = GlobalKey<InboundsPanelState>();
      addTearDown(c.dispose);
      addTearDown(selection.dispose);
      await tester.runAsync(() async {
        await ssh.prepare(session);
        await session.save();
        await f.setup(c);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.create(Brightness.dark),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: ServerDetailView(
              session: session,
              motion: MotionPreference.off,
              sections: [
                ServerProtocolSection(
                  name: 'VLESS',
                  count: 2,
                  detected: true,
                  selection: selection,
                  selectionActions: () =>
                      panel.currentState!.selectionActions(),
                  child: InboundsPanel(
                    key: panel,
                    selectionInHeader: true,
                    controller: c,
                    selection: selection,
                    serverId: 'one',
                    serverName: (id) => id,
                    network: session.network,
                    motion: MotionPreference.off,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('VLESS'));
      await tester.pumpAndSettle();
      final pencil = find.byKey(const ValueKey('inbound-edit'));
      expect(pencil, findsOneWidget);
      final back = tester.getRect(
        find.byKey(const ValueKey('server-list-back')),
      );
      expect(tester.getRect(pencil).center.dy, back.center.dy);
      expect(find.byType(CatalogTitle), findsNothing);
      await tester.tap(pencil);
      await tester.pumpAndSettle();
      expect(find.text('Selected: 0'), findsOneWidget);
      expect(find.byType(CatalogTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('server-list-back')), findsNothing);
      expect(find.byKey(const ValueKey('vpn-inbound-add')), findsNothing);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('inbound-select-all')))
            .center
            .dy,
        tester.getRect(find.text('Selected: 0')).center.dy,
      );
      await tester.tap(find.byKey(const ValueKey('inbound-select-all')));
      await tester.pumpAndSettle();
      expect(selection.ids, hasLength(2));
      expect(find.text('Selected: 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inbound-delete-selected')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('inbound-confirm-delete')),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();
      expect(c.workspace.inbounds.any((r) => r.deleted), false);
      await tester.tap(find.byKey(const ValueKey('inbound-edit-exit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('server-list-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('vpn-inbound-add')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      session.network.dispose();
    },
  );
}
