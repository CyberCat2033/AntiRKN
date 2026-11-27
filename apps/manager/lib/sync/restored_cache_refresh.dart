import 'dart:async';
import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../vpn/vpn_strings.dart';

/// Setting written by a cloud pull: servers whose observations this device
/// does not have (a new device, a replaced server, another workspace).
const restoredCacheSetting = 'syncCacheRefresh';

/// After a cloud pull the snapshot brings intent only. Servers listed in
/// [restoredCacheSetting] are read again once, in the background, through the
/// ordinary connection path and the read-only state request; profiles are
/// rebuilt by the existing compiler. A server that does not answer keeps its
/// dated cache and stays listed for the next launch. The interface is never
/// held: connections run outside VPN work, and the read is a background run.
class RestoredCacheRefresh extends ChangeNotifier {
  RestoredCacheRefresh({
    required this.settings,
    required this.connect,
    required this.refresh,
    required this.observedSince,
    required this.observedAt,
    required this.known,
    this.serverName,
    this.retryDelay = const Duration(seconds: 2),
  });
  final SettingsStore settings;
  final Future<bool> Function(String serverId) connect;

  /// Reads servers again; returns why a server was not read, by server.
  final Future<Map<String, String>> Function(List<String> serverIds) refresh;
  final bool Function(String serverId, DateTime since) observedSince;
  final DateTime? Function(String serverId) observedAt;
  final bool Function(String serverId) known;
  final String Function(String serverId)? serverName;
  final Duration retryDelay;

  /// Servers still to be read; [failed] were not read in this attempt.
  final pending = <String>{}, failed = <String>{};

  /// Why each of [failed] was not read: a VPN issue code.
  final issues = <String, String>{};
  bool running = false;
  bool _disposed = false;
  Future<void>? _current;

  /// The oldest saved read among [failed], shown as "data from".
  DateTime? get staleSince {
    DateTime? oldest;
    for (final id in failed) {
      final at = observedAt(id);
      if (at == null) return null;
      if (oldest == null || at.isBefore(oldest)) oldest = at;
    }
    return oldest;
  }

  Future<void> start() => _current ??= _run().whenComplete(() {
    _current = null;
  });

  Future<void> _run() async {
    final List<String> listed;
    try {
      final raw = await settings.readSetting(restoredCacheSetting);
      listed = raw == null || raw.isEmpty
          ? const []
          : List<String>.from(jsonDecode(raw) as List);
    } catch (_) {
      return;
    }
    if (listed.isEmpty || _disposed) return;
    pending
      ..clear()
      ..addAll(listed);
    failed.clear();
    issues.clear();
    running = true;
    _notify();
    final since = DateTime.now().toUtc();
    final queue = [...listed];
    Future<void> worker() async {
      while (queue.isNotEmpty && !_disposed) {
        final id = queue.removeAt(0);
        final issue = known(id) ? await _read(id, since) : null;
        if (issue == null) {
          pending.remove(id);
          await _save();
        } else {
          failed.add(id);
          issues[id] = issue;
        }
        _notify();
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    running = false;
    _notify();
  }

  /// Null once the server's saved state was actually read after [since];
  /// otherwise why it was not.
  Future<String?> _read(String id, DateTime since) async {
    var issue = 'vpn_connection';
    try {
      if (!await connect(id)) return issue;
      for (var attempt = 0; attempt < 3 && !_disposed; attempt++) {
        issue = (await refresh([id]))[id] ?? 'vpn_connection';
        if (observedSince(id, since)) return null;
        await Future<void>.delayed(retryDelay);
      }
    } catch (_) {}
    return issue;
  }

  Future<void> _save() async {
    try {
      final rest = pending.toList()..sort();
      await settings.writeSetting(restoredCacheSetting, jsonEncode(rest));
    } catch (_) {}
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

/// Says that server data is being read again, or how old the shown data is.
class RestoredCacheNotice extends StatelessWidget {
  const RestoredCacheNotice({required this.refresh, super.key});
  final RestoredCacheRefresh refresh;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: refresh,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      if (refresh.running) {
        return AppNotice(
          key: const ValueKey('restored-cache-running'),
          icon: Icons.sync,
          message: l.restoredCacheRunning,
        );
      }
      if (refresh.failed.isEmpty) return const SizedBox.shrink();
      final since = refresh.staleSince;
      final locale = Localizations.localeOf(context).toLanguageTag();
      final summary = since == null
          ? l.restoredCacheMissing(refresh.failed.length)
          : l.restoredCacheStale(
              refresh.failed.length,
              DateFormat.yMd(locale).add_Hm().format(since.toLocal()),
            );
      // Each server with its own reason: the person knows what to fix.
      final reasons = [
        for (final id in refresh.failed.toList()..sort())
          l.restoredCacheServerIssue(
            refresh.serverName?.call(id) ?? id,
            vpnMessage(l, refresh.issues[id] ?? 'vpn_connection'),
          ),
      ];
      return AppNotice(
        key: const ValueKey('restored-cache-stale'),
        icon: Icons.cloud_off_outlined,
        message: [summary, ...reasons].join('\n'),
        action: TextButton(onPressed: refresh.start, child: Text(l.vaultRetry)),
      );
    },
  );
}
