import 'dart:async';

import '../ssh.dart';
import 'ip_address.dart';
import 'ip_diagnostics.dart';
import 'tls_scan.dart';
import 'tls_scan_json.dart';

/// FR-SNI-02 search for a REALITY target: TLS discovery of a finite address
/// set without SNI, confirmation of IP + SNI pairs from certificate names, and
/// one repeat of the best pairs. All probes run on this device.

/// A finite address set of one search; it never grows by itself.
final class RealitySearchPlan {
  RealitySearchPlan._(List<IpAddress> addresses, this.port, this.server)
    : addresses = List.unmodifiable(addresses);

  static const defaultLimit = 256, hardLimit = 1024;

  /// Neighbours of [server] in its IPv4 /[prefix] without the server, network
  /// and broadcast addresses. IPv6 prefixes are never expanded.
  factory RealitySearchPlan.neighbors(
    String server, {
    int prefix = 24,
    int port = 443,
    int limit = defaultLimit,
  }) {
    final ip = IpAddress.tryParse(server);
    if (ip == null ||
        ip.family != IpFamily.ipv4 ||
        prefix < 22 ||
        prefix > 30 ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('search_plan');
    }
    final value = ip.bytes.fold<int>(0, (v, b) => v << 8 | b);
    final size = 1 << (32 - prefix);
    final base = value & ~(size - 1) & 0xffffffff;
    final addresses = <IpAddress>[];
    for (var i = 1; i < size - 1; i++) {
      final n = base + i;
      final a = IpAddress.parse(
        '${n >> 24 & 255}.${n >> 16 & 255}.${n >> 8 & 255}.${n & 255}',
      );
      if (a != ip && a.category == IpCategory.publicUnicast) addresses.add(a);
    }
    if (addresses.isEmpty || addresses.length > limit.clamp(1, hardLimit)) {
      throw const FormatException('search_plan');
    }
    return RealitySearchPlan._(addresses, port, ip);
  }

  /// Exactly the given public addresses; duplicates are dropped.
  factory RealitySearchPlan.explicit(
    Iterable<String> addresses, {
    String server = '',
    int port = 443,
    int limit = defaultLimit,
  }) {
    final parsed = <IpAddress>{};
    for (final text in addresses) {
      final ip = IpAddress.tryParse(text.trim());
      if (ip == null || ip.category != IpCategory.publicUnicast) {
        throw const FormatException('search_plan');
      }
      parsed.add(ip);
    }
    final origin = server.isEmpty ? null : IpAddress.tryParse(server);
    if (parsed.isEmpty ||
        parsed.length > limit.clamp(1, hardLimit) ||
        server.isNotEmpty && origin == null ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('search_plan');
    }
    return RealitySearchPlan._(parsed.toList(), port, origin);
  }

  final List<IpAddress> addresses;
  final int port;

  /// The managed server the target is chosen for; null when unknown.
  final IpAddress? server;

  Map<String, Object?> toJson() => {
    'addresses': [for (final a in addresses) a.canonical],
    'port': port,
    'server': server?.canonical ?? '',
  };

  @override
  bool operator ==(Object other) =>
      other is RealitySearchPlan &&
      other.port == port &&
      other.server == server &&
      other.addresses.length == addresses.length &&
      Iterable<int>.generate(
        addresses.length,
      ).every((i) => other.addresses[i] == addresses[i]);
  @override
  int get hashCode => Object.hash(port, server, Object.hashAll(addresses));
}

enum RealityProximity { sameNetwork, nearby, far, unknown }

/// discovered: TLS seen; confirmed: the IP + SNI certificate verified;
/// criteria: every REALITY gate passed; serverChecked: the managed server
/// also accepted the pair (3x-ui check); mihomoChecked: traffic from this
/// device passed through a temporary inbound with this target and SNI.
enum RealityLevel {
  discovered,
  confirmed,
  criteria,
  serverChecked,
  mihomoChecked,
}

/// working: 100 KB went through; failed: the network was healthy and the
/// proxy did not work; inconclusive: the network, a device VPN or the
/// temporary inbound kept the check from saying either.
enum RealityMihomoStatus { working, failed, inconclusive }

