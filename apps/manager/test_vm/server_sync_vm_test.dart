// Drives the real VpnController against a disposable QEMU VM: real SSH
// transport, real runner, real 3x-ui and an on-disk WorkspaceDatabase.
//
// Skipped unless ANTIRKN_VM_DIRECTORY names a VM booted by tool/runner_vm.py
// (client key, fingerprint and port files). Never point it at the manual
// artifacts/local-server VM or at a real server: it upgrades the runner and
// creates inbounds and clients.
//
//   ANTIRKN_VM_DIRECTORY=$PWD/artifacts/<vm> flutter test --no-pub \
//     test_vm/server_sync_vm_test.dart
//
// Optional: ANTIRKN_SYNC_REPORT=<file> writes the measurements as JSON;
// ANTIRKN_SYNC_SCRATCH=<dir> holds the temporary workspace database.
//
// Only API present before and after the "check reads state first" change is
// used, so the same file measures both versions.
import 'dart:convert';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

const _template =
    '{"proxies":[],"proxy-groups":[{"name":"ALL","type":"select","include-all-proxies":true}],"rules":["MATCH,ALL"]}';
const _fallbackPanel = '10000000000000000000000000000001';

/// Records every runner action the controller sends; secrets are not kept.
final class _LoggingTransport implements RunnerTransport {
  _LoggingTransport(this.inner);
  final RunnerTransport inner;
  final log = <String>[];
  @override
  String get bundledRelease => inner.bundledRelease;
  @override
  Future<RunnerInstallation> inspect(CancellationToken c) => inner.inspect(c);
  @override
  Future<RunnerInstallation> install(
    RunnerInstallation plan,
    CancellationToken c, {
    String? sudoPassword,
  }) => inner.install(plan, c, sudoPassword: sudoPassword);
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken c, {
    String? sudoPassword,
  }) {
    final action = request.json['action'] as String;
    log.add(action == 'submit' ? 'submit:${request.json['kind']}' : action);
    return inner.request(request, c, sudoPassword: sudoPassword);
  }

  @override
  Future<void> emergencyReset(CancellationToken c, {String? sudoPassword}) =>
      inner.emergencyReset(c, sudoPassword: sudoPassword);
}

