import 'dart:async';
import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

/// The target a search proposes for the REALITY form: the verified name as
/// Target (owner's choice, 2026-11-28; the server resolves it itself) and SNI.
typedef RealityTargetChoice = ({String target, String sni});

/// What a connection check of this session ended with, as shown in place.
enum RealityConnectOutcome { works, fails, unknown, cancelled, cleanupPending }

/// One finished connection check, for a notice when its details are closed.
typedef RealityConnectFinished = ({
  String key,
  String sni,
  RealityConnectOutcome outcome,
  int serial,
});

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
    this.checkConnection,
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

  /// Traffic from this device through a temporary inbound with the chosen
  /// Target and SNI (FR-SNI, level 4); null without a server connection.
  final Future<ConnectionCheck> Function(
    RealityTargetChoice choice,
    CancellationToken cancellation,
    void Function(int stage) onStage,
  )?
  checkConnection;
  final DateTime Function() clock;

  /// Pairs whose connection check runs now, with its stage (0 create,
  /// 1 traffic, 2 remove).
  final connecting = <String, int>{};

  /// Pairs whose running check was asked to stop.
  final cancelling = <String>{};

  /// Results of this session, including a cancel; saved ones are in state.
  final outcomes = <String, RealityConnectOutcome>{};

  /// The last finished check; its serial grows with every check.
  RealityConnectFinished? finished;
  final _connectTokens = <String, CancellationToken>{};
  var _serial = 0;

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

  /// Runs only on request: it adds and removes an inbound on the server.
  /// Closing its details does not stop it; [cancelConnection] does.
  Future<void> checkWithMihomo(RealityCandidate candidate) async {
    final check = checkConnection, s = state, key = candidate.target.key;
    if (check == null ||
        s == null ||
        running ||
        connecting.isNotEmpty ||
        checking.contains(key)) {
      return;
    }
    final token = _connectTokens[key] = CancellationToken();
    connecting[key] = 0;
    outcomes.remove(key);
    _notify();
    ConnectionCheck? result;
    DateTime? trafficStarted, trafficEnded;
    try {
      result = await check(realityChoice(candidate), token, (stage) {
        if (stage == 1) trafficStarted = clock();
        if (stage == 2) trafficEnded = clock();
        if (connecting.containsKey(key)) {
          connecting[key] = stage;
          _notify();
        }
      });
    } catch (_) {
      result = null;
    }
    connecting.remove(key);
    cancelling.remove(key);
    _connectTokens.remove(key);
    if (_disposed || state != s) return;
    final outcome = switch (result) {
      null => RealityConnectOutcome.unknown,
      _ when result.code == 'cleanup_pending' =>
        RealityConnectOutcome.cleanupPending,
      _
          when token.isCancelled ||
              result.status == ConnectionCheckStatus.cancelled =>
        RealityConnectOutcome.cancelled,
      _ when result.status == ConnectionCheckStatus.working =>
        RealityConnectOutcome.works,
      _ when result.status == ConnectionCheckStatus.failed =>
        RealityConnectOutcome.fails,
      _ => RealityConnectOutcome.unknown,
    };
    outcomes[key] = outcome;
    if (result != null &&
        outcome != RealityConnectOutcome.cancelled &&
        outcome != RealityConnectOutcome.cleanupPending) {
      final started = trafficStarted, ended = trafficEnded;
      s.mihomoChecks[key] = RealityMihomoCheck(
        status: switch (outcome) {
          RealityConnectOutcome.works => RealityMihomoStatus.working,
          RealityConnectOutcome.fails => RealityMihomoStatus.failed,
          _ => RealityMihomoStatus.inconclusive,
        },
        code: RegExp(r'^[a-z_]{1,40}$').hasMatch(result.code)
            ? result.code
            : 'failed',
        at: clock(),
        networkIdentity: result.networkIdentity,
        duration: started != null && ended != null
            ? ended.difference(started)
            : null,
      );
      _save(s);
    }
    finished = (
      key: key,
      sni: candidate.target.sni,
      outcome: outcome,
      serial: ++_serial,
    );
    _notify();
  }

  /// Stops the traffic; the temporary inbound is still removed.
  void cancelConnection(String key) {
    final token = _connectTokens[key];
    if (token == null || cancelling.contains(key)) return;
    cancelling.add(key);
    token.cancel();
    _notify();
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
          'connection': c.fromMihomo?.status.name,
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
    for (final token in _connectTokens.values) {
      token.cancel();
    }
    super.dispose();
  }
}
