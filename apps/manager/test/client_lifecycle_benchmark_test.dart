import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' as f;
import 'awg_test.dart' as awg;
import 'tt_test.dart' as tt;

// ============================================================================
// ISOLATED IN-MEMORY TEST DOUBLES & BENCHMARK HARNESS
// NO live ~/.config/antirkn user databases or live VPS servers are accessed.
// ============================================================================

class BenchmarkStore extends f.MemoryVpn {
  int writeCount = 0;
  int readCount = 0;

  @override
  Future<VpnStoredDocument> readVpn() async {
    readCount++;
    return super.readVpn();
  }

  @override
  Future<int> writeVpn(String source, {required int expectedRevision}) async {
    writeCount++;
    return super.writeVpn(source, expectedRevision: expectedRevision);
  }
}

class RequestRecord {
  final String serverId;
  final String action;
  final DateTime startTime;
  final DateTime endTime;
  final int durationMs;

  RequestRecord({
    required this.serverId,
    required this.action,
    required this.startTime,
    required this.endTime,
    required this.durationMs,
  });

  @override
  String toString() =>
      '[$serverId] $action: ${durationMs}ms (${startTime.toIso8601String()} -> ${endTime.toIso8601String()})';
}

class BenchmarkRemote extends f.Remote {
  BenchmarkRemote(
    super.store, {
    required this.serverId,
    this.delay = Duration.zero,
  });

  final String serverId;
  final Duration delay;
  final List<RequestRecord> history = [];
  int currentInFlight = 0;
  int peakInFlight = 0;
  bool failOnRequest = false;

  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    currentInFlight++;
    if (currentInFlight > peakInFlight) {
      peakInFlight = currentInFlight;
    }
    final start = DateTime.now();
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (failOnRequest) {
      currentInFlight--;
      throw const SshFailure(SshIssue.disconnected);
    }

    try {
      final r = request.json;
      final a = r['action'] as String;
      actions.add(a);

      // Support AWG and TT protocols in addition to VLESS
      if (a == 'awg_plan') {
        return RunnerResponse.fromJson({
          'version': 1,
          'code': 'ok',
          'alive': true,
          'jobs': <Object?>[],
          'awgPlan': {'fingerprint': 'e' * 64},
        });
      }
      if (a == 'awg_state') {
        return RunnerResponse.fromJson({
          'version': 1,
          'code': 'ok',
          'alive': true,
          'jobs': <Object?>[],
          'awgState': customState ?? state,
        });
      }
      if (a == 'tt_plan') {
        return RunnerResponse.fromJson({
          'version': 1,
          'code': 'ok',
          'alive': true,
          'jobs': <Object?>[],
          'tt': {'fingerprint': 'e' * 64},
        });
      }
      if (a == 'tt_state') {
        return RunnerResponse.fromJson({
          'version': 1,
          'code': 'ok',
          'alive': true,
          'jobs': <Object?>[],
          'tt': {'resources': customState ?? state},
        });
      }

      if (a == 'submit') {
        final p = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
        final protocol = p['protocol'] as String?;
        if (protocol == 'awg') {
          final id = r['id'] as String;
          submissions[id] = p;
          state = [
            for (final s in p['resources'] as List)
              {
                'id': s['id'],
                'workspaceId': p['workspaceId'],
                'confirmed': true,
                'spec': s,
                'clients': [
                  for (final u in p['users'] as List)
                    {
                      'id': u['id'],
                      'enabled': u['enabled'],
                      'publicKey': 'b' * 43,
                      'presharedKey': 'c' * 43,
                      'clientIp': '10.0.0.2',
                    },
                ],
              },
          ];
          jobs[id] = {
            'id': id,
            'kind': 'awg_apply',
            'status': running ? 'running' : 'succeeded',
            'checkpoint': running ? 1 : r['count'],
            'count': r['count'],
            'interval': 1,
          };
          return RunnerResponse.fromJson({
            'version': 1,
            'code': 'ok',
            'alive': true,
            'jobs': [jobs[id]!],
          });
        }
        if (protocol == 'tt') {
          final id = r['id'] as String;
          submissions[id] = p;
          state = [
            for (final s in p['resources'] as List)
              {
                'id': s['id'],
                'workspaceId': p['workspaceId'],
                'confirmed': true,
                'spec': s,
                'clients': [
                  for (final u in p['users'] as List)
                    {
                      'id': u['id'],
                      'enabled': u['enabled'],
                      'login': u['login'],
                    },
                ],
              },
          ];
          jobs[id] = {
            'id': id,
            'kind': 'tt_apply',
            'status': running ? 'running' : 'succeeded',
            'checkpoint': running ? 1 : r['count'],
            'count': r['count'],
            'interval': 1,
          };
          return RunnerResponse.fromJson({
            'version': 1,
            'code': 'ok',
            'alive': true,
            'jobs': [jobs[id]!],
          });
        }
      }

      return await super.request(request, token, sudoPassword: sudoPassword);
    } finally {
      final end = DateTime.now();
      currentInFlight--;
      history.add(
        RequestRecord(
          serverId: serverId,
          action: request.json['action'] as String? ?? 'unknown',
          startTime: start,
          endTime: end,
          durationMs: end.difference(start).inMilliseconds,
        ),
      );
    }
  }
}