void main() {
  final vmDirectory = Platform.environment['ANTIRKN_VM_DIRECTORY'];
  test(
    'server check on a real VM: settled, one change, second press',
    () async {
      final vm = Directory(vmDirectory!);
      final port = int.parse(File('${vm.path}/port').readAsStringSync().trim());
      final pinned = File('${vm.path}/fingerprint').readAsStringSync().trim();
      Future<String> shell(String command) async {
        final result = await Process.run('ssh', [
          '-F', '/dev/null', '-i', '${vm.path}/client', //
          '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
          '-o', 'ConnectTimeout=5',
          '-o', 'UserKnownHostsFile=${vm.path}/known_hosts',
          '-p', '$port', 'root@127.0.0.1', command,
        ]).timeout(const Duration(seconds: 60));
        if (result.exitCode != 0) {
          throw StateError('vm_shell_failed ${result.exitCode}');
        }
        return (result.stdout as String).trim();
      }

      Future<Map<String, Object?>> xray() async {
        final out = await shell(
          r'p=$(pgrep -f xray-linux | head -1); echo "$p|$(ps -o lstart= -p "$p")"',
        );
        final parts = out.split('|');
        return {'pid': parts.first, 'started': parts.last.trim()};
      }

      Future<List<Map<String, Object?>>> jobs() async {
        final out = await shell(
          "python3 -I -c \"import sqlite3,json\n"
          "db=sqlite3.connect('file:/var/lib/antirkn-runner/jobs.sqlite?mode=ro',uri=True)\n"
          "print(json.dumps([dict(id=i,status=s,kind=json.loads(r).get('kind'),created=c) "
          "for i,r,s,c in db.execute('select id,request,status,created from jobs order by created')]))\"",
        );
        return (jsonDecode(out) as List).cast<Map<String, Object?>>();
      }

      final scratch = await Directory(
        Platform.environment['ANTIRKN_SYNC_SCRATCH'] ??
            Directory.systemTemp.path,
      ).createTemp('sync-vm-');
      final db = WorkspaceDatabase.open(
        '${scratch.path}/workspace.sqlite',
        key: SecretKeyData.random(length: 32),
      );
      final key = File('${vm.path}/client').readAsStringSync();
      final profile = SshProfile(
        id: 'a1' * 16,
        host: '127.0.0.1',
        port: port,
        username: 'root',
        authMethod: SshAuthMethod.privateKey,
        secrets: {ServerSecret.privateKey: key},
      );
      final token = CancellationToken();
      final connection = await const DartSshConnector().connect(
        profile,
        verifyHostKey: (hostKey) async =>
            hostKey.fingerprint == pinned ||
            'SHA256:${hostKey.fingerprint}' == pinned,
        cancellation: token,
      );
      final transport = _LoggingTransport(connection.runner!);
      VpnController? vpn;
      final report = <String, Object?>{};
      try {
        // The app's own install flow: inspect, then install the bundle.
        var installation = await transport.inspect(token);
        report['runnerBefore'] = installation.state;
        if (installation.release != transport.bundledRelease ||
            !installation.active) {
          installation = await transport.install(installation, token);
          report['runnerInstalled'] = true;
        }
        expect(installation.release, transport.bundledRelease);
        expect(installation.active, isTrue);
        final discovered = await transport.request(
          RunnerRequest.panelDiscover(),
          token,
        );
        final panelId = discovered.panelAccess?.id ?? _fallbackPanel;
        final verified = await transport.request(
          RunnerRequest.panelVerify(panelId),
          token,
        );
        expect(verified.panelVerified, isTrue, reason: 'panel_verify');

        final serverId = profile.id;
        vpn = VpnController(
          repository: db,
          recovery: db,
          template: () => _template,
          serverIds: () => [serverId, awgTarget(serverId), ttTarget(serverId)],
          serverName: (_) => 'sync-check-vm',
          remote: (target) => vpnServerId(target) != serverId
              ? null
              : VpnRemote(
                  transport: transport,
                  panelId: (isAwgTarget(target) || isTtTarget(target))
                      ? vpn!.workspace.id
                      : panelId,
                  identity: 'sync-check-vm|$pinned',
                  observationKey: 'sync-check-vm|$pinned|$panelId',
                ),
        );
        final c = vpn;
        await c.load();

        Future<void> settle(String name) async {
          final deadline = DateTime.now().add(const Duration(minutes: 4));
          while (!c.hasCurrentVerifiedProfiles) {
            if (DateTime.now().isAfter(deadline)) {
              fail('$name not verified: ${c.error} ${c.serverSyncIssue}');
            }
            await Future<void>.delayed(const Duration(seconds: 1));
            await c.reconcile();
          }
        }

        // 1. Setup: one VLESS REALITY inbound and two users, applied.
        final alice = VpnUser(id: 'a' * 32, login: 'alice', name: 'Alice');
        final bob = VpnUser(id: 'b' * 32, login: 'bob', name: 'Bob');
        await c.saveUser(alice);
        await c.saveUser(bob);
        await c.saveInbound(
          VlessInbound(
            serverId: serverId,
            spec: {
              ...VlessInbound.defaults(),
              'id': 'c' * 32,
              'port': 24443,
              'externalPort': 24443,
              'endpoint': '203.0.113.10',
              'sni': 'www.cloudflare.com',
              'target': 'www.cloudflare.com:443',
            },
          ),
        );
        final setupWatch = Stopwatch()..start();
        await c.prepareAndApply();
        expect(c.error, isNull, reason: 'setup apply');
        await settle('setup');
        report['setup'] = {
          'ms': setupWatch.elapsedMilliseconds,
          'actions': List.of(transport.log),
        };

        Future<Map<String, Object?>> measure(
          String name,
          Future<ServerProfileSyncResult> Function() action,
        ) async {
          final xrayBefore = await xray();
          final jobsBefore = await jobs();
          transport.log.clear();
          final watch = Stopwatch()..start();
          final result = await action();
          watch.stop();
          final actions = List.of(transport.log);
          final busyAtReturn = c.hasRunning || c.hasObservedRunning;
          final verifiedAtReturn = c.hasCurrentVerifiedProfiles;
          final jobsAtReturn = await jobs();
          final xrayAtReturn = await xray();
          final known = {for (final job in jobsBefore) job['id']};
          final created = [
            for (final job in jobsAtReturn)
              if (!known.contains(job['id']))
                {'kind': job['kind'], 'statusAtReturn': job['status']},
          ];
          final entry = {
            'ms': watch.elapsedMilliseconds,
            'verified': result.verified,
            'issue': result.issue,
            'usedSavedVerification': result.usedSavedVerification,
            'hasCurrentVerifiedProfilesAtReturn': verifiedAtReturn,
            'controllerRunningAtReturn': busyAtReturn,
            'actions': actions,
            'plans': actions.where((a) => a.endsWith('_plan')).length,
            'submits': actions.where((a) => a.startsWith('submit:')).toList(),
            'newJobs': created,
            'xrayRestarted':
                xrayBefore['pid'] != xrayAtReturn['pid'] ||
                xrayBefore['started'] != xrayAtReturn['started'],
          };
          // Settle afterwards so the next scenario starts from the same state.
          await settle(name);
          await Future<void>.delayed(const Duration(seconds: 2));
          final xrayAfter = await xray();
          entry['xrayRestartedAfterReturn'] =
              xrayAtReturn['pid'] != xrayAfter['pid'] ||
              xrayAtReturn['started'] != xrayAfter['started'];
          final finalJobs = {for (final j in await jobs()) j['id']: j};
          entry['newJobsFinal'] = [
            for (final job in finalJobs.values)
              if (!known.contains(job['id']))
                {'kind': job['kind'], 'status': job['status']},
          ];
          // ignore: avoid_print
          print('SYNC_VM $name ${jsonEncode(entry)}');
          return entry;
        }

        // 2. Settled, fresh check: no saved verification is used.
        report['settledFresh'] = await measure(
          'settledFresh',
          () => c.syncAllServersAndProfiles(),
        );
        // 3. One change: disable one user, then press sync.
        await c.saveUser(bob.copyWith(enabled: false));
        report['oneChange'] = await measure(
          'oneChange',
          () => c.syncAllServersAndProfiles(allowVerifiedSnapshot: true),
        );
        // 4. Second press of the fresh check.
        report['secondPress'] = await measure(
          'secondPress',
          () => c.syncAllServersAndProfiles(),
        );
      } finally {
        final file = Platform.environment['ANTIRKN_SYNC_REPORT'];
        if (file != null) {
          File(file).writeAsStringSync(jsonEncode(report));
        }
        vpn?.dispose();
        connection.close();
        await db.close();
        await scratch.delete(recursive: true);
      }
    },
    skip: vmDirectory == null ? 'Set ANTIRKN_VM_DIRECTORY to a test VM' : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
