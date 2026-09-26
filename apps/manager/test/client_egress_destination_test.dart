import 'package:antirkn_domain/antirkn_domain.dart';
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
  testWidgets('catalog uses each inbound address instead of the SSH address', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository();
    final remote = FakeRunnerTransport(repository)
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
          body: ClientEgressForm(controller: source, catalog: catalog),
        ),
      ),
    );
    tester
        .widget<DropdownButtonFormField<bool>>(
          find.byType(DropdownButtonFormField<bool>),
        )
        .onChanged!(true);
    await tester.pumpAndSettle();
    tester
        .widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .onChanged!('exit');
    await tester.pumpAndSettle();

    TextField field(String label) => tester.widget<TextField>(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      ),
    );
    expect(
      field('Address reachable from this server').controller!.text,
      '203.0.113.20',
    );
    expect(field('External VLESS port').controller!.text, '443');

    tester
        .widget<DropdownButtonFormField<int>>(
          find.byType(DropdownButtonFormField<int>),
        )
        .onChanged!(9);
    await tester.pumpAndSettle();
    expect(
      field('Address reachable from this server').controller!.text,
      '203.0.113.30',
    );
    expect(field('External VLESS port').controller!.text, '8443');
    expect(remote.submissions, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    source.dispose();
    catalog.dispose();
    session.dispose();
    session.network.dispose();
  });
}
