import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

/// A diagnostic always uses the saved connection and the server's own IPv4s.
class ServerIpDiagnostics {
  ServerIpDiagnostics(SshProfile profile, Iterable<IpAddress> addresses)
    : key = jsonEncode([
        profile.id,
        profile.host,
        profile.port,
        profile.hostKey?.fingerprint,
      ]),
      sshPort = profile.port,
      addresses = List.unmodifiable({
        for (final ip in addresses)
          if (ip.family == IpFamily.ipv4 &&
              ip.category == IpCategory.publicUnicast)
            ip.canonical,
      });

  final String key;
  final int sshPort;
  final List<String> addresses;

  List<IpProbeTarget> targets(IpProbeKind kind) {
    if (addresses.isEmpty ||
        addresses.length > 64 ||
        ![IpProbeKind.tcp, IpProbeKind.ssh].contains(kind)) {
      throw const FormatException('diagnostic_targets');
    }
    return [
      for (final ip in addresses)
        IpProbeTarget(ip, kind == IpProbeKind.ssh ? sshPort : 443, kind: kind),
    ];
  }
}

class IpAddressDiagnostic {
  const IpAddressDiagnostic({
    required this.target,
    required this.stage,
    required this.running,
    required this.current,
    required this.strong,
    required this.connectionLost,
    required this.recovered,
    this.status,
  });
  final IpProbeTarget target;
  final IpProbeStatus? status;
  final IpDiagnosticStage stage;
  final bool running, current, strong, connectionLost, recovered;
}

class IpDiagnosticsController extends ChangeNotifier {
  IpDiagnosticsController({
    required this.engine,
    this.store,
    this.enter,
    this.leave,
  }) {
    ready = _load();
  }
  final IpDiagnosticEngine engine;
  final SettingsStore? store;
  final Future<bool> Function()? enter;
  final Future<void> Function()? leave;
  IpDiagnosticRun? current;
  String? serverKey;
  List<Map<String, dynamic>> history = [];
  bool busy = false, disposed = false, historyError = false;
  String? issue;
  CancellationToken? _token;
  Future<void> _writes = Future.value();
  late final Future<void> ready;
  void _notify() {
    if (!disposed) notifyListeners();
  }

  Future<void> _load() async {
    try {
      final source = await store?.readSetting('ipDiagnosticHistory');
      if (source != null && source.length <= 3000000) {
        history = (jsonDecode(source) as List)
            .take(5)
            .map((v) => Map<String, dynamic>.from(v as Map))
            .where((v) => v['version'] == 1)
            .toList();
      }
    } catch (_) {
      historyError = true;
    }
    _notify();
  }

  IpAddressDiagnostic? resultFor(ServerIpDiagnostics server, String ip) {
    if (!server.addresses.contains(ip)) return null;
    final live = current != null && serverKey == server.key;
    final snapshot = live
        ? {...current!.toJson(), 'currentIp': current!.currentIp}
        : history.where((h) => h['serverKey'] == server.key).firstOrNull;
    if (snapshot == null) return null;
    try {
      final targetJson = (snapshot['targets'] as List)
          .whereType<Map>()
          .where((t) => t['ip'] == ip)
          .firstOrNull;
      if (targetJson == null) return null;
      final sample = (snapshot['samples'] as List)
          .whereType<Map>()
          .where((s) => s['phase'] == 'target' && s['ip'] == ip)
          .firstOrNull;
      final stage = IpDiagnosticStage.values.byName(
        snapshot['stage'] as String,
      );
      final running = live && busy;
      final activeStage = [
        IpDiagnosticStage.baseline,
        IpDiagnosticStage.target,
        IpDiagnosticStage.controls,
        IpDiagnosticStage.recovery,
      ].contains(stage);
      return IpAddressDiagnostic(
        target: IpProbeTarget.fromJson(Map<String, dynamic>.from(targetJson)),
        stage: !running && activeStage ? IpDiagnosticStage.cancelled : stage,
        running: running,
        current: snapshot['currentIp'] == ip,
        strong:
            snapshot['currentIp'] == ip && snapshot['suspectedStrong'] == true,
        connectionLost:
            snapshot['currentIp'] == ip && snapshot['lossAt'] != null,
        recovered: snapshot['recoveredAt'] != null,
        status: sample == null
            ? null
            : IpProbeStatus.values.byName(sample['status'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> start(ServerIpDiagnostics server, IpProbeKind kind) async {
    if (busy || disposed) return;
    final targets = server.targets(kind);
    busy = true;
    issue = null;
    serverKey = server.key;
    current = IpDiagnosticRun(DateTime.now(), targets);
    _notify();
    var entered = false;
    _token = CancellationToken();
    var previousCheckpoint = '';
    try {
      await ready;
      if (disposed || _token!.isCancelled) return;
      entered = enter == null || await enter!();
      if (!entered) {
        issue = 'busy';
        current = null;
        return;
      }
      if (disposed || _token!.isCancelled) return;
      current = await engine.run(targets, _token!, (value) {
        current = value;
        final checkpoint = '${value.stage.name}:${value.completed}';
        if (checkpoint != previousCheckpoint) {
          previousCheckpoint = checkpoint;
          _save(value);
        }
        _notify();
      });
      _save(current!);
      await _writes;
    } catch (_) {
      issue = 'failed';
      current?.stage = IpDiagnosticStage.failed;
    } finally {
      if (entered) await leave?.call();
      busy = false;
      _token = null;
      _notify();
    }
  }

  void _save(IpDiagnosticRun value) {
    final snapshot = <String, dynamic>{
      ...value.toJson(),
      'serverKey': serverKey,
      'currentIp': value.currentIp,
    };
    history = [
      snapshot,
      ...history.where((h) => h['startedAt'] != snapshot['startedAt']),
    ].take(5).toList();
    final encoded = jsonEncode(history);
    _writes = _writes.then((_) async {
      try {
        await store?.writeSetting('ipDiagnosticHistory', encoded);
      } catch (_) {
        historyError = true;
        _notify();
      }
    });
  }

  void stop() {
    _token?.cancel();
    unawaited(engine.transport.cancel().catchError((Object _) {}));
  }

  Future<void> clearHistory() async {
    if (busy) return;
    await _writes;
    try {
      await store?.writeSetting('ipDiagnosticHistory', '[]');
      history = [];
      historyError = false;
    } catch (_) {
      historyError = true;
    }
    _notify();
  }

  @override
  void dispose() {
    disposed = true;
    stop();
    super.dispose();
  }
}