class InstrumentedVpnController extends VpnController {
  InstrumentedVpnController({
    required super.repository,
    required super.template,
    required super.remote,
    super.serverName,
    super.coreValidator,
    super.recovery,
    super.connectForAction,
    super.connectForDeletion,
    super.pickTemplate,
    super.serverIds,
    super.timer,
  });

  final List<String> ensureConnectedCalls = [];
  final List<DateTime> ensureConnectedTimestamps = [];

  @override
  Future<bool> ensureConnected(String target) {
    ensureConnectedCalls.add(target);
    ensureConnectedTimestamps.add(DateTime.now());
    return super.ensureConnected(target);
  }
}

InstrumentedVpnController createBenchmarkController(
  f.MemoryVpn store,
  Map<String, f.Remote> remotes, {
  String Function()? source,
  WorkspaceRecoveryStore? recovery,
  Future<bool?> Function(String serverId)? connectForDeletion,
  Future<bool> Function(String serverId)? connectForAction,
}) => InstrumentedVpnController(
  repository: store,
  recovery: recovery,
  connectForDeletion: connectForDeletion,
  connectForAction: connectForAction,
  template: source ?? () => f.template,
  serverName: (id) => 'Server $id',
  remote: (id) {
    final server = vpnServerId(id);
    final transport = remotes[id] ?? remotes[server];
    return transport == null
        ? null
        : VpnRemote(
            transport: transport,
            panelId: f.panel,
            identity: 'identity-$server',
          );
  },
  timer: (d, fn) => Timer(Duration.zero, () {}),
);

