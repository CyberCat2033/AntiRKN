import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';

RunnerJob runnerJob(
  String id, {
  String status = 'running',
  int progress = 1,
  int sequence = 2,
  String kind = 'diagnostic',
  int count = 10,
  int interval = 2,
  List<Map<String, Object?>>? events,
}) => RunnerJob.fromJson({
  'id': id,
  'kind': kind,
  'status': status,
  'checkpoint': progress,
  'count': count,
  'interval': interval,
  'sequence': sequence,
  'cancelRequested': status == 'cancelled',
  'events':
      events ??
      [
        {
          'sequence': sequence,
          'timestamp': 1789340000,
          'code': status == 'running' ? 'sample' : status,
          'progress': progress,
          'total': count,
        },
      ],
});

class MemoryRunnerJournal implements RunnerJournalStore {
  String? value;
  bool failWrite = false;
  @override
  Future<String?> readRunnerJournal(String id) async => value;
  @override
  Future<void> writeRunnerJournal(String id, String source) async {
    if (failWrite) throw const VaultFailure(VaultIssue.writeFailed);
    value = source;
  }
}

class FakeRunnerTransport implements RunnerTransport {
  FakeRunnerTransport(this.store);
  final MemoryRunnerJournal store;
  bool installed = false;
  bool loseSubmitResponse = false;
  bool failStatus = false;
  bool submitWithoutPersistence = false;
  int installs = 0;
  int inspections = 0;
  int submissions = 0;
  int cancellations = 0;
  Completer<void>? submitGate;
  RunnerJob? job;
  List<RunnerJob>? customSubmitJobs;
  Map<String, dynamic>? discovery;
  Map<String, dynamic>? recoveredAccess;
  String panelState = 'missing';
  String panelUpdateState = 'update';
  String? panelUpdateCode;
  String panelVerifyCode = 'ok';
  String panelFingerprint = 'c' * 64;
  bool panelPortAvailable = true;
  bool panelSupported = true;
  int panelChecks = 0;
  String? customRelease;
  bool upgradable = false;
  Map<String, dynamic>? componentUpgradePlanData;
  final requests = <RunnerRequest>[];
  @override
  String get bundledRelease => 'a' * 64;
  @override
  Future<RunnerInstallation> inspect(CancellationToken cancellation) async {
    inspections++;
    return RunnerInstallation.fromJson({
      'supported': true,
      'state': installed ? 'installed' : 'missing',
      'release': installed ? (customRelease ?? bundledRelease) : null,
      'fingerprint': 'b' * 64,
      'active': installed,
      'upgradable': upgradable,
    });
  }

  @override
  Future<RunnerInstallation> install(
    RunnerInstallation plan,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    installs++;
    installed = true;
    customRelease = null;
    upgradable = false;
    return inspect(cancellation);
  }

  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    requests.add(request);
    var code = 'ok';
    var jobs = <RunnerJob>[];
    final extra = <String, Object?>{};
    switch (request.json['action']) {
      case 'panel_update_plan':
        if (panelUpdateCode != null) {
          code = panelUpdateCode!;
        } else {
          extra['panelUpdatePlan'] = {
            'panelId': request.id,
            'state': panelUpdateState,
            'supported': panelSupported,
            'fingerprint': panelFingerprint,
            'installedPanelVersion': '3.7.0',
            'installedXrayVersion': '26.7.28',
            'panelVersion': '3.8.0',
            'xrayVersion': '26.7.28',
            'url':
                'https://github.com/MHSanaei/3x-ui/releases/download/v3.8.0/x-ui-linux-amd64.tar.gz',
            'sha256': 'd' * 64,
            'bytes': 82291492,
            'paths': ['/usr/local/x-ui/x-ui'],
            'backupRoot': '/var/lib/antirkn-runner',
            'coreUrl':
                'https://github.com/MHSanaei/3x-ui/releases/download/v3.7.0/x-ui-linux-amd64.tar.gz',
            'coreSha256': 'e' * 64,
          };
        }
      case 'apt_plan':
        extra['aptPlan'] = {
          'packages': [
            {'name': 'fixture', 'installed': '1', 'version': '2'},
          ],
          'fingerprint': 'f' * 64,
          'rebootRequired': false,
        };
      case 'component_upgrade_check':
        extra['componentUpgrade'] =
            componentUpgradePlanData ??
            {
              'component': request.json['component'],
              'installed': true,
              'source': 'native',
              'currentVersion': '26.7.28',
              'candidateVersion': '26.9.9',
              'binaryPath': '/usr/local/bin/xray',
              'configPath': '/usr/local/etc/xray/config.json',
              'units': ['xray.service'],
              'upgradable': true,
              'arch': 'x86_64',
              'fingerprint': 'c' * 64,
              'ready': true,
            };
      case 'panel_discover':
        extra['panelAccess'] = recoveredAccess;
        extra['panelDiscovery'] =
            discovery ??
            {'panels': <Object?>[], 'failed': false, 'cliAvailable': false};
      case 'component_plan':
        extra['componentPlan'] = {
          'component': request.json['component'],
          'state': panelState,
          'supported': panelSupported,
          'version': '1.1.0',
          'installedVersion': null,
          'toolsVersion': null,
          'fingerprint': panelFingerprint,
          'archives': <String, dynamic>{},
          'prerequisites': <String>[],
        };
      case 'panel_plan':
        extra['panelPlan'] = {
          'state': panelState,
          'supported': panelSupported,
          'portAvailable': panelPortAvailable,
          'port': request.json['port'] == 0 ? 43127 : request.json['port'],
          'fingerprint': panelFingerprint,
          'panelVersion': '3.7.0',
          'xrayVersion': '26.7.28',
          'sha256': 'd' * 64,
          'bytes': 80280886,
          'prerequisites': <String>[],
        };
      case 'panel_verify':
        code = panelVerifyCode;
        panelChecks++;
        extra['panelVerified'] = true;
        extra['panelAccess'] = {
          'id': request.id,
          'port': 2053,
          'username': 'antirkn',
          'password': 'A' * 43,
          'panelVersion': '3.7.0',
          'xrayVersion': '26.7.28',
        };
      case 'submit':
        submissions++;
        if (store.value == null ||
            (jsonDecode(store.value!) as Map)['pending']?['id'] != request.id) {
          submitWithoutPersistence = true;
        }
        await submitGate?.future;
        job ??= runnerJob(
          request.id!,
          kind: request.json['kind'] as String,
          count: request.json['count'] as int,
          interval: request.json['interval'] as int,
        );
        if (loseSubmitResponse) throw const SshFailure(SshIssue.disconnected);
        jobs = customSubmitJobs ?? [job!];
      case 'list':
        jobs = [?job];
      case 'status':
        if (failStatus) throw const RunnerFailure(RunnerIssue.invalidResponse);
        if (job == null || job!.id != request.id) {
          code = 'missing';
        } else {
          final json = job!.toJson();
          json['events'] = job!.events
              .where((e) => e.sequence > (request.json['cursor'] as int))
              .map((e) => e.toJson())
              .toList();
          jobs = [RunnerJob.fromJson(json)];
        }
      case 'cancel':
        cancellations++;
        job = runnerJob(request.id!, status: 'cancelled');
        jobs = [job!];
    }
    return RunnerResponse.fromJson({
      'version': 1,
      'code': code,
      'alive': installed,
      'jobs': jobs.map((j) => j.toJson()).toList(),
      ...extra,
    });
  }

  int emergencyResets = 0;
  @override
  Future<void> emergencyReset(
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    emergencyResets++;
    if (job != null) {
      job = runnerJob(job!.id, status: 'cancelled');
    }
  }
}
