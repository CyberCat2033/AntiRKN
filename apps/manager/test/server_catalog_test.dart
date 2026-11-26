import 'dart:async';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/catalog_selection.dart';
import 'package:antirkn_manager/ssh/server_catalog.dart';
import 'package:antirkn_manager/ssh/server_catalog_controller.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ssh_support.dart';
import 'network_support.dart';

const _userId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _template =
    '{"proxies":[],"proxy-groups":[{"name":"ALL","type":"select","include-all-proxies":true}],"rules":["MATCH,ALL"]}';

VlessInbound _inbound(String server, String id) => VlessInbound(
  serverId: server,
  spec: {
    ...VlessInbound.defaults(),
    'id': id,
    'endpoint': '203.0.113.1',
    'sni': 'example.com',
    'target': 'example.com:443',
  },
);

class _MemoryVpn implements VpnRepository {
  String? source;
  int revision = 0;

  @override
  Future<VpnStoredDocument> readVpn() async =>
      VpnStoredDocument(source, revision);

  @override
  Future<int> writeVpn(String source, {required int expectedRevision}) async {
    if (expectedRevision != revision) {
      throw const VaultFailure(VaultIssue.busy);
    }
    this.source = source;
    return ++revision;
  }
}

VpnController _vpnController(VpnRepository repository) => VpnController(
  repository: repository,
  remote: (_) => null,
  template: () => _template,
  timer: (_, _) => Timer(Duration.zero, () {}),
);

class _Repository
    implements ServerRepository, LanguagePreferenceStore, SettingsStore {
  final servers = <String, SshProfile>{};
  final settings = <String, String>{};
  int sequence = 0;
  int revision = 1;
  final deletedRevisions = <int>[];
  @override
  Future<void> deleteServers(
    List<SavedServer> expected, {
    bool detachJumpReferences = false,
  }) async {
    if (detachJumpReferences) {
      final ids = expected.map((server) => server.id).toSet();
      for (final entry in servers.entries.toList()) {
        if (!ids.contains(entry.key) &&
            ids.contains(entry.value.jumpServerId)) {
          servers[entry.key] = entry.value.withJumpServer(null);
        }
      }
    }
    for (final server in expected) {
      deletedRevisions.add(server.revision);
      servers.remove(server.id);
    }
  }

  @override
  bool get needsLegacyPassword => false;
  @override
  Future<void> migrateLegacy({String? password}) async {}
  @override
  Future<List<SavedServer>> listServers() async => [
    for (final entry in servers.entries)
      SavedServer(entry.key, entry.value, revision),
  ];
  @override
  String newServerId() => 'server-${++sequence}';
  @override
  Future<SecretVault> openServer(String id) async => _Handle(this, id);
  @override
  Future<AppLanguage> readLanguage() async => AppLanguage.en;
  @override
  Future<void> writeLanguage(AppLanguage language) async {}
  @override
  Future<String?> readSetting(String key) async => settings[key];
  @override
  Future<void> writeSetting(String key, String value) async {
    settings[key] = value;
  }
}

class _Handle extends FakeVault {
  _Handle(this.repository, this.id) {
    saved = repository.servers[id];
  }
  final _Repository repository;
  final String id;
  @override
  Future<void> saveProfile(SshProfile? profile) async {
    await super.saveProfile(profile);
    if (profile == null) {
      repository.servers.remove(id);
    } else {
      repository.servers[id] = profile;
    }
  }
}

class _VpnRepository extends _Repository implements VpnRepository {
  _VpnRepository(this.vpnSource);
  String? vpnSource;
  int vpnRevision = 1;

  @override
  Future<VpnStoredDocument> readVpn() async =>
      VpnStoredDocument(vpnSource, vpnRevision);

  @override
  Future<int> writeVpn(String source, {required int expectedRevision}) async {
    if (expectedRevision != vpnRevision) {
      throw const VaultFailure(VaultIssue.busy);
    }
    vpnSource = source;
    return ++vpnRevision;
  }
}

