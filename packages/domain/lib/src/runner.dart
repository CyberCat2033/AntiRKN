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
    if (!(runnerSchema['states'] as List).contains(status) ||
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
    'kind': 'diagnostic',
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
  final bool alive;
  final List<RunnerJob> jobs;
}

final class RunnerInstallation {
  RunnerInstallation.fromJson(Map<String, dynamic> value)
    : supported = value['supported'] as bool,
      state = value['state'] as String,
      release = value['release'] as String?,
      fingerprint = value['fingerprint'] as String,
      active = value['active'] as bool {
    if (!const {'missing', 'installed', 'conflict'}.contains(state) ||
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
