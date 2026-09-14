import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/vpn/awg_panel.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as fixtures;

Map<String, Object?> spec() => {
  'id': 'd' * 32,
  'name': 'AWG',
  'enabled': true,
  'deleted': false,
  'endpoint': '203.0.113.1',
  'port': 51820,
  'externalPort': 51820,
  'pool': '10.10.0.0/20',
  'pool6': '',
  'mtu': 1280,
  'keepalive': 25,
  'options': {
    for (final e in awgOptionRules.entries) e.key as String: e.value['default'],
  },
};

class AwgRemote extends fixtures.Remote {
  AwgRemote(super.store);
  bool busyOnce = true;
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    final r = request.json;
    Map<String, dynamic> reply = {
      'version': 1,
      'code': 'ok',
      'alive': true,
      'jobs': <Object?>[],
    };
    if (r['action'] == 'awg_plan') {
      reply['awgPlan'] = {'fingerprint': 'e' * 64};
    } else if (r['action'] == 'awg_state') {
      reply['awgState'] = state;
    } else if (r['action'] == 'submit') {
      expect(store.raw, contains(r['id']));
      if (busyOnce) {
        busyOnce = false;
        return RunnerResponse.fromJson({...reply, 'code': 'busy'});
      }
      final p = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
      expect(p['protocol'], 'awg');
      expect(p['panelId'], p['workspaceId']);
      submissions[r['id'] as String] = p;
      state = [
        for (final s in p['resources'] as List)
          {
            'id': s['id'],
            'workspaceId': p['workspaceId'],
            'spec': s,
            'confirmed': true,
            'revision': vlessRevision(Map<String, Object?>.from(p)),
            'publicKey': 'synthetic-public',
            'headerProtectionKey': 'synthetic-header',
            'clients': [
              for (final u in p['users'] as List)
                {
                  'id': u['id'],
                  'enabled': u['enabled'],
                  'address': '10.10.0.2',
                  'privateKey': 'synthetic-private-${u['id']}',
                  'presharedKey': 'synthetic-psk-${u['id']}',
                },
            ],
          },
      ];
      jobs[r['id'] as String] = {
        'id': r['id'],
        'kind': 'awg_apply',
        'count': r['count'],
        'interval': 1,
        'status': 'succeeded',
        'checkpoint': r['count'],
        'sequence': 1,
        'cancelRequested': false,
        'events': <Object?>[],
      };
      reply['jobs'] = [jobs[r['id']]!];
    } else {
      reply['code'] = jobs.containsKey(r['id']) ? 'ok' : 'missing';
      reply['jobs'] = [if (jobs.containsKey(r['id'])) jobs[r['id']]!];
    }
    return RunnerResponse.fromJson(reply);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'AWG-only workflow retries busy runner, exports personal keys and migrates workspace',
    () async {
      final store = fixtures.MemoryVpn();
      // The transport observes the same persisted intent as the coordinator.
      final actual = AwgRemote(store);
      final c = fixtures.controller(store, {awgTarget('one'): actual});
      addTearDown(c.dispose);
      await c.load();
      for (final id in [fixtures.alice, fixtures.bob]) {
        await c.saveUser(VpnUser(id: id, login: id, name: id));
      }
      await c.saveAwg(AwgInterface(serverId: 'one', spec: spec()));
      await c.prepare();
      expect(c.plans.length, 1);
      await c.apply();
      expect(c.workspace.servers[awgTarget('one')]!['paused'], false);
      await c.reconcile();
      expect(actual.submissions.length, 1);
      expect(c.error, isNull);
      final yaml = c.results[fixtures.alice]!.yaml;
      expect(yaml, contains('synthetic-private-${fixtures.alice}'));
      expect(yaml, isNot(contains('synthetic-private-${fixtures.bob}')));
      expect(
        awgUserAccesses(c.workspace, fixtures.alice).single.fields['type'],
        'wireguard',
      );
      expect(VpnWorkspace.decode(c.workspace.encode()).awgInterfaces.length, 1);
      final legacy = jsonDecode(c.workspace.encode()) as Map<String, dynamic>;
      legacy['version'] = 1;
      legacy.remove('awgInterfaces');
      expect(VpnWorkspace.decode(jsonEncode(legacy)).awgInterfaces, isEmpty);
    },
  );
  for (final locale in ['ru', 'en']) {
    testWidgets('AWG form manual endpoint and linked ports $locale width 390', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final network = NetworkController(reader: SampleInventoryReader());
      addTearDown(network.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.create(Brightness.light),
          home: Scaffold(
            body: AwgForm(
              serverId: 'one',
              spec: {...spec(), 'endpoint': ''},
              network: network,
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final endpoint = find.byKey(const ValueKey('awg-endpoint'));
      expect(tester.widget<TextField>(endpoint).controller!.text, '');
      await tester.enterText(endpoint, '203.0.113.2');
      await tester.enterText(find.byKey(const ValueKey('awg-port')), '51821');
      final advanced = find.byType(ExpansionTile);
      await tester.ensureVisible(advanced);
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('awg-externalPort')))
            .controller!
            .text,
        '51821',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
