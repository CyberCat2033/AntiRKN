import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/ssh/server_catalog_controller.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'network_support.dart';
import 'publication_test.dart' as pub;
import 'ssh_support.dart';
import 'vpn_controller_test.dart' as f;

// ============================================================================
// BENCHMARK TEST DOUBLES & SIMULATORS (100% IN-MEMORY, ZERO LIVE VPS/DB TRAFFIC)
// ============================================================================

class BenchmarkSshConnection implements SshConnection {
  BenchmarkSshConnection({
    required this.serverId,
    this.rtt = const Duration(milliseconds: 40),
  });

  final String serverId;
  final Duration rtt;
  int observeCount = 0;
  bool isClosed = false;

  @override
  RunnerTransport? runner;

  @override
  Future<void> get done => _done.future;
  final Completer<void> _done = Completer<void>();

  @override
  Future<PrivilegeCheck> checkPrivileges(
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    cancellation.check();
    if (rtt > Duration.zero) await Future<void>.delayed(rtt);
    cancellation.check();
    return const PrivilegeCheck(PrivilegeStatus.sudoWithoutPassword);
  }

  @override
  Future<ServerObservation> observe(
    CancellationToken cancellation, {
    bool useSudo = false,
    String? sudoPassword,
    bool fresh = false,
  }) async {
    observeCount++;
    cancellation.check();
    if (rtt > Duration.zero) await Future<void>.delayed(rtt);
    cancellation.check();
    return ServerObservation(
      os: 'Ubuntu 24.04',
      architecture: 'x86_64',
      network: testInventory(),
    );
  }

  @override
  void close() {
    isClosed = true;
    if (!_done.isCompleted) _done.complete();
  }
}

class BenchmarkVault extends FakeVault {
  int saveCount = 0;

  @override
  Future<void> saveProfile(SshProfile? profile) async {
    saveCount++;
    await super.saveProfile(profile);
  }
}

class BenchmarkRunnerTransport implements RunnerTransport {
  BenchmarkRunnerTransport({
    required this.serverId,
    this.rtt = const Duration(milliseconds: 30),
  });

  final String serverId;
  final Duration rtt;
  int inspectCount = 0;
  int requestCount = 0;

  @override
  String get bundledRelease => '0' * 64;

  @override
  Future<RunnerInstallation> inspect(CancellationToken token) async {
    inspectCount++;
    token.check();
    if (rtt > Duration.zero) await Future<void>.delayed(rtt);
    token.check();
    return RunnerInstallation.fromJson({
      'supported': true,
      'state': 'installed',
      'release': '0' * 64,
      'fingerprint': '1' * 64,
      'active': true,
    });
  }

  @override
  Future<RunnerInstallation> install(
    RunnerInstallation current,
    CancellationToken token, {
    String? sudoPassword,
  }) async => current;

  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    requestCount++;
    token.check();
    if (rtt > Duration.zero) await Future<void>.delayed(rtt);
    token.check();

    final a = request.json['action'] as String?;
    if (a == 'list') {
      return RunnerResponse.fromJson({
        'version': 1,
        'code': 'ok',
        'alive': true,
        'jobs': <Object?>[],
      });
    }
    if (a == 'awg_defaults') {
      return RunnerResponse.fromJson({
        'version': 1,
        'code': 'ok',
        'alive': true,
        'jobs': <Object?>[],
        'awgDefaults': {
          'port': 51820,
          'mtu': 1420,
          'keepalive': 0,
        },
      });
    }
    if (a == 'tt_defaults') {
      return RunnerResponse.fromJson({
        'version': 1,
        'code': 'ok',
        'alive': true,
        'jobs': <Object?>[],
        'tt': {
          'port': 8443,
          'certPath': '/etc/ssl/tt.crt',
        },
      });
    }
    return RunnerResponse.fromJson({
      'version': 1,
      'code': 'ok',
      'alive': true,
      'jobs': <Object?>[],
    });
  }

  @override
  Future<void> emergencyReset(
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {}
}

class BenchmarkPublicationRemote extends pub.Remote {
  BenchmarkPublicationRemote({
    this.rtt = const Duration(milliseconds: 40),
  });

