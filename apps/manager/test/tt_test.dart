import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/network/server_address_field.dart';
import 'package:antirkn_manager/vpn/tt_panel.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as fixtures;

Map<String, Object?> spec() => {
  'id': 'd' * 32,
  'name': 'TT',
  'enabled': true,
  'deleted': false,
  'listen': '0.0.0.0',
  'port': 443,
  'endpoint': '203.0.113.1',
  'externalPort': 443,
  'domain': 'vpn.example.com',
  'certificateId': 'e' * 32,
  'quic': false,
  'ipv6': false,
  'allowPrivate': false,
  'outbound': 'direct',
  'socksAddress': '127.0.0.1:1080',
  'rotation': 0,
};

class TtRemote extends fixtures.Remote {
  TtRemote(super.store);
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
    if (r['action'] == 'tt_plan') {
      reply['tt'] = {'fingerprint': 'e' * 64};
    } else if (r['action'] == 'tt_state') {
      reply['tt'] = {'resources': state};
    } else if (r['action'] == 'submit') {
      expect(store.raw, contains(r['id']));
      if (busyOnce) {
        busyOnce = false;
        return RunnerResponse.fromJson({...reply, 'code': 'busy'});
      }
      final p = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
      expect(p['protocol'], 'tt');
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
                  'username': u['login'],
                  'password': 'synthetic-password-${u['id']}',
                },
            ],
          },
      ];
      jobs[r['id'] as String] = {
        'id': r['id'],
        'kind': 'tt_apply',
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
    'TT-only workflow retries busy runner, exports personal keys and migrates workspace',
    () async {
      final store = fixtures.MemoryVpn();
      // The transport observes the same persisted intent as the coordinator.
      final actual = TtRemote(store);
      final c = fixtures.controller(store, {ttTarget('one'): actual});
      addTearDown(c.dispose);
      await c.load();
      for (final id in [fixtures.alice, fixtures.bob]) {
        await c.saveUser(VpnUser(id: id, login: id, name: id));
      }
      await c.saveTt(TrustTunnelEndpoint(serverId: 'one', spec: spec()));
      await c.prepare();
      expect(c.plans.length, 1);
      await c.apply();
      expect(c.workspace.servers[ttTarget('one')]!['paused'], false);
      await c.reconcile();
      expect(actual.submissions.length, 1);
      expect(c.error, isNull);
      final yaml = c.results[fixtures.alice]!.yaml;
      expect(yaml, contains('synthetic-password-${fixtures.alice}'));
      expect(yaml, isNot(contains('synthetic-password-${fixtures.bob}')));
      expect(
        ttUserAccesses(c.workspace, fixtures.alice).single.fields['type'],
        'trusttunnel',
      );
      expect(VpnWorkspace.decode(c.workspace.encode()).ttEndpoints.length, 1);
      final legacy = jsonDecode(c.workspace.encode()) as Map<String, dynamic>;
      legacy['version'] = 1;
      legacy.remove('ttEndpoints');
      expect(VpnWorkspace.decode(jsonEncode(legacy)).ttEndpoints, isEmpty);
    },
  );
  for (final locale in ['ru', 'en']) {
    testWidgets(
      'Shared TT editor handles SOCKS and advanced fields at width 390 $locale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final network = NetworkController(reader: SampleInventoryReader());
        addTearDown(network.dispose);
        await tester.runAsync(network.load);
        final value = {...spec(), 'outbound': 'socks5'};
        final fields = {
          for (final key in [
            'name',
            'listen',
            'port',
            'endpoint',
            'externalPort',
            'domain',
            'socksAddress',
          ])
            key: TextEditingController(text: '${value[key]}'),
        };
        addTearDown(() {
          for (final f in fields.values) {
            f.dispose();
          }
        });
        var changes = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: AppTheme.create(Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: TtSettingsEditor(
                  fields: fields,
                  spec: value,
                  certificates: [
                    {'id': 'e' * 32, 'domain': 'vpn.example.com'},
                  ],
                  network: network,
                  motion: MotionPreference.off,
                  onChanged: () => changes++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final listen = find.byKey(const ValueKey('tt-listen'));
        expect(find.byType(ServerAddressField), findsOneWidget);
        await tester.enterText(listen, '198.51.100.99');
        expect(fields['listen']!.text, '198.51.100.99');
        expect(changes, 1);
        await tester.tap(find.byKey(const ValueKey('pick-listener')));
        await tester.pumpAndSettle();
        final choice = network
            .choices(AddressRole.listener)
            .firstWhere(
              (choice) =>
                  choice.enabled &&
                  choice.source == AddressChoiceSource.assigned,
            );
        final option = find.byKey(ValueKey('option-${choice.id}'));
        await tester.scrollUntilVisible(
          option,
          180,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('address-options-listener')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(fields['listen']!.text, choice.host);
        expect(changes, 2);
        final socks = find.byKey(const ValueKey('tt-socksAddress'));
        await tester.ensureVisible(socks);
        await tester.enterText(socks, '127.0.0.1:2080');
        final advanced = find.byType(ExpansionTile);
        await tester.ensureVisible(advanced);
        await tester.tap(advanced);
        await tester.pumpAndSettle();
        expect(fields['socksAddress']!.text, '127.0.0.1:2080');

        final outbound = find.byKey(const ValueKey('tt-outbound'));
        await tester.ensureVisible(outbound);
        await tester.tap(outbound);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('app-choice-direct')));
        await tester.pumpAndSettle();
        expect(value['outbound'], 'direct');
        expect(find.byType(BottomSheet), findsNothing);

        final certKey = ValueKey('tt-certificate-${value['certificateId']}-1');
        final certField = find.byKey(certKey);
        await tester.ensureVisible(certField);
        await tester.tap(certField);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('app-choice-')));
        await tester.pumpAndSettle();
        expect(value['certificateId'], '');
        expect(find.byType(BottomSheet), findsNothing);

        expect(tester.takeException(), isNull);
      },
    );
  }
}
