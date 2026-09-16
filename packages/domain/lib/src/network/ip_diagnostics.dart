import 'dart:async';
import '../ssh.dart';
import 'ip_address.dart';

enum IpProbeKind { tcp, tls, ssh, http }

enum IpProbeStatus {
  reachable,
  timeout,
  refused,
  tlsError,
  protocolError,
  unavailable,
}

enum IpDiagnosticStage {
  baseline,
  target,
  controls,
  recovery,
  complete,
  cancelled,
  networkChanged,
  insufficient,
  degraded,
  failed,
}

enum ControlHealth { healthy, degraded, strong }

final class IpProbeTarget {
  IpProbeTarget(
    String address,
    this.port, {
    this.kind = IpProbeKind.tcp,
    this.host = '',
  }) : address = IpAddress.parse(address) {
    if (port < 1 ||
        port > 65535 ||
        host.length > 253 ||
        host.isNotEmpty && !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(host) ||
        kind == IpProbeKind.tls && host.isEmpty) {
      throw const FormatException('diagnostic_target');
    }
  }
  final IpAddress address;
  final int port;
  final IpProbeKind kind;
  final String host;
  String get key => '${address.canonical}|$port|${kind.name}|$host';
  Map<String, Object?> toJson() => {
    'ip': address.canonical,
    'port': port,
    'kind': kind.name,
    'host': host,
  };
  factory IpProbeTarget.fromJson(Map<String, dynamic> json) => IpProbeTarget(
    json['ip'] as String,
    json['port'] as int,
    kind: IpProbeKind.values.byName(json['kind'] as String),
    host: json['host'] as String? ?? '',
  );
}

final class IpControl {
  const IpControl(
    this.name,
    this.provider,
    this.target, {
    this.region = 'anycast',
  });
  final String name, provider, region;
  final IpProbeTarget target;
}

final class IpProbeResult {
  const IpProbeResult(this.status, this.milliseconds);
  final IpProbeStatus status;
  final int milliseconds;
  bool get reachable => status == IpProbeStatus.reachable;
}

final class ProbeNetwork {
  const ProbeNetwork(
    this.identity,
    this.kind, {
    this.vpn = false,
    this.bound = false,
  });
  final String identity, kind;
  final bool vpn, bound;
}

abstract interface class IpProbeTransport {
  Future<ProbeNetwork> network();
  Future<IpProbeResult> probe(
    IpProbeTarget target,
    ProbeNetwork network,
    Duration timeout,
    CancellationToken cancellation,
  );
  Future<void> cancel();
}

final class IpProbeSample {
  const IpProbeSample(this.target, this.result, this.phase, this.at);
  final IpProbeTarget target;
  final IpProbeResult result;
  final String phase;
  final DateTime at;
  Map<String, Object?> toJson() => {
    ...target.toJson(),
    'status': result.status.name,
    'ms': result.milliseconds,
    'phase': phase,
    'at': at.toUtc().toIso8601String(),
  };
}

/// Facts are scoped to one device, route, address family and run.
final class IpDiagnosticRun {
  IpDiagnosticRun(this.startedAt, this.targets);
  final DateTime startedAt;
  final List<IpProbeTarget> targets;
  final samples = <IpProbeSample>[];
  IpDiagnosticStage stage = IpDiagnosticStage.baseline;
  ProbeNetwork? network;
  String? currentIp;
  int completed = 0,
      controlsReachable = 0,
      controlsTotal = 0,
      droppedSamples = 0;
  bool suspectedStrong = false, regionalLoss = false;
  DateTime? lossAt, recoveredAt;
  void add(IpProbeSample sample) {
    samples.add(sample);
    if (samples.length > 512) {
      final index = samples.indexWhere((s) => s.phase != 'target');
      samples.removeAt(index < 0 ? 0 : index);
      droppedSamples++;
    }
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'targets': targets.map((t) => t.toJson()).toList(),
    'samples': samples.map((s) => s.toJson()).toList(),
    'stage': stage.name,
    'network': network?.kind,
    'vpn': network?.vpn,
    'bound': network?.bound,
    'completed': completed,
    'total': targets.length,
    'controlsReachable': controlsReachable,
    'controlsTotal': controlsTotal,
    'suspectedStrong': suspectedStrong,
    'regionalLoss': regionalLoss,
    'lossAt': lossAt?.toUtc().toIso8601String(),
    'recoveredAt': recoveredAt?.toUtc().toIso8601String(),
    'droppedSamples': droppedSamples,
  };
}

