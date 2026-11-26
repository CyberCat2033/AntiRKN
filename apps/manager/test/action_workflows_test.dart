import 'dart:async';
import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:antirkn_manager/ssh/server_catalog.dart';
import 'package:antirkn_manager/ssh/server_catalog_controller.dart';
import 'package:antirkn_manager/ssh/protocol_removal.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/vpn/profile_share_sheet.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'ssh_support.dart' as ssh;
import 'runner_support.dart';
import 'server_software_test.dart' show ObservedRemote;
import 'network_support.dart';
import 'publication_test.dart' as publication;
import 'vpn_controller_test.dart' as vpn;
import 'vpn_widgets_test.dart' show Export;

class Repository extends MemoryRunnerJournal implements ServerRepository {
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
  String newServerId() => 'fixture';
  @override
  Future<void> deleteServers(
    List<SavedServer> expected, {
    bool detachJumpReferences = false,
  }) async => vault.saveProfile(null);
}

Widget app(Widget child) => MaterialApp(
  theme: AppTheme.create(Brightness.dark),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Scaffold(body: child),
);

void main() {
  testWidgets(
    'inbound badge submits only enable and panel login belongs to VLESS',
    (tester) async {
      final store = MemoryRunnerJournal();
      final remote = ObservedRemote(store);
      final runner = RunnerController(
        serverId: 'fixture',
        store: store,
        transport: () => remote,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
      );
      final controller = vpn.controller(vpn.MemoryVpn(), {});
      final network = NetworkController(
        reader: TestInventoryReader(() async => testInventory()),
      );
      await runner.refresh(prepare: true);
      runner.panelDiscovery = {
        'panels': [
          {
            'source': 'systemd',
            'port': 43127,
            'inbounds': [
              {
                'id': 42,
                'name': 'Manual inbound',
                'enabled': true,
                'protocol': 'vless',
                'port': 443,
                'transport': 'xhttp',
                'security': 'reality',
              },
            ],
          },
        ],
        'failed': false,
      };
      await tester.pumpWidget(
        app(
          SingleChildScrollView(
            child: InboundsPanel(
              controller: controller,
              runner: runner,
              serverId: 'fixture',
              serverName: (s) => s,
              network: network,
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('vless-panel-login')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('vless-panel-login')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('panel-login-username')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('panel-login-username')),
        'fixture',
      );
      await tester.enterText(
        find.byKey(const ValueKey('panel-login-password')),
        'fixture-only',
      );
      remote.loginAccepted = true;
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('vless-panel-login')), findsNothing);
      expect(find.text('Details'), findsNothing);
      // The state is a labelled switch, not a button showing it (UI-59).
      await tester.tap(find.byType(Switch).last);
      await tester.pump(const Duration(milliseconds: 400));
      final request = remote.requests.lastWhere(
        (r) => r.json['kind'] == 'inbound_update',
      );
      final payload = jsonDecode(request.json['payload'] as String) as Map;
      expect(payload['patch'], {'enable': false});
      expect(payload['observedHash'], 'c' * 64);
      expect(payload['inboundId'], 42);
      expect(remote.submissions, 1);
      expect(remote.submitWithoutPersistence, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      runner.dispose();
      controller.dispose();
      network.dispose();
    },
  );
  testWidgets(
    'protocol confirmation reconnects and submits once; SSH Cancel returns',
    (tester) async {
      final repo = Repository(), remoteStore = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(remoteStore)..installed = true;
      final connector = ssh.FakeConnector()..connection.runner = remote;
      final session = ssh.controller(repo.vault, connector, repository: repo);
      await ssh.prepare(session);
      await session.save();
      repo.vault.saved = repo.vault.saved!.withHostKey(connector.key);
      await tester.pumpWidget(
        app(
          ServerDetailView(
            session: session,
            motion: MotionPreference.system,
            sections: const [
              ServerProtocolSection(
                name: 'AmneziaWG',
                count: 0,
                mark: 'W',
                child: Text('interfaces'),
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.text('AmneziaWG'));
      await tester.pumpAndSettle();
      expect(find.byType(AppFormDialog), findsOneWidget);
      expect(connector.calls, 0);
      expect(remote.submissions, 0);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(connector.calls, 0);
      await tester.tap(find.text('AmneziaWG'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Install'));
      await tester.pump();
      await tester.runAsync(() async {
        await session.runner.waitUntilIdle();
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(connector.calls, 1);
      expect(remote.submissions, 1);
      expect(remote.job?.kind, 'component_install');
      expect(find.text('Apply plan'), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      remote.job = runnerJob(
        remote.job!.id,
        kind: 'component_install',
        count: 6,
        interval: 1,
        progress: 6,
        status: 'succeeded',
      );
      await session.runner.refresh();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('SSH access'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('ssh-edit-cancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ssh-edit-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ssh-password')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      session.network.dispose();
    },
  );
  testWidgets(
    'privilege prompt allows back navigation to server overview and displays sudo password',
    (tester) async {
      final repo = Repository(), connector = ssh.FakeConnector();
      final session = ssh.controller(repo.vault, connector, repository: repo);
      await ssh.prepare(session);
      await session.save();
      repo.vault.saved = repo.vault.saved!.withHostKey(connector.key);
      await session.connect();
      session.needsPrivilegeInput = true;
      expect(session.showPrivilegePrompt, isTrue);

      var backPushed = false;
      await tester.pumpWidget(
        app(
          ServerDetailView(
            session: session,
            motion: MotionPreference.off,
            onBack: () => backPushed = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SSH access'), findsOneWidget);
      expect(backPushed, isFalse);

      await tester.tap(find.text('SSH access'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sudo-password')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('server-list-back')));
      await tester.pumpAndSettle();
      expect(backPushed, isFalse);
      expect(find.byKey(const ValueKey('sudo-password')), findsNothing);
      expect(find.text('SSH access'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      session.network.dispose();
    },
  );
  testWidgets('removal warns before connecting; cancelling has no effects', (
    tester,
  ) async {
    final repo = Repository(), connector = ssh.FakeConnector();
    final session = ssh.controller(repo.vault, connector, repository: repo),
        controller = vpn.controller(vpn.MemoryVpn(), {});
    await ssh.prepare(session);
    await session.save();
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => ServerDetailView(
            session: session,
            motion: MotionPreference.system,
            sections: [
              ServerProtocolSection(
                name: 'AmneziaWG',
                count: 0,
                mark: 'W',
                detected: true,
                onRemove: () => removeServerProtocol(
                  context,
                  session,
                  controller,
                  'amneziawg',
                  'AmneziaWG',
                ),
                child: const Text('interfaces'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.longPress(find.text('AmneziaWG'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AppFormDialog), findsOneWidget);
    expect(connector.calls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(connector.calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    session.network.dispose();
    controller.dispose();
  });
  test(
    'stale offline job allows reconnect; duplicate install submits once',
    () async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store);
      final gate = Completer<bool>();
      var connected = false, calls = 0;
      final c = RunnerController(
        serverId: 'fixture',
        store: store,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
        transport: () => connected ? remote : null,
        connectForAction: () async {
          calls++;
          connected = await gate.future;
          return connected;
        },
      );
      addTearDown(c.dispose);
      c.jobs = [runnerJob('a' * 32, status: 'running')];
      final first = c.installOrUpdate('trusttunnel');
      await c.installOrUpdate('trusttunnel');
      gate.complete(true);
      await first;
      expect(calls, 1);
      expect(remote.submissions, 1);
      expect(remote.submitWithoutPersistence, isFalse);
    },
  );
  testWidgets('container transform and system Back retain the catalogue', (
    tester,
  ) async {
    final repo = Repository(), connector = ssh.FakeConnector();
    final session = ssh.controller(repo.vault, connector, repository: repo);
    await ssh.prepare(session);
    session.serverName.text = 'Fixture server';
    await session.save();
    session.dispose();
    session.network.dispose();
    final c = ServerCatalogController(
      repository: repo,
      connector: connector,
      picker: ssh.FakeKeyPicker(),
      reader: TestInventoryReader(() async => testInventory()),
    );
    await c.load();
    await tester.pumpWidget(
      app(ServerCatalog(controller: c, motion: MotionPreference.system)),
    );
    await tester.tap(find.byKey(ValueKey('server-${repo.vault.saved!.id}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AppOpenContainer), findsWidgets);
    await tester.pumpAndSettle();
    expect(find.text('SSH access'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(c.selectedId, isNull);
    expect(find.text('Fixture server'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('server-${repo.vault.saved!.id}')));
    await tester.pumpAndSettle();
    await c.showList();
    await tester.pumpAndSettle();
    expect(find.text('Fixture server'), findsOneWidget);
    expect(find.text('SSH access'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
  testWidgets(
    'verified Drive QR survives missing local compilation and copies direct URL',
    (tester) async {
      final account = publication.Account(),
          repo = publication.Repository(),
          remote = publication.Remote(),
          c = vpn.controller(vpn.MemoryVpn(), {});
      final pub = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: c,
        canPublish: () => false,
      );
      await pub.ready;
      await tester.runAsync(() async {
        await c.load();
        await c.saveUser(VpnUser(id: vpn.alice, login: 'alice', name: 'Alice'));
      });
      await pub.configure(PublicationAccess.link);
      await pub.completeSetup();
      const direct = 'https://drive.google.com/uc?export=download&id=fixture';
      repo.docs['result/${vpn.alice}'] = jsonEncode({
        'fileId': 'fixture',
        'hash': 'f' * 64,
        'access': 'link',
        'url': direct,
      });
      await pub.reload();
      c.results.clear();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
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
          ProfileShareSheet(
            controller: c,
            user: c.workspace.users.single,
            exporter: Export(),
            publications: pub,
          ),
        ),
      );
      expect(find.byType(QrImageView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('profile-link-qr')));
      await tester.pumpAndSettle();
      expect(copied, direct);
      await tester.pumpWidget(const SizedBox.shrink());
      pub.dispose();
      c.dispose();
    },
  );
  testWidgets(
    'profile action identifies the resource and exposes regeneration at top right',
    (tester) async {
      final resource = vpn.inbound('one', '1' * 32);
      final store = vpn.MemoryVpn()
        ..raw = VpnWorkspace(
          id: 'f' * 32,
          users: [VpnUser(id: vpn.alice, login: 'alice', name: 'Alice')],
          inbounds: [resource],
        ).encode();
      final c = vpn.controller(store, {});
      await tester.runAsync(c.load);
      await tester.pumpWidget(
        app(
          ProfileShareSheet(
            controller: c,
            user: c.workspace.users.single,
            exporter: Export(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profile-regenerate')), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('profile-regenerate')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('profile-regenerate'))).dx,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('profile-close'))).dx,
        ),
      );
      expect(find.text('VLESS · Server one · VLESS'), findsOneWidget);
      expect(
        find.text('The server has not confirmed this resource yet.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'profile sheet shows only blocking issues, not base-config warnings',
    (tester) async {
      final c = vpn.controller(vpn.MemoryVpn(), {});
      await tester.runAsync(() async {
        await c.load();
        await c.saveUser(VpnUser(id: vpn.alice, login: 'alice', name: 'Alice'));
      });
      Future<void> show(List<ProfileDiagnostic> diagnostics) async {
        c.results[vpn.alice] = ProfileResult(
          groups: const <GroupPreview>[],
          diagnostics: diagnostics,
        );
        await tester.pumpWidget(
          app(
            ProfileShareSheet(
              key: UniqueKey(),
              controller: c,
              user: c.workspace.users.single,
              exporter: Export(),
            ),
          ),
        );
        await tester.pump();
      }

      await show(const [
        ProfileDiagnostic(
          'unsupported_rule_preview',
          DiagnosticSeverity.warning,
        ),
      ]);
      expect(
        find.text('This rule type still requires core validation.'),
        findsNothing,
      );
      expect(find.text('Check config'), findsNothing);
      await show(const [
        ProfileDiagnostic('invalid_yaml', DiagnosticSeverity.error),
      ]);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'ProfileShareSheet displays force overwrite button on external conflict',
    (tester) async {
      final account = publication.Account(),
          repo = publication.Repository(),
          remote = publication.Remote(),
          c = vpn.controller(vpn.MemoryVpn(), {});
      final pub = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: c,
        canPublish: () => false,
      );
      await pub.ready;
      await tester.runAsync(() async {
        await c.load();
        await c.saveUser(VpnUser(id: vpn.alice, login: 'alice', name: 'Alice'));
      });
      await pub.configure(PublicationAccess.link);
      await pub.completeSetup();
      repo.docs['result/${vpn.alice}'] = jsonEncode({
        'fileId': 'fixture',
        'hash': 'f' * 64,
        'access': 'link',
        'url': 'https://drive.google.com/uc?export=download&id=fixture',
      });
      await pub.reload();
      pub.queues[vpn.alice] = {
        'status': 'error',
        'issue': 'conflict',
        'userId': vpn.alice,
      };
      pub.notifyListeners();

      await tester.pumpWidget(
        app(
          ProfileShareSheet(
            controller: c,
            user: c.workspace.users.single,
            exporter: Export(),
            publications: pub,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final forceBtn = find.byKey(
        ValueKey('publication-force-overwrite-${vpn.alice}'),
      );
      expect(forceBtn, findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      pub.dispose();
      c.dispose();
    },
  );
}
