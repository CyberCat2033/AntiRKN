import 'dart:convert';

import 'runner_contract.g.dart';
import 'ssh.dart';
export 'runner_contract.g.dart'
    show validateRunnerRequest, verifiedComponentVersions;

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
  factory RunnerRequest.panelUpdatePlan(String panelId) =>
      RunnerRequest.fromJson({
        'version': 1,
        'action': 'panel_update_plan',
        'id': panelId,
      });
  factory RunnerRequest.panelUpdate(String id, PanelUpdatePlan plan) =>
      RunnerRequest.fromJson({
        'version': 1,
        'action': 'submit',
        'id': id,
        'kind': 'panel_update',
        'count': 6,
        'interval': 1,
        'panelId': plan.panelId,
        'fingerprint': plan.fingerprint,
      });
  factory RunnerRequest.componentPlan(String component) =>
      RunnerRequest.fromJson({
        'version': 1,
        'action': 'component_plan',
        'component': component,
      });
  factory RunnerRequest.componentInstall(String id, ComponentPlan plan) =>
      RunnerRequest.fromJson({
        'version': 1,
        'action': 'submit',
        'id': id,
        'kind': 'component_install',
        'count': 6,
        'interval': 1,
        'component': plan.component,
        'fingerprint': plan.fingerprint,
      });
  factory RunnerRequest.realityScan(String id, String target, String sni) =>
      RunnerRequest.fromJson({
        'version': 1,
        'action': 'reality_scan',
        'id': id,
        'target': target,
        'sni': sni,
      });
  factory RunnerRequest.aptPlan() =>
      RunnerRequest.fromJson({'version': 1, 'action': 'apt_plan'});
  factory RunnerRequest.apt(String id, {String? fingerprint}) =>
      RunnerRequest.fromJson({
        'version': 1,
        'action': 'submit',
        'id': id,
        'kind': fingerprint == null ? 'apt_update' : 'apt_upgrade',
        'count': 2,
        'interval': 1,
        'fingerprint': ?fingerprint,
      });
  factory RunnerRequest.list() =>
      RunnerRequest.fromJson({'version': 1, 'action': 'list'});
  factory RunnerRequest.ttDefaults() =>
      RunnerRequest.fromJson({'version': 1, 'action': 'tt_defaults'});
  factory RunnerRequest.ttState(String workspaceId) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'tt_state',
    'id': workspaceId,
  });
  factory RunnerRequest.ttPlan(
    String workspaceId,
    Map<String, Object?> payload,
  ) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'tt_plan',
    'id': workspaceId,
    'payload': jsonEncode(payload),
  });
  factory RunnerRequest.ttApply(
    String id,
    Map<String, Object?> payload,
    String fingerprint,
  ) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'submit',
    'kind': 'tt_apply',
    'id': id,
    'count': (payload['resources'] as List).length + 2,
    'interval': 1,
    'payload': jsonEncode(payload),
    'fingerprint': fingerprint,
  });
  factory RunnerRequest.awgDefaults() =>
      RunnerRequest.fromJson({'version': 1, 'action': 'awg_defaults'});
  factory RunnerRequest.awgState(String workspaceId) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'awg_state',
    'id': workspaceId,
  });
  factory RunnerRequest.awgPlan(
    String workspaceId,
    Map<String, Object?> payload,
  ) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'awg_plan',
    'id': workspaceId,
    'payload': jsonEncode(payload),
  });
  factory RunnerRequest.awgApply(
    String id,
    Map<String, Object?> payload,
    String fingerprint,
  ) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'submit',
    'kind': 'awg_apply',
    'id': id,
    'count': (payload['resources'] as List).length + 2,
    'interval': 1,
    'payload': jsonEncode(payload),
    'fingerprint': fingerprint,
  });
  factory RunnerRequest.vlessPlan(
    String panelId,
    Map<String, Object?> payload,
  ) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'vless_plan',
    'id': panelId,
    'payload': jsonEncode(payload),
  });
  factory RunnerRequest.vlessState(String panelId) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'vless_state',
    'id': panelId,
  });
  factory RunnerRequest.vlessApply(
    String id,
    Map<String, Object?> payload,
    String fingerprint,
  ) => RunnerRequest.fromJson({
    'version': 1,
    'action': 'submit',
    'id': id,
    'kind': 'vless_apply',
    'count': (payload['resources'] as List).length + 2,
    'interval': 1,
    'payload': jsonEncode(payload),
    'fingerprint': fingerprint,
  });
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
  factory RunnerRequest.panelCli() =>
      RunnerRequest.fromJson({'version': 1, 'action': 'panel_cli'});
  factory RunnerRequest.panelDiscover() =>
      RunnerRequest.fromJson({'version': 1, 'action': 'panel_discover'});
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
    if (!const {
          'diagnostic',
          'panel_install',
          'panel_update',
          'vless_apply',
          'awg_apply',
          'awg_external_edit',
          'tt_apply',
          'tt_external_edit',
          'tt_certificate',
          'component_install',
          'protocol_remove',
          'inbound_update',
          'apt_update',
          'apt_upgrade',
        }.contains(kind) ||
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
    : removalPlan = value['removalPlan'] == null
          ? null
          : Map<String, dynamic>.from(value['removalPlan'] as Map),
      tt = value['tt'] == null
          ? null
          : Map<String, dynamic>.from(value['tt'] as Map),
      awgExternal = value['awgExternal'] == null
          ? null
          : Map<String, dynamic>.from(value['awgExternal'] as Map),
      awgDefaults = value['awgDefaults'] == null
          ? null
          : Map<String, dynamic>.from(value['awgDefaults'] as Map),
      awgPlan = value['awgPlan'] == null
          ? null
          : Map<String, dynamic>.from(value['awgPlan'] as Map),
      awgState = value['awgState'] == null
          ? null
          : (value['awgState'] as List)
                .map((v) => Map<String, dynamic>.from(v as Map))
                .toList(),
      code = value['code'] as String,
      panelUpdatePlan = value['panelUpdatePlan'] == null
          ? null
          : PanelUpdatePlan.fromJson(
              Map<String, dynamic>.from(value['panelUpdatePlan'] as Map),
            ),
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
      componentPlan = value['componentPlan'] == null
          ? null
          : ComponentPlan.fromJson(
              Map<String, dynamic>.from(value['componentPlan'] as Map),
            ),
      inboundSnapshot = value['inboundSnapshot'] == null
          ? null
          : Map<String, dynamic>.from(value['inboundSnapshot'] as Map),
      inboundPlan = value['inboundPlan'] == null
          ? null
          : Map<String, dynamic>.from(value['inboundPlan'] as Map),
      aptPlan = value['aptPlan'] == null
          ? null
          : Map<String, dynamic>.from(value['aptPlan'] as Map),
      panelDiscovery = value['panelDiscovery'] == null
          ? null
          : Map<String, dynamic>.from(value['panelDiscovery'] as Map),
      realityScan = value['realityScan'] == null
          ? null
          : Map<String, dynamic>.from(value['realityScan'] as Map),
      panelVerified = value['panelVerified'] == true,
      vlessPlan = value['vlessPlan'] == null
          ? null
          : Map<String, dynamic>.unmodifiable(value['vlessPlan'] as Map),
      vlessState = value['vlessState'] == null
          ? null
          : List<Map<String, dynamic>>.unmodifiable(
              (value['vlessState'] as List).map(
                (e) => Map<String, dynamic>.from(e as Map),
              ),
            ),
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
  final Map<String, dynamic>? removalPlan;
  final Map<String, dynamic>? awgDefaults, awgPlan, awgExternal, tt;
  final List<Map<String, dynamic>>? awgState;
  final PanelUpdatePlan? panelUpdatePlan;
  final Map<String, dynamic>? inboundSnapshot, inboundPlan;
  final Map<String, dynamic>? aptPlan;
  final PanelPlan? panelPlan;
  final ComponentPlan? componentPlan;
  final PanelAccess? panelAccess;
  final Map<String, dynamic>? panelDiscovery;
  final Map<String, dynamic>? realityScan;
  final bool panelVerified;
  final Map<String, dynamic>? vlessPlan;
  final List<Map<String, dynamic>>? vlessState;
  final bool alive;
  final List<RunnerJob> jobs;
}