void main() {
  SshProfile profile(String id, {String? jump, TrustedHostKey? key}) =>
      SshProfile(
        id: id,
        name: 'VPS $id',
        host: '$id.example',
        port: 22,
        username: 'test',
        authMethod: SshAuthMethod.password,
        jumpServerId: jump,
        hostKey: key,
        secrets: const {ServerSecret.sshPassword: 'test-only'},
      );

  test(
    'a restored server without a pinned key is never trusted in the background',
    () async {
      // E.g. after a cloud pull: saved, but never connected on this device.
      final repo = _Repository()..servers['a'] = profile('a');
      final connector = FakeConnector();
      final c = ServerCatalogController(
        repository: repo,
        connector: connector,
        picker: FakeKeyPicker(),
        reader: TestInventoryReader(() async => testInventory()),
      );
      addTearDown(c.dispose);
      await c.load();
      // The background cache refresh path: non-interactive attempt, then the
      // runner's own connect-for-action fallback.
      expect(await c.connectForAction('a'), isFalse);
      expect(repo.servers['a']!.hostKey, isNull);
      expect(connector.authentications, 0);
    },
  );

  test('local forget refreshes revisions and never opens SSH', () async {
    final repo = _Repository()..servers['a'] = profile('a');
    final connector = FakeConnector();
    final c = ServerCatalogController(
      repository: repo,
      connector: connector,
      picker: FakeKeyPicker(),
      reader: TestInventoryReader(() async => testInventory()),
    );
    addTearDown(c.dispose);
    await c.load();
    repo.revision = 2;
    var abandoned = false;

    await c.forgetServersLocally({
      'a',
    }, abandonVpnState: () async => abandoned = true);

    expect(c.error, isNull);
    expect(abandoned, isTrue);
    expect(repo.deletedRevisions, [2]);
    expect(repo.servers, isEmpty);
    expect(connector.calls, 0);
  });

  test(
    'local forget detaches a lost SSH jump and preserves other servers',
    () async {
      final repo = _Repository()
        ..servers.addAll({'a': profile('a'), 'b': profile('b', jump: 'a')});
      final c = ServerCatalogController(
        repository: repo,
        connector: FakeConnector(),
        picker: FakeKeyPicker(),
        reader: TestInventoryReader(() async => testInventory()),
      );
      addTearDown(c.dispose);
      await c.load();
      var abandoned = false;

      await c.forgetServersLocally({
        'a',
      }, abandonVpnState: () async => abandoned = true);

      expect(c.error, isNull);
      expect(abandoned, isTrue);
      expect(repo.servers.keys, ['b']);
      expect(repo.servers['b']!.jumpServerId, isNull);
      expect(repo.servers['b']!.secrets, profile('b').secrets);
    },
  );

  testWidgets('offline deletion explains and detaches a jump', (tester) async {
    final repository = _Repository()
      ..servers.addAll({'a': profile('a'), 'b': profile('b', jump: 'a')});
    final connector = FakeConnector();
    final catalog = ServerCatalogController(
      repository: repository,
      connector: connector,
      picker: FakeKeyPicker(),
      reader: TestInventoryReader(() async => testInventory()),
    );
    final vpn = _vpnController(_MemoryVpn());
    final selection = CatalogSelection()
      ..start()
      ..toggle('a');
    addTearDown(() {
      selection.dispose();
      catalog.dispose();
      vpn.dispose();
    });
    await catalog.load();
    await tester.runAsync(() async {
      await vpn.load();
      await vpn.saveUser(VpnUser(id: _userId, login: 'alice', name: 'Alice'));
      await vpn.saveInbound(_inbound('a', '1' * 32));
    });
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('delete'),
            onPressed: () =>
                ServerCatalog.deleteSelected(context, catalog, selection, vpn),
            child: const Text('Delete'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('delete')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('ssh-delete-confirm')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey('ssh-forget-local-confirm')),
      findsOneWidget,
    );
    expect(find.text('Forget inaccessible server?'), findsOneWidget);
    expect(find.textContaining('SSH jump references'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ssh-forget-local-confirm')));
    await tester.pump();
    await tester.runAsync(() async {
      for (
        var attempt = 0;
        attempt < 100 && repository.servers.containsKey('a');
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump(const Duration(seconds: 1));
    expect(repository.servers.keys, ['b']);
    expect(repository.servers['b']!.jumpServerId, isNull);
    expect(vpn.workspace.inbounds.single.deleted, isTrue);
    expect(connector.calls, 0);
  });

  for (final (width, scale, locale) in [
    (390.0, 2.0, 'ru'),
    (700.0, 1.0, 'en'),
    (1000.0, 2.0, 'en'),
    (1400.0, 1.0, 'ru'),
  ]) {
    testWidgets('a server in service mode is marked in the catalog: '
        '$width x$scale $locale', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final repository = _Repository()
        ..servers.addAll({'a': profile('a'), 'b': profile('b')});
      final catalog = ServerCatalogController(
        repository: repository,
        connector: FakeConnector(),
        picker: FakeKeyPicker(),
        reader: TestInventoryReader(() async => testInventory()),
      );
      final vpn = _vpnController(_MemoryVpn());
      addTearDown(() {
        catalog.dispose();
        vpn.dispose();
      });
      await catalog.load();
      await tester.runAsync(() async {
        await vpn.load();
        await vpn.saveInbound(_inbound('a', '1' * 32));
        await vpn.enterServiceMode('a');
      });
      expect(vpn.serviceModeOf('a'), isNotNull);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          theme: AppTheme.create(Brightness.light),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: ServerCatalog(
              controller: catalog,
              vpn: vpn,
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final l = lookupAppLocalizations(Locale(locale));
      final badge = find.byKey(const ValueKey('server-service-mode-a'));
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text(l.serviceModeTitle)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('server-a')),
          matching: badge,
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('server-service-mode-b')), findsNothing);
    });
  }

  testWidgets('startup retires VPN resources whose SSH server is gone', (
    tester,
  ) async {
    final repository = _VpnRepository(
      VpnWorkspace(
        id: 'f' * 32,
        inbounds: [_inbound('gone', '1' * 32)],
      ).encode(),
    );
    final languages = LanguageController(repository);
    await languages.load();
    addTearDown(languages.dispose);

    await tester.pumpWidget(
      AntiRknApp(
        source: '',
        languages: languages,
        servers: repository,
        settings: repository,
        ssh: SshDependencies(
          openVault: () async => FakeVault(),
          connector: FakeConnector(),
          picker: FakeKeyPicker(),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100; attempt++) {
        final source = repository.vpnSource;
        if (source != null &&
            VpnWorkspace.decode(source).inbounds.single.deleted) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('Orphaned VPN resource was not retired');
    });

    final restored = VpnWorkspace.decode(repository.vpnSource!);
    expect(restored.inbounds.single.deleted, isTrue);
    expect(restored.inbounds.single.enabled, isFalse);
  });

  testWidgets('server row keeps its layout while opening and closing', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final repository = _Repository();
    repository.servers.addAll({
      for (final id in ['a', 'b', 'c']) id: profile(id),
    });
    final languages = LanguageController(repository);
    await languages.load();
    addTearDown(languages.dispose);
    await tester.pumpWidget(
      AntiRknApp(
        source: '',
        languages: languages,
        servers: repository,
        settings: repository,
        ssh: SshDependencies(
          openVault: () async => FakeVault(),
          connector: FakeConnector(),
          picker: FakeKeyPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('server-c'));
    final subtitle = find.descendant(of: row, matching: find.byType(Column));
    final size = tester.getSize(subtitle);
    await tester.tap(row);
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getSize(subtitle), size, reason: 'opening frame $i');
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('server-list-back')));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getSize(subtitle), size, reason: 'closing frame $i');
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('server-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('server-b')), findsOneWidget);
    expect(tester.getSize(subtitle), size);
  });

  test('jump and target trust are saved separately on first use', () async {
    final repo = _Repository();
    repo.servers.addAll({'a': profile('a'), 'b': profile('b', jump: 'a')});
    final connector = FakeConnector();
    const jumpKey = TrustedHostKey('ssh-ed25519', 'SHA256:jump');
    connector.jumpKeys['a'] = jumpKey;
    final c = controller(
      FakeVault(),
      connector,
      repository: repo,
      serverId: 'b',
    );
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await c.initialise();
    expect(c.showJumpPicker, isTrue);
    expect(c.jumpOptions.map((s) => s.id), ['a']);
    expect(c.saved, isTrue);
    await c.connect();
    expect(c.challenge, isNull);
    expect(c.stage, SshStage.connected);
    expect(connector.lastJumps.single.id, 'a');
    expect(repo.servers['a']!.hostKey, same(jumpKey));
    expect(repo.servers['b']!.hostKey, same(connector.key));
    expect(repo.servers['b']!.jumpServerId, 'a');
    c.disconnect();
    c.editSettings();
    c.setJump(null);
    expect(c.saved, isFalse);
    c.cancelEditing();
    expect(c.jumpServerId, 'a');
  });
  test(
    'deleted or cyclic jump stops before connector; changed jump key identifies the intermediary',
    () async {
      final repo = _Repository();
      final connector = FakeConnector();
      final c = controller(
        FakeVault(),
        connector,
        repository: repo,
        serverId: 'b',
      );
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      repo.servers['b'] = profile('b', jump: 'a');
      await c.initialise();
      await c.connect();
      expect(c.error, SshIssue.invalidJumpRoute);
      expect(connector.calls, 0);
      repo.servers['a'] = profile('a', jump: 'b');
      await c.connect();
      expect(c.error, SshIssue.invalidJumpRoute);
      expect(connector.calls, 0);
      repo.servers['a'] = profile(
        'a',
        key: const TrustedHostKey('ssh-ed25519', 'SHA256:old'),
      );
      await c.connect();
      expect(c.error, SshIssue.jumpHostKeyChanged);
      expect(connector.authentications, 0);
      expect(repo.servers['a']!.hostKey!.fingerprint, 'SHA256:old');
      await c.replaceServer();
      expect(connector.calls, 1);
    },
  );

  for (final language in ['en', 'ru']) {
    testWidgets(
      'multiple servers CRUD, restart, reveal password, background and large text: $language',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final repository = _Repository();
        final languages = LanguageController(repository);
        await languages.load();
        await languages.select(AppLanguage.values.byName(language));
        addTearDown(languages.dispose);
        Future<void> launch() async {
          await tester.pumpWidget(
            AntiRknApp(
              source: '',
              languages: languages,
              servers: repository,
              settings: repository,
              ssh: SshDependencies(
                openVault: () async => FakeVault(),
                connector: FakeConnector(),
                picker: FakeKeyPicker(),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        Future<void> tap(String key) async {
          final target = find.byKey(ValueKey(key));
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.tap(target);
          await tester.pumpAndSettle();
        }

        Future<void> enter(String key, String text) async {
          final field = find.byKey(ValueKey(key));
          await tester.ensureVisible(field);
          await tester.pumpAndSettle();
          await tester.enterText(field, text);
          await tester.pumpAndSettle();
        }

        await launch();
        expect(find.text('Protected storage'), findsNothing);
        expect(find.byKey(const ValueKey('vault-open')), findsNothing);
        for (final letter in ['A', 'B']) {
          await tap('server-add');
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('ssh-host')))
                .controller!
                .text,
            isEmpty,
          );
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('ssh-password')))
                .controller!
                .text,
            isEmpty,
          );
          expect(find.byKey(const ValueKey('ssh-jump')), findsNothing);
          await enter('ssh-name', 'VPS $letter');
          await enter('ssh-host', '${letter.toLowerCase()}.example');
          await enter('ssh-password', 'fixture-password-$letter');
          await tap('ssh-save');
          expect(find.text('VPS $letter'), findsOneWidget);
          await tap('server-ssh-access');
          expect(
            find.byKey(const ValueKey('ssh-jump')),
            letter == 'B' ? findsOneWidget : findsNothing,
          );
          await tap('server-list-back');
          await tap('server-list-back');
        }
        expect(repository.servers, hasLength(2));
        expect(find.text('VPS A'), findsOneWidget);
        expect(find.text('VPS B'), findsOneWidget);
        final firstId = repository.servers.keys.first;
        final secondId = repository.servers.keys.last;
        expect(repository.servers[firstId]!.id, firstId);
        expect(repository.servers[secondId]!.hostKey, isNull);
        await tester.pumpWidget(const SizedBox());
        await launch();
        await tap('server-$firstId');
        expect(find.byKey(const ValueKey('ssh-connect')), findsOneWidget);
        await tap('server-ssh-access');
        expect(find.byKey(const ValueKey('ssh-connect')), findsOneWidget);
        expect(
          find.text(language == 'en' ? 'Connect' : 'Подключиться'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('ssh-jump')), findsOneWidget);
        await tap('ssh-jump');
        await tester.tap(find.text('VPS B').last);
        await tester.pumpAndSettle();
        await tap('ssh-save');
        expect(repository.servers[firstId]!.jumpServerId, secondId);
        await tap('ssh-jump');
        await tester.tap(
          find
              .text(
                language == 'en' ? 'Direct connection' : 'Прямое подключение',
              )
              .last,
        );
        await tester.pumpAndSettle();
        await tap('ssh-save');
        expect(repository.servers[firstId]!.jumpServerId, isNull);
        await tap('show-ssh-password');
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('ssh-password')),
        );
        expect(field.obscureText, isFalse);
        expect(field.controller!.text, 'fixture-password-A');
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pump(const Duration(minutes: 6));
        expect(field.controller!.text, 'fixture-password-A');
        await enter('ssh-name', 'Renamed A');
        expect(
          find.text(
            language == 'en' ? 'Save and connect' : 'Сохранить и подключиться',
          ),
          findsOneWidget,
        );
        await tap('ssh-save');
        await tap('ssh-connect');
        await tap('server-list-back');
        await tap('server-list-back');
        expect(find.text('Renamed A'), findsOneWidget);
        expect(repository.servers[firstId]!.host, 'a.example');
        expect(repository.servers[firstId]!.lastInfo!.os, 'Ubuntu 24.04');
        await tester.pumpWidget(const SizedBox());
        await launch();
        await tap('server-$firstId');
        expect(find.textContaining('Ubuntu 24.04'), findsOneWidget);
        await tap('server-list-back');
        await tap('server-edit');
        await tap('server-select-$secondId');
        final deleteText = language == 'en'
            ? 'Delete saved connection'
            : 'Удалить сохранённое подключение';
        // Locate the actual localized action by its stable key.
        await tap('server-delete-selected');
        final confirm = find.byKey(const ValueKey('ssh-delete-confirm'));
        expect(confirm, findsOneWidget, reason: deleteText);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('server-list-back')), findsNothing);
        expect(repository.servers.keys, [firstId]);
        expect(find.text('VPS B'), findsNothing);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final width in [390.0, 700.0, 1400.0]) {
          tester.view.physicalSize = Size(width, 1000);
          await tester.pumpAndSettle();
          expect(find.text('Renamed A'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
