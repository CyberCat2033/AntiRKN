import 'dart:async';
import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

/// The target a search proposes for the REALITY form: the verified name as
/// Target (owner's choice, 2026-11-28; the server resolves it itself) and SNI.
typedef RealityTargetChoice = ({String target, String sni});

RealityTargetChoice realityChoice(RealityCandidate c) =>
    (target: '${c.target.sni}:${c.target.port}', sni: c.target.sni);

/// The address the device verified, shown for reference only.
String realityVerifiedAddress(RealityCandidate c) =>
    c.target.ip.family == IpFamily.ipv6
    ? '[${c.target.ip.canonical}]:${c.target.port}'
    : '${c.target.ip.canonical}:${c.target.port}';

/// Typical length of a search: most closed addresses answer at once, about
/// four in ten wait for the connect timeout.
Duration realitySearchEstimate(int addresses, TlsScanLimits limits) {
  final perAddress =
      limits.connect.inMilliseconds * .4 + 300 * .6; // ms, observed mix
  final ms =
      addresses * perAddress / limits.concurrency +
      48 * 300 / limits.concurrency +
      2000;
  return Duration(milliseconds: ms.round());
}

/// One search per server, alive while its VLESS panel is. Its checkpoint and
/// result stay on this device (settings store), never in sync.
class RealitySearchController extends ChangeNotifier {
  RealitySearchController({
    required this.serverId,
    required this.search,
    this.store,
    this.checkFromServer,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now {
    ready = _load();
  }
  final String serverId;
  final RealityTargetSearch search;
  final SettingsStore? store;

  /// The 3x-ui check of one target and SNI made by the server; null when the
  /// panel is not reachable now.
  final Future<Map<String, dynamic>?> Function(String target, String sni)?
  checkFromServer;
  final DateTime Function() clock;

  /// Pairs whose server check runs now.
  final checking = <String>{};

  /// The last server check could not run: no connection or panel sign-in.
  bool serverUnavailable = false;
  late final Future<void> ready;

  RealitySearchState? state;
  bool running = false;

  /// The device network differs from the one the saved results come from.
  bool otherNetwork = false;
  bool storeFailed = false;
  CancellationToken? _token;
  Future<void> _writes = Future.value();
  bool _disposed = false;

  String get _key => 'realitySearch.$serverId';
  List<RealityCandidate> get candidates =>
      state?.candidates(clock()) ?? const [];
  List<RealityCandidate> get recommended => [
    for (final c in candidates)
      if (c.suitable) c,
  ];

  /// Best finished candidate, offered to the next inbound of this server.
  RealityCandidate? get best =>
      state?.phase == RealitySearchPhase.done && recommended.isNotEmpty
      ? recommended.first
      : null;

  /// A stopped search that can continue on the same network.
  bool get resumable =>
      !running &&
      !otherNetwork &&
      state != null &&
      const {
        RealitySearchPhase.cancelled,
        RealitySearchPhase.failed,
        RealitySearchPhase.networkChanged,
      }.contains(state!.phase);

  Future<void> _load() async {
    try {
      final raw = await store?.readSetting(_key);
      if (raw == null) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final checkpoint = json['checkpoint'] as Map<String, dynamic>;
      final saved = checkpoint['plan'] as Map<String, dynamic>;
      final plan = RealitySearchPlan.explicit(
        (saved['addresses'] as List).cast<String>(),
        server: saved['server'] as String,
        port: saved['port'] as int,
        limit: RealitySearchPlan.hardLimit,
      );
      final restored = RealitySearchState.fromJson(checkpoint, plan);
      restored
        ..phase = RealitySearchPhase.values.byName(json['phase'] as String)
        ..code = json['code'] as String;
      // A search interrupted by closing the app is a stopped search.
      if (!restored.finished) restored.phase = RealitySearchPhase.cancelled;
      state ??= restored;
      _notify();
    } catch (_) {
      // A damaged or older entry is ignored; a new search replaces it.
    }
  }

  /// Marks saved results that were observed on another device network.
  Future<void> checkNetwork() async {
    final saved = state;
    if (saved == null || running) return;
    try {
      final now = await search.network();
      otherNetwork = now.identity != saved.networkIdentity;
    } catch (_) {
      otherNetwork = false;
    }
    _notify();
  }

  Future<void> start(RealitySearchPlan plan) => _run(plan, null);

  Future<void> resume() async {
    final saved = state;
    if (!resumable || saved == null) return;
    await _run(saved.plan, saved.toJson());
  }

  Future<void> _run(
    RealitySearchPlan plan,
    Map<String, dynamic>? checkpoint,
  ) async {
    if (running) return;
    running = true;
    otherNetwork = false;
    final token = _token = CancellationToken();
    _notify();
    try {
      final result = await search.run(plan, token, (s) {
        state = s;
        _save(s);
        _notify();
      }, checkpoint: checkpoint);
      state = result;
      _save(result);
    } catch (_) {
      // A checkpoint that no longer matches starts nothing; offer a new run.
      state = RealitySearchState(plan, '', clock())
        ..phase = RealitySearchPhase.failed
        ..code = 'search_checkpoint';
    } finally {
      running = false;
      _token = null;
      _notify();
    }
    if (state?.phase == RealitySearchPhase.done) await checkFinalists();
  }

  /// The best suitable pairs not yet checked by the server, one at a time.
  Future<void> checkFinalists({int top = 3}) async {
    for (final c in recommended.take(top).toList()) {
      if (_disposed || running || serverUnavailable) return;
      if (state?.serverChecks[c.target.key] == null) await checkOnServer(c);
    }
  }

  Future<void> checkOnServer(RealityCandidate candidate) async {
    final check = checkFromServer, s = state, key = candidate.target.key;
    if (check == null || s == null || running || checking.contains(key)) {
      return;
    }
    checking.add(key);
    _notify();
    Map<String, dynamic>? answer;
    try {
      final choice = realityChoice(candidate);
      answer = await check(choice.target, choice.sni);
    } catch (_) {
      answer = null;
    }
    checking.remove(key);
    if (_disposed || state != s) return;
    serverUnavailable = answer == null;
    if (answer != null) {
      final ms = answer['latencyMs'];
      s.serverChecks[key] = RealityServerCheck(
        feasible: answer['feasible'] == true,
        at: clock(),
        latency: ms is int && ms >= 0 && ms <= 60000
            ? Duration(milliseconds: ms)
            : null,
      );
      _save(s);
    }
    _notify();
  }

  void stop() => _token?.cancel();

  void _save(RealitySearchState s) {
    final encoded = jsonEncode({
      'version': 1,
      'phase': s.phase.name,
      'code': s.code,
      'checkpoint': s.toJson(),
    });
    _writes = _writes.then((_) async {
      try {
        await store?.writeSetting(_key, encoded);
      } catch (_) {
        storeFailed = true;
        _notify();
      }
    });
  }

  /// Observations without secrets: one row per probed IP + SNI pair.
  String exportJson() => const JsonEncoder.withIndent('  ').convert({
    'startedAt': state?.startedAt.toUtc().toIso8601String(),
    'network': state?.network?.kind,
    'deviceVpn': state?.network?.vpn,
    'bypassedVpn': state?.network?.direct,
    'addresses': state?.plan.addresses.length,
    'server': state?.plan.server?.canonical,
    'candidates': [
      for (final c in candidates)
        {
          ...tlsProbeJson(c.confirmation),
          'level': c.level.name,
          'score': c.score,
          'serverFeasible': c.fromServer?.feasible,
          'serverMs': c.fromServer?.latency?.inMilliseconds,
          'reasons': [for (final r in c.reasons) r.name],
        },
    ],
  });

  String exportCsv() {
    String cell(Object? v) {
      final text = '${v ?? ''}';
      // Certificate fields are untrusted: quote, and keep spreadsheets from
      // reading them as formulas.
      final safe = RegExp(r'^[=+\-@]').hasMatch(text) ? "'$text" : text;
      return '"${safe.replaceAll('"', '""')}"';
    }

    final rows = [
      [
        'ip',
        'port',
        'sni',
        'level',
        'score',
        'tls',
        'alpn',
        'group',
        'dns',
        'tls_ms',
        'server_ms',
        'issuer',
        'not_after',
        'reasons',
      ],
      for (final c in candidates)
        [
          c.target.ip.canonical,
          c.target.port,
          c.target.sni,
          c.level.name,
          c.score,
          c.confirmation.version,
          c.confirmation.alpn,
          c.confirmation.group,
          c.confirmation.dns.name,
          c.confirmation.tls.inMilliseconds,
          c.fromServer?.latency?.inMilliseconds,
          c.confirmation.certificate?.issuer,
          c.confirmation.certificate?.notAfter.toUtc().toIso8601String(),
          c.reasons.map((r) => r.name).join(' '),
        ],
    ];
    return '${rows.map((r) => r.map(cell).join(',')).join('\r\n')}\r\n';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _token?.cancel();
    super.dispose();
  }
}
