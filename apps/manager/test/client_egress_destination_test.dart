import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/ssh/client_egress_card.dart';
import 'package:antirkn_manager/ssh/server_catalog_controller.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'network_support.dart';
import 'runner_support.dart';
import 'ssh_support.dart' as ssh;

class _Repository extends MemoryRunnerJournal implements ServerRepository {
  final vault = ssh.FakeVault();
  @override
  bool get needsLegacyPassword => false;
  @override
  Future<void> migrateLegacy({String? password}) async {}
  @override
  Future<List<SavedServer>> listServers() async => vault.saved == null
      ? []
      : [SavedServer(vault.saved!.id, vault.saved!, 1)];
  @override
  Future<SecretVault> openServer(String id) async => vault;
  @override
  String newServerId() => 'exit';
  @override
  Future<void> deleteServers(List<SavedServer> expected) async =>
      vault.saveProfile(null);
}

class _DestinationTransport extends FakeRunnerTransport {
  _DestinationTransport(super.store);
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    if (request.json['action'] == 'egress_access_plan') {
      requests.add(request);
      return RunnerResponse.fromJson({
        'version': 1,
        'code': 'egress_conflict',
        'alive': true,
        'jobs': <Object?>[],
      });
    }
    return super.request(request, cancellation, sudoPassword: sudoPassword);
  }
}

class _Catalog extends ServerCatalogController {
  _Catalog(this.session, SshProfile profile)
    : super(
        repository: session.repository!,
        connector: ssh.FakeConnector(),
        picker: ssh.FakeKeyPicker(),
        reader: TestInventoryReader(() async => testInventory()),
      ) {
    servers = [SavedServer('exit', profile, 1)];
  }
  final SshController session;
  @override
  SshController? sessionFor(String id) => id == 'exit' ? session : null;
  @override
  Future<bool> connectForAction(String id) => session.runner.ensureReady();
}

void main() {
  testWidgets(
    'About Server egress uses hidden inbound addresses and standard choice sheets',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository();
      final remote = _DestinationTransport(repository)
        ..installed = true
        ..recoveredAccess = {
          'id': 'a' * 32,
          'port': 2053,
          'basePath': '/',
          'username': 'antirkn',
          'password': 'A' * 43,
          'panelVersion': '3.7.0',
          'xrayVersion': '26.7.28',
        }
        ..discovery = {
          'failed': false,
          'cliAvailable': true,
          'panels': [
            {
              'source': 'systemd',
              'port': 2053,
              'inbounds': [
                {
                  'id': 5,
                  'name': 'First exit',
                  'enabled': true,
                  'protocol': 'vless',
                  'listen': '203.0.113.20',
                  'port': 443,
                },
                {
                  'id': 9,
                  'name': 'Second exit',
                  'enabled': true,
                  'protocol': 'vless',
                  'listen': '203.0.113.30',
                  'port': 8443,
                },
              ],
            },
          ],
        };
      final vault = repository.vault;
      final connector = ssh.FakeConnector()..connection.runner = remote;
      final session = ssh.controller(
        vault,
        connector,
        serverId: 'exit',
        repository: repository,
      );
      await ssh.prepare(session);
      session.host.text = '203.0.113.10';
      await session.save();
      vault.saved = vault.saved!.withHostKey(connector.key);
      await session.connect();
      await session.runner.waitUntilIdle();
      expect(session.runner.panelAccess, isNotNull);
      expect(session.runner.error, isNull);
      expect(await session.runner.ensureReady(), isTrue);
      expect(session.runner.panels.single['inbounds'], hasLength(2));
      final catalog = _Catalog(session, vault.saved!);
      final source = RunnerController(
        serverId: 'source',
        transport: () => null,
        identity: () => null,
        password: () => null,
        accessFailure: (_) {},
      )..egress = {'enabled': false, 'observedHash': 'f' * 64};

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ServerDetailView(
              session: session,
              motion: MotionPreference.reduced,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ClientEgressCard), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('server-about')));
      await tester.tap(find.byKey(const ValueKey('server-about')));
      await tester.pumpAndSettle();
      expect(find.byType(ClientEgressCard), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ClientEgressForm(controller: source, catalog: catalog),
          ),
        ),
      );
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byKey(const ValueKey('client-egress-address')), findsNothing);
      expect(
        find.byKey(const ValueKey('client-egress-external-port')),
        findsNothing,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('client-egress-port')))
            .controller!
            .text,
        '1080',
      );
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('client-egress-server')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-choice-exit')));
      await tester.pumpAndSettle();

      Future<void> expectDestination(String host, int port) async {
        await tester.tap(find.byKey(const ValueKey('client-egress-apply')));
        await tester.pumpAndSettle();
        final plan = remote.requests.lastWhere(
          (r) => r.json['action'] == 'egress_access_plan',
        );
        final payload = jsonDecode(plan.json['payload'] as String) as Map;
        expect(payload['endpoint'], host);
        expect(payload['externalPort'], port);
      }

      await expectDestination('203.0.113.20', 443);
      await tester.tap(find.byKey(const ValueKey('client-egress-inbound')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-choice-9')));
      await tester.pumpAndSettle();
      await expectDestination('203.0.113.30', 8443);

      await tester.tap(find.byKey(const ValueKey('client-egress-server')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-choice-vless://')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('client-egress-uri')), findsOneWidget);
      expect(find.byKey(const ValueKey('client-egress-inbound')), findsNothing);
      expect(remote.submissions, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      source.dispose();
      catalog.dispose();
      session.dispose();
      session.network.dispose();
    },
  );
}