/// One Mihomo check of a pair from this device through the managed server.
final class RealityMihomoCheck {
  const RealityMihomoCheck({
    required this.status,
    required this.code,
    required this.at,
    this.networkIdentity = '',
  });
  final RealityMihomoStatus status;
  final String code, networkIdentity;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'code': code,
    'network': networkIdentity,
    'at': at.toUtc().toIso8601String(),
  };

  factory RealityMihomoCheck.fromJson(Object? json) {
    final at = json is Map ? DateTime.tryParse('${json['at']}') : null;
    final status = json is Map
        ? RealityMihomoStatus.values.asNameMap()[json['status']]
        : null;
    if (json is! Map ||
        status == null ||
        at == null ||
        json['code'] is! String ||
        !RegExp(r'^[a-z_]{1,40}$').hasMatch(json['code'] as String) ||
        json['network'] is! String) {
      throw const FormatException('search_checkpoint');
    }
    return RealityMihomoCheck(
      status: status,
      code: json['code'] as String,
      at: at,
      networkIdentity: json['network'] as String,
    );
  }
}

/// One check of an IP + SNI pair made by the managed server itself. It is
/// not a scan: only chosen finalists are checked, one request each.
final class RealityServerCheck {
  const RealityServerCheck({
    required this.feasible,
    required this.at,
    this.latency,
  });
  final bool feasible;

  /// Server → target time; null when the server did not report it.
  final Duration? latency;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'feasible': feasible,
    'latencyMs': latency?.inMilliseconds,
    'at': at.toUtc().toIso8601String(),
  };

  factory RealityServerCheck.fromJson(Object? json) {
    final at = json is Map ? DateTime.tryParse('${json['at']}') : null;
    final ms = json is Map ? json['latencyMs'] : null;
    if (json is! Map ||
        json['feasible'] is! bool ||
        at == null ||
        ms != null && (ms is! int || ms < 0 || ms > 60000)) {
      throw const FormatException('search_checkpoint');
    }
    return RealityServerCheck(
      feasible: json['feasible'] as bool,
      at: at,
      latency: ms == null ? null : Duration(milliseconds: ms as int),
    );
  }
}

enum RealityReason {
  sameNetwork,
  nearbyNetwork,
  farNetwork,
  dnsMatch,
  dnsMismatch,
  dnsUnresolved,
  modernKeyExchange,
  stable,
  unstable,
  stabilityNotChecked,
  serverNotChecked,
  serverChecked,
  serverRejected,
  mihomoWorking,
  mihomoFailed,
  mihomoInconclusive,
  redirectNotChecked,
  notTls13,
  noH2,
  unsupportedGroup,
  certificateInvalid,
  handshakeFailed,
  knownCdn,
  expiresSoon,
}

/// Published ranges of large CDNs (Cloudflare, Fastly): short and incomplete.
const _cdn = [
  ('173.245.48.0', 20),
  ('103.21.244.0', 22),
  ('103.22.200.0', 22),
  ('103.31.4.0', 22),
  ('141.101.64.0', 18),
  ('108.162.192.0', 18),
  ('190.93.240.0', 20),
  ('188.114.96.0', 20),
  ('197.234.240.0', 22),
  ('198.41.128.0', 17),
  ('162.158.0.0', 15),
  ('104.16.0.0', 13),
  ('104.24.0.0', 14),
  ('172.64.0.0', 13),
  ('131.0.72.0', 22),
  ('2400:cb00::', 32),
  ('2606:4700::', 32),
  ('2803:f800::', 32),
  ('2405:b500::', 32),
  ('2405:8100::', 32),
  ('2a06:98c0::', 29),
  ('2c0f:f248::', 32),
  ('151.101.0.0', 16),
  ('146.75.0.0', 17),
  ('199.232.0.0', 16),
  ('2a04:4e40::', 32),
  ('2a04:4e42::', 32),
];

bool isKnownCdn(IpAddress ip) => _cdn.any((p) => ip.inSubnet(p.$1, p.$2));

RealityProximity realityProximity(IpAddress ip, IpAddress? server) {
  if (server == null || server.family != ip.family) {
    return RealityProximity.unknown;
  }
  final v4 = ip.family == IpFamily.ipv4;
  if (ip.inSubnet(server.canonical, v4 ? 24 : 48)) {
    return RealityProximity.sameNetwork;
  }
  if (ip.inSubnet(server.canonical, v4 ? 16 : 32)) {
    return RealityProximity.nearby;
  }
  return RealityProximity.far;
}

const _groups = {'X25519', 'X25519MLKEM768'};