/// Separate policy makes partial control failures explicit and testable.
class IpControlPolicy {
  const IpControlPolicy();
  bool enoughBaseline(List<IpControl> controls, Map<String, bool> baseline) =>
      controls.where((c) => baseline[c.target.key] == true).length >= 8 &&
      controls
              .where((c) => baseline[c.target.key] == true)
              .map((c) => c.provider)
              .toSet()
              .length >=
          4 &&
      baseline.values.where((v) => v).length * 10 >= controls.length * 7;

  bool regionalLoss(List<IpControl> controls, Map<String, bool> now) {
    final foreign = controls.where((c) => c.region == 'foreign').toList();
    return foreign.map((c) => c.provider).toSet().length >= 2 &&
        foreign.every((c) => now[c.target.key] != true) &&
        controls.any((c) => c.region == 'ru' && now[c.target.key] == true);
  }

  ControlHealth classify(List<IpControl> eligible, Map<String, bool> now) {
    if (eligible.isEmpty) return ControlHealth.degraded;
    final reachable = eligible.where((c) => now[c.target.key] == true).length;
    // 9/10 and 13/14 are normal. One missing endpoint never indicates strong blocking.
    if (reachable * 10 >= eligible.length * 9) return ControlHealth.healthy;
    final lostProviders = eligible
        .where((c) => now[c.target.key] != true)
        .map((c) => c.provider)
        .toSet();
    if (regionalLoss(eligible, now) ||
        reachable * 2 <= eligible.length && lostProviders.length >= 3) {
      return ControlHealth.strong;
    }
    return ControlHealth.degraded;
  }
}

