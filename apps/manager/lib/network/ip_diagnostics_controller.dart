import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';

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
  final addresses = TextEditingController(),
      port = TextEditingController(text: '443'),
      host = TextEditingController();
  IpProbeKind kind = IpProbeKind.tcp;
  IpDiagnosticRun? current;
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

  void seed(String value, {int? serverPort}) {
    if (busy) return;
    addresses.text = value;
    if (serverPort != null) {
      port.text = '$serverPort';
      kind = IpProbeKind.ssh;
    }
    issue = null;
    _notify();
  }

  List<IpProbeTarget> parse() {
    final number = int.tryParse(port.text.trim());
    if (number == null) throw const FormatException('diagnostic_target');
    final values = addresses.text.trim().split(RegExp(r'[\s,;]+')).toSet();
    if (values.isEmpty || values.length > 64) {
      throw const FormatException('diagnostic_targets');
    }
    return values.map((ip) {
      final target = IpProbeTarget(
        ip,
        number,
        kind: kind,
        host: host.text.trim(),
      );
      if (target.address.category != IpCategory.publicUnicast) {
        throw const FormatException('diagnostic_public_ip');
      }
      return target;
    }).toList();
  }

  void setKind(IpProbeKind value) {
    if (busy) return;
    kind = value;
    _notify();
  }

  Future<void> start(List<IpProbeTarget> targets) async {
    if (busy || disposed) return;
    busy = true;
    issue = null;
    current = null;
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
    } finally {
      if (entered) await leave?.call();
      busy = false;
      _token = null;
      _notify();
    }
  }

  void _save(IpDiagnosticRun value) {
    final snapshot = Map<String, dynamic>.from(value.toJson());
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
    addresses.dispose();
    port.dispose();
    host.dispose();
    super.dispose();
  }
}