final class PanelUpdatePlan {
  PanelUpdatePlan.fromJson(Map<String, dynamic> json)
    : panelId = json['panelId'] as String,
      state = json['state'] as String,
      supported = json['supported'] as bool,
      fingerprint = json['fingerprint'] as String,
      installedPanelVersion = json['installedPanelVersion'] as String?,
      installedXrayVersion = json['installedXrayVersion'] as String?,
      panelVersion = json['panelVersion'] as String,
      xrayVersion = json['xrayVersion'] as String,
      coreUrl = json['coreUrl'] as String,
      coreSha256 = json['coreSha256'] as String,
      url = json['url'] as String,
      sha256 = json['sha256'] as String,
      bytes = json['bytes'] as int,
      paths = List<String>.from(json['paths'] as List),
      backupRoot = json['backupRoot'] as String {
    RunnerRequest.panelUpdatePlan(panelId);
    if (!const {'update', 'current', 'incompatible'}.contains(state) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        bytes < 1) {
      throw const FormatException('panel_update_plan');
    }
  }
  final String panelId,
      state,
      fingerprint,
      panelVersion,
      xrayVersion,
      url,
      sha256,
      backupRoot;
  final String coreUrl, coreSha256;
  final String? installedPanelVersion, installedXrayVersion;
  final bool supported;
  final int bytes;
  final List<String> paths;
  bool get canApply => supported && state == 'update';
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
      managed = json['managed'] != false,
      tls = json['tls'] == true,
      basePath = json['basePath'] as String? ?? '/',
      username = json['username'] as String,
      password = json['password'] as String,
      panelVersion = json['panelVersion'] as String,
      xrayVersion = json['xrayVersion'] as String {
    RunnerRequest.panelVerify(id);
    if (port < 1 ||
        port > 65535 ||
        !RegExp(r'^/[A-Za-z0-9_/-]*$').hasMatch(basePath) ||
        basePath.length > 2048 ||
        username.isEmpty ||
        username.length > 256 ||
        password.isEmpty ||
        password.length > 4096 ||
        (managed &&
            (username != 'antirkn' ||
                !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(password)))) {
      throw const FormatException('panel_access');
    }
  }
  final String id, username, password, panelVersion, xrayVersion, basePath;
  final bool managed, tls;
  final int port;
  Map<String, Object?> toJson() => {
    'id': id,
    'port': port,
    'managed': managed,
    'tls': tls,
    'basePath': basePath,
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

/// Prevents an old controller from overwriting a journal received through sync
/// or changed by another local process. Compare and write are one transaction.
abstract interface class ConditionalRunnerJournalStore {
  Future<void> writeRunnerJournalIfUnchanged(
    String serverId,
    String source, {
    required String? expectedSource,
  });
}

Map<String, dynamic> decodeRunnerObject(String source) =>
    Map<String, dynamic>.from(jsonDecode(source) as Map);

final class ComponentPlan {
  ComponentPlan.fromJson(Map<String, dynamic> json)
    : component = json['component'] as String,
      state = json['state'] as String,
      supported = json['supported'] as bool,
      version = json['version'] as String,
      installedVersion = json['installedVersion'] as String?,
      toolsVersion = json['toolsVersion'] as String?,
      fingerprint = json['fingerprint'] as String,
      activeUnits = List<String>.from(json['activeUnits'] as List? ?? const []),
      archives = Map<String, dynamic>.unmodifiable(json['archives'] as Map),
      prerequisites = List<String>.from(json['prerequisites'] as List) {
    RunnerRequest.componentPlan(component);
    if (!const {
          'missing',
          'current',
          'update',
          'conflict',
          'incompatible',
        }.contains(state) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('component_plan');
    }
  }
  final String component, state, version, fingerprint;
  final String? installedVersion, toolsVersion;
  final bool supported;
  final Map<String, dynamic> archives;
  final List<String> prerequisites;
  final List<String> activeUnits;
  bool get canApply => supported && const {'missing', 'update'}.contains(state);
}