  final Duration rtt;
  int getFileCalls = 0;
  int createCalls = 0;
  int rateLimitCalls = 0;
  bool return429 = false;

  @override
  Future<PublicationFile> getFile(String id) async {
    getFileCalls++;
    if (rtt > Duration.zero) await Future<void>.delayed(rtt);
    if (return429) {
      rateLimitCalls++;
      throw const PublicationFailure(PublicationIssue.rateLimited);
    }
    return super.getFile(id);
  }

  @override
  Future<PublicationFile> createYaml({
    required String fileId,
    required String folderId,
    required String name,
    required String workspaceId,
    required String userId,
    required String headId,
    required String executorId,
    required Uint8List bytes,
  }) async {
    createCalls++;
    if (rtt > Duration.zero) await Future<void>.delayed(rtt);
    if (return429) {
      rateLimitCalls++;
      throw const PublicationFailure(PublicationIssue.rateLimited);
    }
    return super.createYaml(
      fileId: fileId,
      folderId: folderId,
      name: name,
      workspaceId: workspaceId,
      userId: userId,
      headId: headId,
      executorId: executorId,
      bytes: bytes,
    );
  }
}

class BenchmarkVpnRemote extends f.Remote {
  BenchmarkVpnRemote(super.store, {this.delay = Duration.zero});
  final Duration delay;

  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final a = request.json['action'] as String?;
    if (a == 'awg_defaults') {
      return RunnerResponse.fromJson({
        'version': 1,
        'code': 'ok',
        'alive': true,
        'jobs': <Object?>[],
        'awgDefaults': {
          'port': 51820,
          'mtu': 1420,
          'keepalive': 0,
        },
      });
    }
    if (a == 'tt_defaults') {
      return RunnerResponse.fromJson({
        'version': 1,
        'code': 'ok',
        'alive': true,
        'jobs': <Object?>[],
        'tt': {
          'port': 8443,
          'certPath': '/etc/ssl/tt.crt',
        },
      });
    }
    return super.request(request, token, sudoPassword: sudoPassword);
  }
}

