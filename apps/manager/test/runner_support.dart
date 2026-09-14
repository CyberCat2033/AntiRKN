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
  int submissions = 0;
  int cancellations = 0;
  Completer<void>? submitGate;
  RunnerJob? job;
  String panelState = 'missing';
  String panelFingerprint = 'c' * 64;
  bool panelPortAvailable = true;
  bool panelSupported = true;
  int panelChecks = 0;
  final requests = <RunnerRequest>[];
  @override
  String get bundledRelease => 'a' * 64;
  @override
  Future<RunnerInstallation> inspect(CancellationToken cancellation) async =>
      RunnerInstallation.fromJson({
        'supported': true,
        'state': installed ? 'installed' : 'missing',
        'release': installed ? bundledRelease : null,
        'fingerprint': 'b' * 64,
        'active': installed,
      });
  @override
  Future<RunnerInstallation> install(
    RunnerInstallation plan,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    installs++;
    installed = true;
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
      case 'panel_plan':
        extra['panelPlan'] = {
          'state': panelState,
          'supported': panelSupported,
          'portAvailable': panelPortAvailable,
          'port': request.json['port'],
          'fingerprint': panelFingerprint,
          'panelVersion': '3.7.0',
          'xrayVersion': '26.7.28',
          'sha256': 'd' * 64,
          'bytes': 80280886,
          'prerequisites': <String>[],
        };
      case 'panel_verify':
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
        jobs = [job!];
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
}
