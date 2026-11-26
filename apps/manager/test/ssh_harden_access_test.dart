import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:antirkn_manager/ssh/ssh_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'network_support.dart';
import 'ssh_support.dart';

const pin = TrustedHostKey('ssh-ed25519', 'SHA256:fixture');
SshProfile profile(
  String id, {
  String? jump,
  SshAuthMethod auth = SshAuthMethod.password,
}) => SshProfile(
  id: id,
  host: '$id.example',
  port: 22,
  username: 'root',
  authMethod: auth,
  hostKey: pin,
  jumpServerId: jump,
  secrets: const {
    ServerSecret.sshPassword: 'old-fixture',
    ServerSecret.privateKey: 'key-fixture',
    ServerSecret.keyPassphrase: 'passphrase-fixture',
  },
);

class HopRepository implements ServerRepository {
  final hop = FakeVault()..saved = profile('hop');
  @override
  Future<List<SavedServer>> listServers() async => [
    SavedServer('hop', hop.saved!, 1),
  ];
  @override
  Future<SecretVault> openServer(String id) async => hop;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'both recovery profiles preserve keys and restore original credentials',
    () {
      for (final auth in [SshAuthMethod.password, SshAuthMethod.privateKey]) {
        final old = profile('target', jump: 'hop', auth: auth);
        final pending = old.withHardenRecovery(
          jobId: 'a' * 32,
          user: 'newuser',
          port: 2222,
          password: 'new-fixture',
        );
        final next = pending.recoveredAccess(hardened: true);
        expect(next.jumpServerId, 'hop');
        expect(next.hostKey, pin);
        expect(next.secrets[ServerSecret.privateKey], 'key-fixture');
        expect(next.secrets[ServerSecret.keyPassphrase], 'passphrase-fixture');
        expect(
          next.secrets[ServerSecret.sshPassword],
          auth == SshAuthMethod.password ? 'new-fixture' : 'old-fixture',
        );
        expect(
          next.recoveredAccess(hardened: false, clear: true).secrets,
          old.secrets,
        );
        expect(
          next
              .recoveredAccess(hardened: false, clear: true)
              .hasSameConnectionSettings(old),
          isTrue,
        );
        expect(
          () => pending
              .withHostKey(
                const TrustedHostKey('ssh-ed25519', 'SHA256:changed'),
              )
              .hardenRecovery,
          throwsFormatException,
        );
      }
    },
  );
  test(
    'verification uses saved jump route and rejects changed target or jump keys',
    () async {
      final repository = HopRepository(), connector = FakeConnector();
      final c = controller(FakeVault(), connector, repository: repository);
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      final target = profile('target', jump: 'hop').withHardenedAccess(
        user: 'newuser',
        port: 2222,
        sudoPassword: 'new-fixture',
      );
      final connection = await c.openHardenConnection(
        target,
        CancellationToken(),
      );
      expect(connector.lastJumps.map((p) => p.id), ['hop']);
      expect(repository.hop.isUnlocked, isFalse);
      connection.close();
      connector.jumpKeys['hop'] = const TrustedHostKey(
        'ssh-ed25519',
        'SHA256:changed',
      );
      await expectLater(
        c.openHardenConnection(target, CancellationToken()),
        throwsA(isA<SshFailure>()),
      );
      expect(connector.authentications, 1);
      expect(repository.hop.isUnlocked, isFalse);
      connector.jumpKeys.clear();
      connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:changed');
      await expectLater(
        c.openHardenConnection(target, CancellationToken()),
        throwsA(isA<SshFailure>()),
      );
      expect(connector.authentications, 1);
    },
  );
  test('hardened reconnect forgets the root observation', () async {
    final vault = FakeVault(), connector = FakeConnector();
    var uid = '0';
    Future<ServerObservation> reader() async => ServerObservation(
      os: 'Ubuntu 24.04',
      architecture: 'x86_64',
      network: testInventory(),
      software: ServerSoftwareInventory(
        observedAt: DateTime.utc(2026, 11, 26),
        facts: {ServerFact.uid: InventoryValue.ok(uid)},
        components: const [],
        sockets: const [],
      ),
    );
    Future<PrivilegeCheck> checker(String? password, Object _) async =>
        uid == '0'
        ? const PrivilegeCheck(PrivilegeStatus.root)
        : password == 'new-fixture'
        ? const PrivilegeCheck(PrivilegeStatus.sudoWithPassword)
        : const PrivilegeCheck(PrivilegeStatus.passwordRequired);
    // A closed connection cannot be reused: each connect gets its own.
    FakeConnection fresh() => connector.connection = FakeConnection()
      ..reader = reader
      ..privilegeChecker = checker;
    fresh();
    final c = controller(vault, connector);
    addTearDown(c.dispose);
    addTearDown(c.network.dispose);
    await prepare(c);
    await c.save();
    vault.saved = vault.saved!.withHostKey(pin);
    await c.connect();
    expect(c.isRoot, isTrue);
    await c.persistHardenProfile(
      vault.saved!.withHardenedAccess(
        user: 'mustang',
        port: 2222,
        sudoPassword: 'new-fixture',
      ),
    );
    c.disconnect();
    uid = '1000';
    fresh();
    await c.connect();
    expect(c.stage, SshStage.connected);
    expect(c.privileges?.status, PrivilegeStatus.sudoWithPassword);
    expect(c.showPrivilegePrompt, isFalse);
  });
  testWidgets(
    'root login exposes working hardening entry and root policy choice',
    (tester) async {
      final vault = FakeVault(), connector = FakeConnector();
      connector.connection.privilegeChecker = (_, _) async =>
          const PrivilegeCheck(PrivilegeStatus.root);
      final c = controller(vault, connector);
      await prepare(c);
      await c.save();
      vault.saved = vault.saved!.withHostKey(pin);
      await c.connect();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: SshPanel(controller: c)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.widgetWithIcon(FilledButton, Icons.shield_outlined);
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      c.network.dispose();
    },
  );
}
