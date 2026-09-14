import 'dart:convert';

import 'runner_contract.g.dart';
import 'ssh.dart';
export 'runner_contract.g.dart' show validateRunnerRequest;

enum RunnerIssue {
  prerequisites,
  conflict,
  incompatible,
  installFailed,
  invalidResponse,
  unavailable,
  storage,
}

final class RunnerFailure implements Exception {
  const RunnerFailure(this.issue);
  final RunnerIssue issue;
  @override
  String toString() => 'RunnerFailure(${issue.name})';
}

final class RunnerRequest {
  RunnerRequest.fromJson(Map<String, Object?> value)
    : json = Map.unmodifiable(value) {
    validateRunnerRequest(value);
  }
  factory RunnerRequest.list() =>
      RunnerRequest.fromJson({'version': 1, 'action': 'list'});
  factory RunnerRequest.status(String id, int cursor) => RunnerRequest.fromJson(
    {'version': 1, 'action': 'status', 'id': id, 'cursor': cursor},
  );
  factory RunnerRequest.cancel(String id) =>
      RunnerRequest.fromJson({'version': 1, 'action': 'cancel', 'id': id});
  factory RunnerRequest.resume(String id) =>
      RunnerRequest.fromJson({'version': 1, 'action': 'resume', 'id': id});
  factory RunnerRequest.panelPlan(int port) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'panel_plan',
    'port': port,
  });
  factory RunnerRequest.panelVerify(String id) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'panel_verify',
    'id': id,
  });
  factory RunnerRequest.panelInstall(String id, PanelPlan plan) =>
      RunnerRequest.fromJson({
        'version': 1,
        'action': 'submit',
        'id': id,
        'kind': 'panel_install',
        'count': 6,
        'interval': 1,
        'port': plan.port,
        'fingerprint': plan.fingerprint,
      });
  factory RunnerRequest.diagnostic(
    String id, {
    int count = 10,
    int interval = 2,
  }) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'submit',
    'id': id,
    'kind': 'diagnostic',
    'count': count,
    'interval': interval,
  });
  final Map<String, Object?> json;
  String? get id => json['id'] as String?;
}

final class RunnerEvent {
  RunnerEvent.fromJson(Map<String, dynamic> json)
    : sequence = json['sequence'] as int,
      timestamp = DateTime.fromMillisecondsSinceEpoch(
        ((json['timestamp'] as num) * 1000).round(),
        isUtc: true,
      ),
      code = json['code'] as String,
      progress = json['progress'] as int,
      total = json['total'] as int {
    if (sequence < 1 ||
        !(runnerSchema['events'] as List).contains(code) ||
        progress < 0 ||
        progress > total ||
        total < 1 ||
        total > 60) {
      throw const FormatException('runner_event');
    }
  }
  final int sequence;
  final DateTime timestamp;
  final String code;
  final int progress;
  final int total;
  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'timestamp': timestamp.millisecondsSinceEpoch / 1000,
    'code': code,
    'progress': progress,
    'total': total,
  };
}

final class RunnerJob {
  RunnerJob.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      kind = json['kind'] as String,
      status = json['status'] as String,
      checkpoint = json['checkpoint'] as int,
      count = json['count'] as int,
      interval = json['interval'] as int,
      sequence = json['sequence'] as int,
      cancelRequested = json['cancelRequested'] as bool,
      events = List.unmodifiable(
        (json['events'] as List).map(
          (e) => RunnerEvent.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      ) {
    RunnerRequest.diagnostic(id, count: count, interval: interval);
    if (!const {'diagnostic', 'panel_install'}.contains(kind) ||
        (kind == 'panel_install' && (count != 6 || interval != 1)) ||
        !(runnerSchema['states'] as List).contains(status) ||
        checkpoint < 0 ||
        checkpoint > count ||
        sequence < 1 ||
        events.length > (runnerSchema['maxEvents'] as int)) {
      throw const FormatException('runner_job');
    }
    var previous = 0;
    for (final event in events) {
      if (event.sequence <= previous ||
          event.sequence > sequence ||
          event.total != count) {
        throw const FormatException('runner_sequence');
      }
      previous = event.sequence;
    }
  }
  final String id;
  final String kind;
  final String status;
  final int checkpoint;
  final int count;
  final int interval;
  final int sequence;
  final bool cancelRequested;
  final List<RunnerEvent> events;
  bool get terminal => (runnerSchema['terminal'] as List).contains(status);
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'status': status,
    'checkpoint': checkpoint,
    'count': count,
    'interval': interval,
    'sequence': sequence,
    'cancelRequested': cancelRequested,
    'events': events.map((e) => e.toJson()).toList(),
  };
  RunnerJob mergeEvents(RunnerJob? previous) {
    if (previous == null || previous.id != id) return this;
    final merged = {
      for (final e in previous.events) e.sequence: e,
      for (final e in events) e.sequence: e,
    }.values.toList()..sort((a, b) => a.sequence.compareTo(b.sequence));
    final limit = runnerSchema['maxEvents'] as int;
    return RunnerJob.fromJson({
      ...toJson(),
      'events': merged
          .skip(merged.length > limit ? merged.length - limit : 0)
          .map((e) => e.toJson())
          .toList(),
    });
  }
}