bool _sameObservation(TlsProbeResult a, TlsProbeResult b) =>
    a.handshake == b.handshake &&
    a.version == b.version &&
    a.alpn == b.alpn &&
    a.group == b.group &&
    a.certificate?.check == b.certificate?.check &&
    a.certificate?.names.join(',') == b.certificate?.names.join(',');

/// One IP + SNI pair with its gates, reasons and a 0..100 score. Weights are
/// starting values; an unmeasured factor gives half of its weight.
final class RealityCandidate {
  RealityCandidate._(
    this.confirmation,
    this.repeat,
    this.level,
    this.score,
    List<RealityReason> reasons,
    this.proximity,
    this.fromServer,
    this.fromMihomo,
  ) : reasons = List.unmodifiable(reasons);

  factory RealityCandidate.rate(
    TlsProbeResult confirmation, {
    TlsProbeResult? repeat,
    RealityServerCheck? fromServer,
    RealityMihomoCheck? fromMihomo,
    IpAddress? server,
    required DateTime now,
  }) {
    final p = confirmation;
    final reasons = <RealityReason>[];
    final proximity = realityProximity(p.target.ip, server);
    final cdn = isKnownCdn(p.target.ip);
    final valid = p.certificate?.check == TlsCertificateCheck.valid;
    if (p.handshake != TlsHandshake.ok) {
      reasons.add(RealityReason.handshakeFailed);
    }
    if (p.handshake == TlsHandshake.ok && p.version != '1.3') {
      reasons.add(RealityReason.notTls13);
    }
    if (p.handshake == TlsHandshake.ok && p.alpn != 'h2') {
      reasons.add(RealityReason.noH2);
    }
    if (p.handshake == TlsHandshake.ok && !_groups.contains(p.group)) {
      reasons.add(RealityReason.unsupportedGroup);
    }
    if (p.handshake == TlsHandshake.ok && !valid) {
      reasons.add(RealityReason.certificateInvalid);
    }
    if (cdn) reasons.add(RealityReason.knownCdn);
    if (fromServer?.feasible == false) {
      reasons.add(RealityReason.serverRejected);
    }
    if (fromMihomo?.status == RealityMihomoStatus.failed) {
      reasons.add(RealityReason.mihomoFailed);
    }
    final gated = reasons.isNotEmpty;
    final level = !valid
        ? RealityLevel.discovered
        : gated
        ? RealityLevel.confirmed
        : fromMihomo?.status == RealityMihomoStatus.working
        ? RealityLevel.mihomoChecked
        : fromServer == null
        ? RealityLevel.criteria
        : RealityLevel.serverChecked;
    switch (fromMihomo?.status) {
      case RealityMihomoStatus.working:
        reasons.add(RealityReason.mihomoWorking);
      case RealityMihomoStatus.inconclusive:
        reasons.add(RealityReason.mihomoInconclusive);
      case RealityMihomoStatus.failed || null:
        break;
    }

    var score = 0;
    switch (proximity) {
      case RealityProximity.sameNetwork:
        score += 30;
        reasons.add(RealityReason.sameNetwork);
      case RealityProximity.nearby:
        score += 15;
        reasons.add(RealityReason.nearbyNetwork);
      case RealityProximity.far:
        reasons.add(RealityReason.farNetwork);
      case RealityProximity.unknown:
        score += 15;
    }
    switch (p.dns) {
      case TlsDnsCheck.match:
        score += 20;
        reasons.add(RealityReason.dnsMatch);
      case TlsDnsCheck.mismatch:
        reasons.add(RealityReason.dnsMismatch);
      case TlsDnsCheck.unresolved || TlsDnsCheck.notChecked:
        score += 10;
        reasons.add(RealityReason.dnsUnresolved);
    }
    final latency = fromServer?.latency;
    if (fromServer == null) {
      score += 7;
      reasons.add(RealityReason.serverNotChecked);
    } else if (fromServer.feasible) {
      reasons.add(RealityReason.serverChecked);
      // Every handshake through REALITY waits for server → target.
      score += latency == null
          ? 7
          : (15 * (1 - (latency.inMilliseconds - 20) / 300).clamp(0, 1))
                .round();
    }
    if (repeat == null) {
      score += 7;
      reasons.add(RealityReason.stabilityNotChecked);
    } else if (_sameObservation(p, repeat)) {
      score += 15;
      reasons.add(RealityReason.stable);
    } else {
      reasons.add(RealityReason.unstable);
    }
    if (p.group == 'X25519MLKEM768') {
      score += 10;
      reasons.add(RealityReason.modernKeyExchange);
    }
    score += 2; // Redirect to another host: needs an HTTP request later.
    reasons.add(RealityReason.redirectNotChecked);
    if (!cdn) score += 5;
    final expires = p.certificate?.notAfter;
    if (valid && expires != null && expires.difference(now).inDays < 14) {
      score -= 15;
      reasons.add(RealityReason.expiresSoon);
    }
    return RealityCandidate._(
      p,
      repeat,
      level,
      level.index >= RealityLevel.criteria.index ? score.clamp(0, 100) : 0,
      reasons,
      proximity,
      fromServer,
      fromMihomo,
    );
  }