// ============================================================================
// MAIN BENCHMARK & REPRODUCTION SUITE
// ============================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Helper to extract a user from controller workspace
  VpnUser getUser(VpnController c, String id) =>
      c.workspace.users.singleWhere((u) => u.id == id);

  group(
    'Benchmark & Reproduction A: Cross-Server Deadlock on Offline Pending Revocation',
    () {
      test(
        'reproduce deadlock: offline server with pending revocation blocks prepare() on healthy independent servers',
        () async {
          final store = BenchmarkStore();
          final healthyRemote = BenchmarkRemote(store, serverId: 'healthy');
          final offlineRemote = BenchmarkRemote(store, serverId: 'offline');
          final remotes = <String, f.Remote>{
            'healthy': healthyRemote,
            'offline': offlineRemote,
          };

          final c = createBenchmarkController(store, remotes);
          addTearDown(c.dispose);

          await c.load();
          await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
          await c.saveUser(VpnUser(id: f.bob, login: 'bob', name: 'Bob'));
          await c.saveInbound(f.inbound('healthy', '1' * 32));
          await c.saveInbound(f.inbound('offline', '2' * 32));

          // Initial apply to both servers
          await c.prepareAndApply();
          expect(c.error, isNull);
          expect(healthyRemote.submissions, isNotEmpty);
          expect(offlineRemote.submissions, isNotEmpty);

          // Simulate server 'offline' going offline (disconnected)
          remotes.remove('offline');

          // Delete user Alice. Revocation succeeds on 'healthy' but remains pending on 'offline'
          await c.deleteUser(getUser(c, f.alice), awaitReconcile: true);

          // Verification of state
          final aliceUser = getUser(c, f.alice);
          expect(aliceUser.deleted, isTrue);
          expect(aliceUser.deletionComplete, isFalse);
          expect(c.hasPendingRevocation('offline'), isTrue);
          expect(c.hasPendingRevocation('healthy'), isFalse);
          expect(c.blockingRevocations.map((u) => u.id), contains(f.alice));

          // VERIFICATION OF DEADLOCK RESOLUTION:
          // Operator now attempts to perform prepare() ONLY on 'healthy',
          // which has ZERO pending revocations and is 100% online.
          // Previously line 1233 blocked this with vpn_busy.
          // With server-scoped revocation isolation, healthy server prepares cleanly!
          await c.prepare(serverIds: {'healthy'});

          expect(c.error, isNull);
          expect(c.plans, isNotEmpty);
          expect(c.plans.single.serverId, 'healthy');
          expect(c.plans.single.preview, isNotNull);

          // Applying healthy server succeeds!
          await c.apply();
          expect(c.error, isNull);

          // Saving a new user 'charlie' and preparing for 'healthy' server succeeds
          await c.saveUser(
            VpnUser(id: 'c' * 32, login: 'charlie', name: 'Charlie'),
          );
          await c.prepare(serverIds: {'healthy'});
          expect(c.error, isNull);
          expect(c.plans, isNotEmpty);

          // Preparing offline server produces plan with null preview (isolated)
          await c.prepare(serverIds: {'offline'});
          expect(c.error, isNull);
          expect(c.plans.single.preview, isNull);

          // Metrics report
          final healthyRevocationCount = c.hasPendingRevocation('healthy')
              ? 1
              : 0;
          final offlineRevocationCount = c.hasPendingRevocation('offline')
              ? 1
              : 0;
          debugPrint(
            '[Benchmark A - Deadlock Resolved] healthy_pending_revocations=$healthyRevocationCount '
            'offline_pending_revocations=$offlineRevocationCount '
            'blocking_revocations_count=${c.blockingRevocations.length} '
            'healthy_prepare_success=true',
          );
        },
      );
    },
  );

  group(
    'Benchmark & Reproduction B: Sequential Bottleneck in Deletion Reconciliation',
    () {
      test(
        'reproduce sequential bottleneck: _reconcileDeletions revokes independent servers one-by-one',
        () async {
          final store = BenchmarkStore();
          const serverDelay = Duration(milliseconds: 30);
          final remotes = <String, BenchmarkRemote>{
            'srv-alpha': BenchmarkRemote(
              store,
              serverId: 'srv-alpha',
              delay: serverDelay,
            ),
            'srv-beta': BenchmarkRemote(
              store,
              serverId: 'srv-beta',
              delay: serverDelay,
            ),
            'srv-gamma': BenchmarkRemote(
              store,
              serverId: 'srv-gamma',
              delay: serverDelay,
            ),
          };

          final c = createBenchmarkController(store, remotes);
          addTearDown(c.dispose);

          await c.load();
          await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
          await c.saveInbound(f.inbound('srv-alpha', '1' * 32));
          await c.saveInbound(f.inbound('srv-beta', '2' * 32));
          await c.saveInbound(f.inbound('srv-gamma', '3' * 32));
          await c.prepareAndApply();

          // Clear initial apply history
          for (final r in remotes.values) {
            r.history.clear();
          }
          final initialWrites = store.writeCount;

          // Trigger deletion with reconciliation
          final stopwatch = Stopwatch()..start();
          await c.deleteUser(getUser(c, f.alice), awaitReconcile: true);
          stopwatch.stop();
          final totalElapsedMs = stopwatch.elapsedMilliseconds;

          // Gather metrics per server
          final alphaHistory = remotes['srv-alpha']!.history;
          final betaHistory = remotes['srv-beta']!.history;
          final gammaHistory = remotes['srv-gamma']!.history;

          expect(alphaHistory, isNotEmpty);
          expect(betaHistory, isNotEmpty);
          expect(gammaHistory, isNotEmpty);

          final alphaStart = alphaHistory.first.startTime;
          final alphaEnd = alphaHistory.last.endTime;
          final betaStart = betaHistory.first.startTime;
          final betaEnd = betaHistory.last.endTime;
          final gammaStart = gammaHistory.first.startTime;
          final gammaEnd = gammaHistory.last.endTime;

          final alphaDurationMs = alphaEnd
              .difference(alphaStart)
              .inMilliseconds;
          final betaDurationMs = betaEnd.difference(betaStart).inMilliseconds;
          final gammaDurationMs = gammaEnd
              .difference(gammaStart)
              .inMilliseconds;

          // VERIFICATION OF PARALLEL CONCURRENT EXECUTION:
          // srv-beta starts BEFORE srv-alpha finishes (concurrent overlap!)
          // srv-gamma starts BEFORE srv-beta finishes (concurrent overlap!)
          expect(
            betaStart.isBefore(alphaEnd),
            isTrue,
            reason:
                'Parallel execution: Server Beta executes concurrently with Server Alpha',
          );

          final sequentialSumMs =
              alphaDurationMs + betaDurationMs + gammaDurationMs;
          final concurrentIdealMs = [
            alphaDurationMs,
            betaDurationMs,
            gammaDurationMs,
          ].reduce((a, b) => a > b ? a : b);
          final theoreticalSpeedup = sequentialSumMs / concurrentIdealMs;
          final deletionWrites = store.writeCount - initialWrites;

          debugPrint(
            '[Benchmark B - Parallel Reconciliation] '
            'servers=3 '
            'totalElapsedMs=$totalElapsedMs '
            'sequentialSumMs=$sequentialSumMs '
            'concurrentIdealMs=$concurrentIdealMs '
            'actualSpeedup=${(sequentialSumMs / totalElapsedMs).toStringAsFixed(2)}x '
            'theoreticalSpeedup=${theoreticalSpeedup.toStringAsFixed(2)}x '
            'writeCountDuringDeletion=$deletionWrites',
          );

          // Verification of atomic batching: 6 disk writes instead of 10
          expect(deletionWrites, lessThanOrEqualTo(6));
        },
      );
    },
  );

  group(
    'Benchmark & Reproduction C: Redundant ensureConnected Invocations During prepare()',
    () {
      test(
        'measure redundant ensureConnected calls on a single target server during prepare()',
        () async {
          final store = BenchmarkStore();
          final remote = BenchmarkRemote(store, serverId: 'srv-1');
          final remotes = {'srv-1': remote};

          final c = createBenchmarkController(store, remotes);
          addTearDown(c.dispose);

          await c.load();
          await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
          await c.saveInbound(f.inbound('srv-1', '1' * 32));

          c.ensureConnectedCalls.clear();
          await c.prepare();

          // VERIFICATION:
          // Physical server srv-1 is connected once without redundant re-connection calls
          final calls = c.ensureConnectedCalls;
          debugPrint(
            '[Benchmark C1 - Single Server] ensureConnected_calls=${calls.length}: $calls',
          );

          expect(calls.length, 1);
          expect(calls[0], 'srv-1');
        },
      );

      test(
        'measure severe ensureConnected call multiplication on multi-protocol server (VLESS + AWG + TT)',
        () async {
          final store = BenchmarkStore();
          final remote = BenchmarkRemote(store, serverId: 'srv-multi');
          final remotes = {'srv-multi': remote};

          final c = createBenchmarkController(store, remotes);
          addTearDown(c.dispose);

          await c.load();
          await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
          // 1 physical server with 3 protocols: VLESS, AWG, TrustTunnel
          await c.saveInbound(f.inbound('srv-multi', '1' * 32));
          await c.saveAwg(
            AwgInterface(
              serverId: 'srv-multi',
              spec: {...awg.spec(), 'id': 'd' * 32, 'name': 'AWG-Res'},
            ),
          );
          await c.saveTt(
            TrustTunnelEndpoint(
              serverId: 'srv-multi',
              spec: {...tt.spec(), 'id': 'e' * 32, 'name': 'TT-Res'},
            ),
          );

          c.ensureConnectedCalls.clear();
          await c.prepare();

          final calls = c.ensureConnectedCalls;
          final uniqueTargets = c.workspace.serverIds;
          debugPrint(
            '[Benchmark C2 - Multi-Protocol] '
            'targets=${uniqueTargets.length} '
            'physical_servers=1 '
            'ensureConnected_calls=${calls.length}: $calls',
          );

          // VERIFICATION:
          // Even across 3 targets (VLESS, AWG, TrustTunnel) on 1 physical host,
          // srv-multi is connected exactly once via memoized in-flight connection
          expect(uniqueTargets.length, 3);
          expect(calls.length, 1);
          expect(calls[0], 'srv-multi');
        },
      );

      test(
        'measure extreme ensureConnected redundancy when pending revocations exist',
        () async {
          final store = BenchmarkStore();
          final remote = BenchmarkRemote(store, serverId: 'srv-one');
          final remotes = <String, f.Remote>{'srv-one': remote};

          var c = createBenchmarkController(store, remotes);

          await c.load();
          await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
          await c.saveUser(VpnUser(id: f.bob, login: 'bob', name: 'Bob'));
          await c.saveInbound(f.inbound('srv-one', '1' * 32));
          await c.saveAwg(
            AwgInterface(
              serverId: 'srv-one',
              spec: {...awg.spec(), 'id': 'd' * 32, 'name': 'AWG-Res'},
            ),
          );
          await c.saveTt(
            TrustTunnelEndpoint(
              serverId: 'srv-one',
              spec: {...tt.spec(), 'id': 'e' * 32, 'name': 'TT-Res'},
            ),
          );

          await c.prepareAndApply();

          // 1. Take server offline
          remotes.clear();

          // 2. Delete user Alice while server is offline
          await c.deleteUser(getUser(c, f.alice), awaitReconcile: false);
          expect(c.pendingRevocations, isNotEmpty);

          // 3. Mark deletion as force-hidden (simulating forceDeleteClient when server is offline)
          final saved = jsonDecode(store.raw!) as Map<String, dynamic>;
          final deletedUser =
              (saved['users'] as List).singleWhere((u) => u['id'] == f.alice)
                  as Map<String, dynamic>;
          deletedUser['deletion'] = {
            ...deletedUser['deletion'] as Map,
            'hidden': true,
          };
          // Also update stored revisions consistently
          store.raw = jsonEncode(saved);

          c.dispose();
          c = createBenchmarkController(store, remotes);
          addTearDown(c.dispose);
          await c.load();

          expect(c.pendingRevocations, isNotEmpty);
          expect(c.blockingRevocations, isEmpty);

          // 4. Server comes back online
          remotes['srv-one'] = remote;

          // 5. prepare() is called:
          // Line 1233 passes (blockingRevocations is empty)
          // Line 1248 executes loop over selected targets (3 calls: srv-one, awg/srv-one, tt/srv-one)
          // Line 1252 executes _reconcileDeletions and settles revocation on the reconnected server
          // Line 1259 executes map over selected physical servers (1 call: srv-one)
          // Line 1263 executes map over selected targets (3 calls: srv-one, awg/srv-one, tt/srv-one)
          c.ensureConnectedCalls.clear();
          await c.prepare();

          final calls = c.ensureConnectedCalls;
          debugPrint(
            '[Benchmark C3 - Pending Revocations] '
            'pendingRevocations=${c.pendingRevocations.length} '
            'physical_servers=1 '
            'ensureConnected_calls=${calls.length}: $calls',
          );

          // VERIFICATION:
          // Redundancy eliminated: only 2 calls total (1 for deletion reconcile + 1 for prepare)
          // instead of 7 redundant calls!
          expect(calls.length, lessThanOrEqualTo(2));
          final redundancyRatio = (calls.length - 1) / 1;
          debugPrint(
            '[Benchmark C3 - Redundancy Eliminated] calls=${calls.length} redundancy=${redundancyRatio * 100}%',
          );
        },
      );
    },
  );

  group(
    'Benchmark & Reproduction D: UI Freeze and Synchronous prepareAndApply in UsersPage.edit',
    () {
      test(
        'timing breakdown microbenchmark: local saveUser() vs synchronous remote prepareAndApply()',
        () async {
          final store = BenchmarkStore();
          const requestLatency = Duration(milliseconds: 30);
          final remote = BenchmarkRemote(
            store,
            serverId: 'one',
            delay: requestLatency,
          );
          final remotes = {'one': remote};

          final c = createBenchmarkController(store, remotes);
          addTearDown(c.dispose);

          await c.load();
          await c.saveInbound(f.inbound('one', '1' * 32));

          // 1. Time local saveUser()
          final localTimer = Stopwatch()..start();
          final newUser = VpnUser(id: f.alice, login: 'alice', name: 'Alice');
          await c.saveUser(newUser);
          localTimer.stop();
          final localMs = localTimer.elapsedMilliseconds;

          expect(c.workspace.users.single.id, f.alice);
          expect(c.workspace.users.single.enabled, isTrue);

          // 2. Time synchronous remote apply (as called directly in UsersPage.edit line 95)
          final serverTimer = Stopwatch()..start();
          await c.prepareAndApply();
          serverTimer.stop();
          final serverMs = serverTimer.elapsedMilliseconds;

          final totalMs = localMs + serverMs;
          final serverPercent = totalMs > 0
              ? (serverMs / totalMs * 100).toStringAsFixed(1)
              : '100';

          debugPrint(
            '[Benchmark D1 - Timing Breakdown] '
            'local_save_ms=$localMs '
            'remote_apply_ms=$serverMs '
            'total_ui_wait_ms=$totalMs '
            'remote_overhead_percent=$serverPercent%',
          );

          // Assert that local save is instantaneous while remote apply dominates execution time
          expect(localMs, lessThan(serverMs));
          expect(serverMs, greaterThanOrEqualTo(50));
        },
      );

      test(
        'reproduce UI freeze: controller.foregroundBusy blocks user interaction during synchronous remote apply',
        () async {
          final store = BenchmarkStore();
          final remote = BenchmarkRemote(
            store,
            serverId: 'one',
            delay: const Duration(milliseconds: 30),
          );
          final remotes = {'one': remote};

          final c = createBenchmarkController(store, remotes);
          addTearDown(c.dispose);

          await c.load();
          await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
          await c.saveInbound(f.inbound('one', '1' * 32));
          await c.prepareAndApply();

          // Simulate saveUser() - instant local persistence
          final localTimer = Stopwatch()..start();
          await c.saveUser(
            VpnUser(id: f.alice, login: 'alice', name: 'Alice', enabled: false),
          );
          localTimer.stop();
          expect(c.workspace.users.single.enabled, isFalse);
          expect(c.foregroundBusy, isFalse);

          // When prepareAndApply() is invoked synchronously right after saveUser (as done in UsersPage.edit line 95):
          final busyStates = <bool>[];
          c.addListener(() => busyStates.add(c.foregroundBusy));

          final applyFuture = c.prepareAndApply();
          // Give event loop one turn to enter _run and set busy = true
          await Future<void>.delayed(Duration.zero);
          expect(
            c.foregroundBusy,
            isTrue,
            reason:
                'UI is locked in foregroundBusy while prepareAndApply() runs',
          );
          await applyFuture;
          expect(c.foregroundBusy, isFalse);

          expect(busyStates, contains(true));
          debugPrint(
            '[Benchmark D2 - Foreground Busy] '
            'local_save_ms=${localTimer.elapsedMilliseconds} '
            'local_enabled=${c.workspace.users.single.enabled} '
            'foregroundBusy_triggered=true '
            'busy_transitions=${busyStates.length}',
          );
        },
      );

      test(
        'reproduce failure propagation: remote failure in prepareAndApply() taints edit flow despite local save succeeding',
        () async {
          final store = BenchmarkStore();
          final remote = BenchmarkRemote(store, serverId: 'one');
          final remotes = {'one': remote};

          final c = createBenchmarkController(store, remotes);
          addTearDown(c.dispose);

          await c.load();
          await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
          await c.saveInbound(f.inbound('one', '1' * 32));
          await c.prepareAndApply();

          // Make remote fail on next request
          remote.failOnRequest = true;

          // Simulate saveUser + prepareAndApply sequence from UsersPage.edit
          final editedUser = VpnUser(
            id: f.alice,
            login: 'alice',
            name: 'AliceRenamed',
            enabled: false,
          );
          await c.saveUser(editedUser);

          // Local state was saved successfully
          expect(c.error, isNull);
          expect(c.workspace.users.single.name, 'AliceRenamed');
          expect(c.workspace.users.single.enabled, isFalse);

          // But synchronous prepareAndApply fails because remote is unreachable
          try {
            await c.prepareAndApply();
          } catch (_) {}

          // Entire controller is tainted with network error
          expect(c.error, 'vpn_connection');
          debugPrint(
            '[Benchmark D3 - Failure Propagation] '
            'local_saved=true '
            'remote_error=${c.error}',
          );
        },
      );

      test(
        'verify background prepareAndApply keeps foregroundBusy false and prevents UI freeze',
        () async {
          final store = BenchmarkStore();
          final remote = BenchmarkRemote(
            store,
            serverId: 'one',
            delay: const Duration(milliseconds: 30),
          );
          final remotes = {'one': remote};

          final c = createBenchmarkController(store, remotes);
          addTearDown(c.dispose);

          await c.load();
          await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
          await c.saveInbound(f.inbound('one', '1' * 32));
          await c.prepareAndApply();

          final busyStates = <bool>[];
          c.addListener(() => busyStates.add(c.foregroundBusy));

          final applyFuture = c.prepareAndApply(background: true);
          await Future<void>.delayed(Duration.zero);
          expect(
            c.foregroundBusy,
            isFalse,
            reason: 'foregroundBusy MUST remain false during background apply',
          );
          await applyFuture;
          expect(c.foregroundBusy, isFalse);
          expect(busyStates.every((b) => b == false), isTrue);
        },
      );

      test(
        'verify background prepareAndApply sets serverSyncIssue without setting controller.error',
        () async {
          final store = BenchmarkStore();
          final remote = BenchmarkRemote(store, serverId: 'one');
          final remotes = {'one': remote};

          final c = createBenchmarkController(store, remotes);
          addTearDown(c.dispose);

          await c.load();
          await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
          await c.saveInbound(f.inbound('one', '1' * 32));
          await c.prepareAndApply();

          remote.failOnRequest = true;

          final editedUser = VpnUser(
            id: f.alice,
            login: 'alice',
            name: 'AliceRenamed',
            enabled: false,
          );
          await c.saveUser(editedUser);
          expect(c.error, isNull);

          await c.prepareAndApply(background: true);

          // Controller error is NOT tainted (UI shows no modal error banner)
          expect(c.error, isNull);
          // Background issue is captured in serverSyncIssue
          expect(c.serverSyncIssue, 'vpn_connection');
          // Local user edit is completely preserved
          expect(c.workspace.users.single.name, 'AliceRenamed');
        },
      );
    },
  );
}