final class RunnerResponse {
  RunnerResponse.fromJson(Map<String, dynamic> value)
    : code = value['code'] as String,
      panelPlan = value['panelPlan'] == null
          ? null
          : PanelPlan.fromJson(
              Map<String, dynamic>.from(value['panelPlan'] as Map),
            ),
      panelAccess = value['panelAccess'] == null
          ? null
          : PanelAccess.fromJson(
              Map<String, dynamic>.from(value['panelAccess'] as Map),
            ),
      panelVerified = value['panelVerified'] == true,
      alive = value['alive'] as bool,
      jobs = List.unmodifiable(
        (value['jobs'] as List).map(
          (e) => RunnerJob.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      ) {
    if (value['version'] != runnerSchema['version'] ||
        !(runnerSchema['codes'] as List).contains(code) ||
        jobs.length > (runnerSchema['pageSize'] as int)) {
      throw const FormatException('runner_response');
    }
  }
  final String code;
  final PanelPlan? panelPlan;
  final PanelAccess? panelAccess;
  final bool panelVerified;
  final bool alive;
  final List<RunnerJob> jobs;
}

final class RunnerInstallation {
  RunnerInstallation.fromJson(Map<String, dynamic> value)
    : supported = value['supported'] as bool,
      state = value['state'] as String,
      release = value['release'] as String?,
      fingerprint = value['fingerprint'] as String,
      upgradable = value['upgradable'] == true,
      active = value['active'] as bool {
    if (!const {
          'missing',
          'installed',
          'partial',
          'conflict',
        }.contains(state) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
        (release != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(release!))) {
      throw const FormatException('runner_installation');
    }
  }
  final bool supported;
  final String state;
  final String? release;
  final String fingerprint;
  final bool active;
  final bool upgradable;
}

final class PanelPlan {
  PanelPlan.fromJson(Map<String, dynamic> json)
    : state = json['state'] as String,
      supported = json['supported'] as bool,
      portAvailable = json['portAvailable'] as bool,
      port = json['port'] as int,
      fingerprint = json['fingerprint'] as String,
      panelVersion = json['panelVersion'] as String,
      xrayVersion = json['xrayVersion'] as String,
      sha256 = json['sha256'] as String,
      bytes = json['bytes'] as int,
      prerequisites = List<String>.from(json['prerequisites'] as List) {
    RunnerRequest.panelPlan(port);
    if (!const {'missing', 'existing'}.contains(state) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        bytes < 1) {
      throw const FormatException('panel_plan');
    }
  }
  final String state, fingerprint, panelVersion, xrayVersion, sha256;
  final bool supported, portAvailable;
  final int port, bytes;
  final List<String> prerequisites;
  bool get canApply => state == 'missing' && supported && portAvailable;
}

final class PanelAccess {
  PanelAccess.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      port = json['port'] as int,
      username = json['username'] as String,
      password = json['password'] as String,
      panelVersion = json['panelVersion'] as String,
      xrayVersion = json['xrayVersion'] as String {
    RunnerRequest.panelVerify(id);
    RunnerRequest.panelPlan(port);
    if (username != 'antirkn' ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(password)) {
      throw const FormatException('panel_access');
    }
  }
  final String id, username, password, panelVersion, xrayVersion;
  final int port;
  Map<String, Object?> toJson() => {
    'id': id,
    'port': port,
    'username': username,
    'password': password,
    'panelVersion': panelVersion,
    'xrayVersion': xrayVersion,
  };
  @override
  String toString() => 'PanelAccess(redacted)';
}

abstract interface class RunnerTransport {
  String get bundledRelease;
  Future<RunnerInstallation> inspect(CancellationToken cancellation);
  Future<RunnerInstallation> install(
    RunnerInstallation plan,
    CancellationToken cancellation, {
    String? sudoPassword,
  });
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken cancellation, {
    String? sudoPassword,
  });
}

abstract interface class RunnerJournalStore {
  Future<String?> readRunnerJournal(String serverId);
  Future<void> writeRunnerJournal(String serverId, String source);
}

Map<String, dynamic> decodeRunnerObject(String source) =>
    Map<String, dynamic>.from(jsonDecode(source) as Map);