  final TlsProbeResult confirmation;
  final TlsProbeResult? repeat;
  final RealityLevel level;
  final int score;
  final List<RealityReason> reasons;
  final RealityProximity proximity;
  final RealityServerCheck? fromServer;
  final RealityMihomoCheck? fromMihomo;
  TlsScanTarget get target => confirmation.target;

  /// Passed every gate here; the server may confirm it further.
  bool get suitable => level.index >= RealityLevel.criteria.index;

  /// Higher level first, then score, then the faster handshake.
  static int compare(RealityCandidate a, RealityCandidate b) {
    final level = b.level.index - a.level.index;
    if (level != 0) return level;
    final score = b.score - a.score;
    if (score != 0) return score;
    final time = a.confirmation.tls.compareTo(b.confirmation.tls);
    return time != 0 ? time : a.target.key.compareTo(b.target.key);
  }
}

/// Concrete names worth confirming on one address: SAN first, then the CN;
/// a wildcard is never turned into an SNI.
List<String> realitySniCandidates(TlsCertificateInfo certificate) {
  final names = <String>{
    for (final n in certificate.names)
      if (isTlsScanSni(n)) n,
    if (isTlsScanSni(certificate.commonName.toLowerCase()))
      certificate.commonName.toLowerCase(),
  };
  return names.toList();
}

enum RealitySearchPhase {
  discovery,
  confirmation,
  stability,
  done,
  cancelled,
  failed,
  networkChanged,
}

/// The state of one search; [toJson] is its checkpoint. Results are scoped
/// to [networkIdentity] and lose meaning on another network.
final class RealitySearchState {
  RealitySearchState(this.plan, this.networkIdentity, this.startedAt);
  final RealitySearchPlan plan;
  final String networkIdentity;
  final DateTime startedAt;

  RealitySearchPhase phase = RealitySearchPhase.discovery;
  String code = '';
  int processed = 0, total = 0;
  ProbeNetwork? network;
  final discoveries = <IpAddress, TlsProbeResult>{};
  final pairs = <String, TlsProbeResult>{};
  final repeats = <String, TlsProbeResult>{};
  final serverChecks = <String, RealityServerCheck>{};
  final mihomoChecks = <String, RealityMihomoCheck>{};

  bool get finished => phase.index >= RealitySearchPhase.done.index;

  /// Addresses that completed a TLS handshake without SNI.
  int get tlsFound =>
      discoveries.values.where((p) => p.handshake == TlsHandshake.ok).length;

  List<RealityCandidate> candidates(DateTime now) => [
    for (final p in pairs.values)
      RealityCandidate.rate(
        p,
        repeat: repeats[p.target.key],
        fromServer: serverChecks[p.target.key],
        fromMihomo: mihomoChecks[p.target.key],
        server: plan.server,
        now: now,
      ),
  ]..sort(RealityCandidate.compare);

  Map<String, Object?> toJson() => {
    'version': 1,
    'plan': plan.toJson(),
    'network': networkIdentity,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'discoveries': [for (final p in discoveries.values) tlsProbeJson(p)],
    'pairs': [for (final p in pairs.values) tlsProbeJson(p)],
    'repeats': [for (final p in repeats.values) tlsProbeJson(p)],
    'serverChecks': {
      for (final e in serverChecks.entries) e.key: e.value.toJson(),
    },
    'mihomoChecks': {
      for (final e in mihomoChecks.entries) e.key: e.value.toJson(),
    },
  };