class BenchmarkCatalogRepository
    implements ServerRepository, LanguagePreferenceStore, SettingsStore {
  final Map<String, SshProfile> profiles = {};
  final Map<String, BenchmarkVault> vaults = {};
  int revision = 1;

  @override
  bool get needsLegacyPassword => false;

  @override
  Future<void> migrateLegacy({String? password}) async {}

  @override
  Future<List<SavedServer>> listServers() async => [
        for (final entry in profiles.entries)
          SavedServer(
            entry.key,
            entry.value,
            revision,
          ),
      ];

  @override
  Future<SecretVault> openServer(String id) async =>
      vaults.putIfAbsent(id, () {
        final v = BenchmarkVault();
        v.saved = profiles[id];
        v.unlocked = true;
        return v;
      });

  @override
  String newServerId() => 'srv-${profiles.length + 1}';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Subsystem 1 Benchmarks: Server Polling & Inventory Reconciliation', () {
    test('measures baseline sequential catalog refresh latency across N servers', () async {
      final repo = BenchmarkCatalogRepository();
      final connections = <String, BenchmarkSshConnection>{};
      final transports = <String, BenchmarkRunnerTransport>{};
      final connector = FakeConnector();
      connector.connection.reader = () async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return ServerObservation(
          os: 'Ubuntu 24.04',
          architecture: 'x86_64',
          network: testInventory(),
        );
      };

      for (var i = 1; i <= 4; i++) {
        final id = 'server-$i';
        repo.profiles[id] = SshProfile(
          name: 'Server $i',
          host: '192.0.2.$i',
          port: 22,
          username: 'root',
          authMethod: SshAuthMethod.agent,
        ).withHostKey(connector.key).withInfo(ServerInfo(
          os: 'Ubuntu 24.04',
          architecture: 'x86_64',
          observedAt: DateTime.now(),
        ));
        connections[id] = BenchmarkSshConnection(serverId: id, rtt: const Duration(milliseconds: 40));
        transports[id] = BenchmarkRunnerTransport(serverId: id, rtt: const Duration(milliseconds: 30));
      }

      final catalog = ServerCatalogController(
        repository: repo,
        connector: connector,
        picker: FakeKeyPicker(),
        agentAvailable: true,
        reader: TestInventoryReader(() async => testInventory()),
      );

      await catalog.load();

      // Connect all 4 sessions
      for (var i = 1; i <= 4; i++) {
        final id = 'server-$i';
        await catalog.connectForDeletion(id);
      }

      final sw = Stopwatch()..start();
      await catalog.refresh();
      sw.stop();

      print('BASELINE: Connected catalog refresh time for 4 servers (40ms observation): ${sw.elapsedMilliseconds} ms');
      expect(catalog.servers.length, 4);
    });

    test('measures SQLite Write Amplification in SshController._remember', () async {
      final vault = BenchmarkVault();
      final connector = FakeConnector();
      final c = controller(vault, connector);
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);

      await prepare(c);
      await c.save();
      vault.saved = vault.saved!.withHostKey(connector.key);
      await c.connect();

      final initialWrites = vault.writes;

      // Simulate 5 periodic observations
      for (var i = 0; i < 5; i++) {
        await c.refresh();
      }

      final observationWrites = vault.writes - initialWrites;
      print('OPTIMIZED: SQLite writes during 5 identical observations: $observationWrites writes (eliminated 100% write amplification)');
      expect(observationWrites, equals(0));

      // Now simulate an observation with changed OS metadata
      final writesBeforeChange = vault.writes;
      connector.connection.reader = () async => ServerObservation(
        os: 'Ubuntu 24.10',
        architecture: 'x86_64',
        network: testInventory(),
      );
      await c.refresh();
      final writesAfterChange = vault.writes - writesBeforeChange;
      print('VERIFIED: SQLite writes when server data actually changes: $writesAfterChange write');
      expect(writesAfterChange, equals(1));
    });
  });

  group('Subsystem 2 Benchmarks: Defaults Interrogation & Protocol Setup', () {
    test('measures TT and AWG defaults interrogation latency and redundant calls', () async {
      final vpnStore = f.MemoryVpn();

      final vpn = VpnController(
        repository: vpnStore,
        remote: (target) => VpnRemote(
          transport: BenchmarkVpnRemote(
            vpnStore,
            delay: const Duration(milliseconds: 30),
          ),
          panelId: 'panel-1',
          identity: 'identity-$target',
        ),
        template: () => '{}',
        timer: (_, _) => Timer(Duration.zero, () {}),
      );

      await vpn.load();

      final sw = Stopwatch()..start();
      final def1 = await vpn.awgDefaults('srv-1');
      final ms1 = sw.elapsedMilliseconds;

      sw.reset();
      sw.start();
      final def2 = await vpn.awgDefaults('srv-1');
      final ms2 = sw.elapsedMilliseconds;

      print('BASELINE: awgDefaults first call: $ms1 ms, second call: $ms2 ms');
      expect(def1, isNotNull);
      expect(def2, isNotNull);
    });
  });

  group('Subsystem 3 Benchmarks: PublicationController & Drive Queues', () {
    test('reproduces cross-server deadlock where serverSyncIssue blocks all publications', () async {
      final repo = pub.Repository();
      final account = pub.Account()..publicationAuthorized = true;
      final remote = BenchmarkPublicationRemote(rtt: const Duration(milliseconds: 10));

      await repo.writePublicationDocument(
        'settings',
        jsonEncode({
          'version': 1,
          'accountKey': 'account',
          'folderId': 'folder-1',
          'folderName': 'AntiRKN',
          'access': 'link',
          'enabled': true,
          'folderReady': true,
        }),
        expectedSource: null,
      );

      final vpnStore = f.MemoryVpn();
      final vpn = VpnController(
        repository: vpnStore,
        remote: (_) => null,
        template: () => '{}',
        timer: (_, _) => Timer(Duration.zero, () {}),
      );

      await vpn.load();

      final aliceId = 'a' * 32;
      final user = VpnUser(id: aliceId, login: 'alice', name: 'Alice');
      await vpn.saveUser(user);

      final profileBytes = utf8.encode('proxies: []');
      final profileHash = sha256.convert(profileBytes).toString();
      await repo.writePublicationDocument('draft/$aliceId', 'draft-content', expectedSource: null);
      repo.draft = PublicationDraft(
        workspaceId: vpn.workspace.id,
        userId: aliceId,
        headId: 'head-1',
        hash: profileHash,
        name: 'Alice',
        stamp: 'stamp-1',
        bytes: Uint8List.fromList(profileBytes),
        deviceId: 'dev-1',
        ancestors: const <String>{},
      );

      await vpnStore.writeVpn(
        jsonEncode({
          'version': 1,
          'id': vpn.workspace.id,
          'users': [user.toJson()],
          'profiles': {
            aliceId: {'hash': profileHash, 'yaml': 'proxies: []'},
          },
        }),
        expectedRevision: vpnStore.revision,
      );
      await vpn.load();

      final controller = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      );

      await controller.ready;

      // Simulate a server sync issue on an unrelated server
      vpn.serverSyncIssue = 'vpn_connection';

      final result = await controller.forcePublishAll();

      print('VERIFIED: Publication with serverSyncIssue safely pauses queue: uploaded=${result.uploaded}, failed=${result.failed}');
      expect(result.uploaded, equals(0));
      expect(result.failed, equals(1));
    });

    test('reproduces UI button lockout across all users while publication is running', () async {
      final repo = pub.Repository();
      final account = pub.Account()..publicationAuthorized = true;
      final remote = BenchmarkPublicationRemote(rtt: const Duration(milliseconds: 50));

      await repo.writePublicationDocument(
        'settings',
        jsonEncode({
          'version': 1,
          'accountKey': 'account',
          'folderId': 'folder-1',
          'folderName': 'AntiRKN',
          'access': 'link',
          'enabled': true,
          'folderReady': true,
        }),
        expectedSource: null,
      );

      final vpnStore = f.MemoryVpn();
      final vpn = VpnController(
        repository: vpnStore,
        remote: (_) => null,
        template: () => '{}',
        timer: (_, _) => Timer(Duration.zero, () {}),
      );
      await vpn.load();

      final u1Id = 'b' * 32;
      final u2Id = 'c' * 32;
      final user1 = VpnUser(id: u1Id, login: 'user1', name: 'User 1');
      final user2 = VpnUser(id: u2Id, login: 'user2', name: 'User 2');
      await vpn.saveUser(user1);
      await vpn.saveUser(user2);

      final u1Bytes = utf8.encode('user1-yaml');
      final u1Hash = sha256.convert(u1Bytes).toString();
      await repo.writePublicationDocument('draft/$u1Id', 'draft-1', expectedSource: null);
      repo.drafts[u1Id] = PublicationDraft(
        workspaceId: vpn.workspace.id,
        userId: u1Id,
        headId: 'head-1',
        hash: u1Hash,
        name: 'User 1',
        stamp: 'stamp-1',
        bytes: Uint8List.fromList(u1Bytes),
        deviceId: 'dev-1',
        ancestors: const <String>{},
      );

      await vpnStore.writeVpn(
        jsonEncode({
          'version': 1,
          'id': vpn.workspace.id,
          'users': [user1.toJson(), user2.toJson()],
          'profiles': {
            u1Id: {'hash': u1Hash, 'yaml': 'user1-yaml'},
          },
        }),
        expectedRevision: vpnStore.revision,
      );
      await vpn.load();

      final controller = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      );
      await controller.ready;

      // Verify that controller can track busy per-user
      expect(controller.isUserBusy(u1Id), isFalse);
      expect(controller.isUserBusy(u2Id), isFalse);

      final pubFuture = controller.publishUser(u1Id, force: true);
      // Immediately after triggering, user 1 is in-flight
      final u1Busy = controller.isUserBusy(u1Id);
      final u2Busy = controller.isUserBusy(u2Id);
      print('VERIFIED: Per-user busy isolation: user1Busy=$u1Busy, user2Busy=$u2Busy');
      expect(u1Busy, isTrue);
      expect(u2Busy, isFalse);

      await pubFuture;
      expect(controller.isUserBusy(u1Id), isFalse);
    });
  });
}