class IpDiagnosticEngine {
  IpDiagnosticEngine({
    required this.transport,
    required this.controls,
    this.timeout = const Duration(seconds: 3),
    this.recoveryWindow = const Duration(minutes: 3),
    this.recoveryInterval = const Duration(seconds: 10),
    this.policy = const IpControlPolicy(),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final IpProbeTransport transport;
  final List<IpControl> controls;
  final Duration timeout, recoveryWindow, recoveryInterval;
  final IpControlPolicy policy;
  final DateTime Function() clock;

  Future<IpDiagnosticRun> run(
    List<IpProbeTarget> targets,
    CancellationToken token,
    void Function(IpDiagnosticRun) update,
  ) async {
    if (targets.isEmpty || targets.length > 64) {
      throw const FormatException('diagnostic_targets');
    }
    final result = IpDiagnosticRun(clock(), List.unmodifiable(targets));
    final eligibleByFamily = <IpFamily, List<IpControl>>{};
    Future<void> sameNetwork() async {
      token.check();
      ProbeNetwork now;
      try {
        now = await token.bind(transport.network());
      } on SshFailure {
        rethrow;
      } catch (_) {
        throw const FormatException('network_changed');
      }
      if (now.identity != result.network!.identity) {
        throw const FormatException('network_changed');
      }
    }

    Future<Map<String, bool>> measure(
      List<IpControl> list,
      String phase,
    ) async {
      final values = <String, bool>{};
      for (var offset = 0; offset < list.length; offset += 4) {
        await sameNetwork();
        await Future.wait(
          list.skip(offset).take(4).map((control) async {
            token.check();
            final probe = await transport.probe(
              control.target,
              result.network!,
              timeout,
              token,
            );
            token.check();
            values[control.target.key] = probe.reachable;
            result.add(IpProbeSample(control.target, probe, phase, clock()));
          }),
        );
        result.controlsReachable = values.values.where((v) => v).length;
        result.controlsTotal = list.length;
        update(result);
      }
      await sameNetwork();
      return values;
    }

    try {
      result.network = await token.bind(transport.network());
      for (final target in targets) {
        token.check();
        result.currentIp = target.address.canonical;
        var eligible = eligibleByFamily[target.address.family];
        if (eligible == null) {
          result.stage = IpDiagnosticStage.baseline;
          update(result);
          final candidates = controls
              .where(
                (c) =>
                    c.target.address.family == target.address.family &&
                    !targets.any((t) => t.address == c.target.address),
              )
              .toList();
          final first = await measure(candidates, 'baseline');
          final second = await measure(candidates, 'baseline');
          final stable = {
            for (final c in candidates)
              c.target.key:
                  first[c.target.key] == true && second[c.target.key] == true,
          };
          if (!policy.enoughBaseline(candidates, stable)) {
            result.stage = IpDiagnosticStage.insufficient;
            update(result);
            return result;
          }
          eligible = candidates
              .where((c) => stable[c.target.key] == true)
              .toList();
          eligibleByFamily[target.address.family] = eligible;
        }
        await sameNetwork();
        result.stage = IpDiagnosticStage.target;
        update(result);
        final probe = await transport.probe(
          target,
          result.network!,
          timeout,
          token,
        );
        token.check();
        result.add(IpProbeSample(target, probe, 'target', clock()));
        result.completed++;
        await sameNetwork();
        if (probe.reachable) {
          update(result);
          continue;
        }
        result.stage = IpDiagnosticStage.controls;
        update(result);
        var observed = await measure(eligible, 'controls');
        var health = policy.classify(eligible, observed);
        if (health == ControlHealth.healthy) continue;
        final firstHealth = health;
        observed = await measure(eligible, 'confirmation');
        health = policy.classify(eligible, observed);
        if (health == ControlHealth.healthy) continue;
        result.suspectedStrong =
            firstHealth == ControlHealth.strong &&
            health == ControlHealth.strong;
        result.regionalLoss =
            result.suspectedStrong && policy.regionalLoss(eligible, observed);
        result.lossAt = clock();
        result.stage = IpDiagnosticStage.recovery;
        update(result);
        final recoveryClock = Stopwatch()..start();
        var rounds = 0;
        while (recoveryClock.elapsed < recoveryWindow) {
          final delay = Duration(
            milliseconds: (recoveryInterval.inMilliseconds * (1 + rounds ~/ 3))
                .clamp(1, 30000),
          );
          final pause = Completer<void>();
          final timer = Timer(delay, pause.complete);
          try {
            await token.bind(pause.future);
          } finally {
            timer.cancel();
          }
          if (recoveryClock.elapsed >= recoveryWindow) break;
          observed = await measure(eligible, 'recovery');
          if (policy.classify(eligible, observed) == ControlHealth.healthy) {
            result.recoveredAt = clock();
            break;
          }
          rounds++;
        }
        // Never continue the target queue automatically after a connectivity collapse.
        result.stage = IpDiagnosticStage.degraded;
        update(result);
        return result;
      }
      result.stage = IpDiagnosticStage.complete;
    } on SshFailure catch (error) {
      result.stage = error.issue == SshIssue.cancelled
          ? IpDiagnosticStage.cancelled
          : IpDiagnosticStage.failed;
    } on FormatException catch (error) {
      result.stage = error.message == 'network_changed'
          ? IpDiagnosticStage.networkChanged
          : IpDiagnosticStage.failed;
    } catch (_) {
      result.stage = token.isCancelled
          ? IpDiagnosticStage.cancelled
          : IpDiagnosticStage.failed;
    } finally {
      try {
        await transport.cancel();
      } catch (_) {
        /* Preserve the measured result. */
      }
    }
    update(result);
    return result;
  }
}