  /// Restores a checkpoint of exactly [plan]; anything else is rejected.
  factory RealitySearchState.fromJson(
    Map<String, dynamic> json,
    RealitySearchPlan plan,
  ) {
    final started = DateTime.tryParse('${json['startedAt']}');
    final network = json['network'];
    final saved = json['plan'];
    if (json['version'] != 1 ||
        started == null ||
        network is! String ||
        saved is! Map ||
        saved['port'] != plan.port ||
        saved['server'] != (plan.server?.canonical ?? '') ||
        '${saved['addresses']}' != '${plan.toJson()['addresses']}') {
      throw const FormatException('search_checkpoint');
    }
    final state = RealitySearchState(plan, network, started);
    final known = plan.addresses.toSet();
    List<Object?> list(String key) => json[key] is List
        ? json[key] as List<Object?>
        : throw const FormatException('search_checkpoint');
    TlsProbeResult read(Object? raw, {required bool sni}) {
      if (raw is! Map) throw const FormatException('search_checkpoint');
      final target = TlsScanTarget(
        '${raw['ip']}',
        raw['port'] is int ? raw['port'] as int : 0,
        sni: raw['sni'] is String ? raw['sni'] as String : '',
      );
      if (!known.contains(target.ip) ||
          target.port != plan.port ||
          target.sni.isNotEmpty != sni) {
        throw const FormatException('search_checkpoint');
      }
      return parseTlsProbe(raw, target);
    }

    for (final raw in list('discoveries')) {
      final p = read(raw, sni: false);
      state.discoveries[p.target.ip] = p;
    }
    for (final raw in list('pairs')) {
      final p = read(raw, sni: true);
      state.pairs[p.target.key] = p;
    }
    for (final raw in list('repeats')) {
      final p = read(raw, sni: true);
      if (!state.pairs.containsKey(p.target.key)) {
        throw const FormatException('search_checkpoint');
      }
      state.repeats[p.target.key] = p;
    }
    final checks = json['serverChecks'] ?? const <String, Object?>{};
    if (checks is! Map) throw const FormatException('search_checkpoint');
    for (final MapEntry(:key, :value) in checks.entries) {
      if (!state.pairs.containsKey(key)) {
        throw const FormatException('search_checkpoint');
      }
      state.serverChecks[key as String] = RealityServerCheck.fromJson(value);
    }
    final mihomo = json['mihomoChecks'] ?? const <String, Object?>{};
    if (mihomo is! Map) throw const FormatException('search_checkpoint');
    for (final MapEntry(:key, :value) in mihomo.entries) {
      if (!state.pairs.containsKey(key)) {
        throw const FormatException('search_checkpoint');
      }
      state.mihomoChecks[key as String] = RealityMihomoCheck.fromJson(value);
    }
    return state;
  }
}

