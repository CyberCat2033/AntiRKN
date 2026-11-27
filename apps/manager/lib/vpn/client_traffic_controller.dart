import 'dart:async';
import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

/// Reads one server's counted traffic; [connect] may open its connection.
typedef ServerTrafficReader =
    Future<ServerTrafficReading> Function(
      String serverId,
      CancellationToken token, {
      bool connect,
    });

/// Per-client traffic from the servers' runners, cached on this device only
/// (never synchronised: every device reads the servers itself).
class ClientTrafficController extends ChangeNotifier {
  ClientTrafficController({
    required this.servers,
    required this.read,
    this.store,
    this.timeout = const Duration(seconds: 45),
  });

  static const settingKey = 'clientTraffic';

  /// Physical servers holding client resources.
  final Set<String> Function() servers;
  final ServerTrafficReader read;
  final SettingsStore? store;
  final Duration timeout;

  Map<String, ServerTrafficReading> readings = {};

  /// Why a server's latest read failed (`traffic_not_connected`,
  /// `traffic_runner_outdated`, `traffic_failed`); cleared by a good read.
  final Map<String, String> issues = {};
  final Set<String> refreshing = {};
  bool _loaded = false, _disposed = false;
  Future<void>? _loading;

  bool get busy => refreshing.isNotEmpty;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final source = await store?.readSetting(settingKey);
      if (source != null && source.isNotEmpty) {
        final json = jsonDecode(source) as Map;
        if (json['version'] == 1) {
          readings = {
            for (final e in (json['servers'] as Map).entries)
              e.key as String: ServerTrafficReading.fromRunner(
                Map<String, dynamic>.from(e.value as Map),
              ),
          };
        }
      }
    } catch (_) {
      readings = {}; // A damaged cache is only a cache: read the servers again.
    }
    _loaded = true;
    _notify();
  }

  ClientTrafficSummary summary(String userId) {
    final live = servers();
    return ClientTrafficSummary.of(userId, {
      for (final e in readings.entries)
        if (live.contains(e.key)) e.key: e.value,
    });
  }

  /// Reads every server again, in parallel. [connect]: open connections
  /// that are not open yet (a person's explicit refresh).
  Future<void> refresh({bool connect = false}) async {
    await load();
    final ids = servers().difference(refreshing);
    if (ids.isEmpty || _disposed) return;
    refreshing.addAll(ids);
    _notify();
    await Future.wait(ids.map((id) => _readOne(id, connect)));
    await _save();
  }

  Future<void> _readOne(String id, bool connect) async {
    final token = CancellationToken();
    final timer = Timer(timeout, token.cancel);
    try {
      readings[id] = await read(id, token, connect: connect);
      issues.remove(id);
    } on FormatException catch (e) {
      issues[id] = e.message.startsWith('traffic_')
          ? e.message
          : 'traffic_failed';
    } catch (_) {
      issues[id] = 'traffic_failed';
    } finally {
      timer.cancel();
      refreshing.remove(id);
      _notify();
    }
  }

  Future<void> _save() async {
    if (!_loaded || _disposed || store == null) return;
    final live = servers();
    readings.removeWhere((id, _) => !live.contains(id));
    try {
      await store!.writeSetting(
        settingKey,
        jsonEncode({
          'version': 1,
          'servers': {
            for (final e in readings.entries) e.key: e.value.toJson(),
          },
        }),
      );
    } catch (_) {
      // The figures stay on screen; the next read saves them again.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