class RealityTargetSearch {
  RealityTargetSearch({
    required this.transport,
    required this.network,
    this.limits = const TlsScanLimits(),
    this.maxPairs = 48,
    this.namesPerAddress = 2,
    this.stabilityTop = 6,
    this.pause = const Duration(milliseconds: 150),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final TlsScanTransport transport;

  /// The device network; checked before every batch.
  final Future<ProbeNetwork> Function() network;
  final TlsScanLimits limits;
  final int maxPairs, namesPerAddress, stabilityTop;

  /// Rate limit between batches.
  final Duration pause;
  final DateTime Function() clock;

  /// IP + SNI pairs to confirm, derived only from [discoveries], so a resumed
  /// search confirms the same pairs. Faster handshakes go first.
  List<TlsScanTarget> pairsFor(
    Map<IpAddress, TlsProbeResult> discoveries,
    int port,
  ) {
    final eligible =
        discoveries.values
            .where(
              (p) =>
                  p.handshake == TlsHandshake.ok &&
                  p.version == '1.3' &&
                  p.certificate != null,
            )
            .toList()
          ..sort((a, b) {
            final time = a.tls.compareTo(b.tls);
            return time != 0 ? time : a.target.ip.compareTo(b.target.ip);
          });
    final out = <TlsScanTarget>[];
    for (final p in eligible) {
      for (final name in realitySniCandidates(
        p.certificate!,
      ).take(namesPerAddress)) {
        if (out.length >= maxPairs) return out;
        out.add(TlsScanTarget(p.target.ip.canonical, port, sni: name));
      }
    }
    return out;
  }

  Future<RealitySearchState> run(
    RealitySearchPlan plan,
    CancellationToken token,
    void Function(RealitySearchState) update, {
    Map<String, dynamic>? checkpoint,
  }) async {
    ProbeNetwork net;
    try {
      net = await token.bind(network());
    } catch (_) {
      final state = RealitySearchState(plan, '', clock());
      state
        ..phase = token.isCancelled
            ? RealitySearchPhase.cancelled
            : RealitySearchPhase.failed
        ..code = token.isCancelled ? 'cancelled' : 'network_unavailable';
      update(state);
      return state;
    }
    final state = checkpoint == null
        ? RealitySearchState(plan, net.identity, clock())
        : RealitySearchState.fromJson(checkpoint, plan);
    state.network = net;
    if (state.networkIdentity != net.identity) {
      state
        ..phase = RealitySearchPhase.networkChanged
        ..code = 'network_changed';
      update(state);
      return state;
    }
    final direct = net.direct ? net.directInterface : '';
    var first = true;

    Future<bool> stop(RealitySearchPhase phase, String code) async {
      state
        ..phase = phase
        ..code = code;
      update(state);
      return false;
    }

    Future<bool> batches(
      List<TlsScanTarget> todo,
      bool resolve,
      void Function(TlsProbeResult) store,
    ) async {
      final size = limits.batchSize;
      for (var offset = 0; offset < todo.length; offset += size) {
        try {
          if (!first) await token.bind(Future<void>.delayed(pause));
          first = false;
          final now = await token.bind(network());
          if (now.identity != state.networkIdentity) {
            return stop(RealitySearchPhase.networkChanged, 'network_changed');
          }
        } catch (_) {
          return token.isCancelled
              ? stop(RealitySearchPhase.cancelled, 'cancelled')
              : stop(RealitySearchPhase.failed, 'network_unavailable');
        }
        final chunk = todo.skip(offset).take(size).toList();
        var batch = await transport.scan(
          chunk,
          token,
          limits: limits,
          resolve: resolve,
          directInterface: direct,
        );
        if (batch.status == TlsScanStatus.notTested && !token.isCancelled) {
          // One retry: a worker may fail once without the network changing.
          batch = await transport.scan(
            chunk,
            token,
            limits: limits,
            resolve: resolve,
            directInterface: direct,
          );
        }
        if (token.isCancelled || batch.status == TlsScanStatus.cancelled) {
          return stop(RealitySearchPhase.cancelled, 'cancelled');
        }
        if (batch.status != TlsScanStatus.scanned) {
          return stop(RealitySearchPhase.failed, batch.code);
        }
        batch.probes.forEach(store);
        state.processed += batch.probes.length;
        update(state);
      }
      return true;
    }

    void begin(RealitySearchPhase phase, int done, int total) {
      state
        ..phase = phase
        ..processed = done
        ..total = total;
      update(state);
    }

    final discovery = [
      for (final ip in plan.addresses) TlsScanTarget(ip.canonical, plan.port),
    ];
    begin(
      RealitySearchPhase.discovery,
      state.discoveries.length,
      discovery.length,
    );
    if (!await batches(
      [
        for (final t in discovery)
          if (!state.discoveries.containsKey(t.ip)) t,
      ],
      false,
      (p) => state.discoveries[p.target.ip] = p,
    )) {
      return state;
    }

    final pairs = pairsFor(state.discoveries, plan.port);
    begin(
      RealitySearchPhase.confirmation,
      pairs.where((t) => state.pairs.containsKey(t.key)).length,
      pairs.length,
    );
    if (!await batches(
      [
        for (final t in pairs)
          if (!state.pairs.containsKey(t.key)) t,
      ],
      true,
      (p) => state.pairs[p.target.key] = p,
    )) {
      return state;
    }

    final best = state
        .candidates(clock())
        .where((c) => c.suitable)
        .take(stabilityTop)
        .map((c) => c.target)
        .toList();
    begin(
      RealitySearchPhase.stability,
      best.where((t) => state.repeats.containsKey(t.key)).length,
      best.length,
    );
    if (!await batches(
      [
        for (final t in best)
          if (!state.repeats.containsKey(t.key)) t,
      ],
      false,
      (p) => state.repeats[p.target.key] = p,
    )) {
      return state;
    }
    state.code = 'done';
    begin(RealitySearchPhase.done, state.processed, state.total);
    return state;
  }
}
