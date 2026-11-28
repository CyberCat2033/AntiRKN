import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime.utc(2026, 11, 28);

TlsProbeResult tls(
  TlsScanTarget target, {
  String version = '1.3',
  String alpn = 'h2',
  String group = 'X25519MLKEM768',
  List<String> names = const [],
  String commonName = '',
  TlsCertificateCheck check = TlsCertificateCheck.valid,
  TlsDnsCheck dns = TlsDnsCheck.notChecked,
  int ms = 40,
  DateTime? notAfter,
}) => TlsProbeResult(
  target: target,
  reach: TlsReach.ok,
  handshake: TlsHandshake.ok,
  tcp: const Duration(milliseconds: 20),
  tls: Duration(milliseconds: ms),
  version: version,
  alpn: alpn,
  group: group,
  dns: dns,
  certificate: TlsCertificateInfo(
    names: names,
    namesTotal: names.length,
    commonName: commonName,
    issuer: 'Test CA',
    notBefore: DateTime.utc(2026, 1, 1),
    notAfter: notAfter ?? DateTime.utc(2027, 6, 1),
    check: target.sni.isEmpty && check == TlsCertificateCheck.valid
        ? TlsCertificateCheck.chainOnly
        : check,
  ),
);

TlsProbeResult refused(TlsScanTarget target) =>
    TlsProbeResult(target: target, reach: TlsReach.refused);

/// A small internet: .10 and .20 host modern sites, .30 is TLS 1.2 only,
/// everything else refuses.
TlsProbeResult world(TlsScanTarget t) {
  final last = t.ip.bytes.last;
  return switch ((last, t.sni)) {
    (10, '') => tls(
      t,
      names: [
        '*.alpha.example',
        'alpha.example',
        'www.alpha.example',
        'cdn.alpha.example',
      ],
      ms: 30,
    ),
    (10, _) => tls(t, names: ['alpha.example'], dns: TlsDnsCheck.match, ms: 30),
    (20, '') => tls(
      t,
      names: [],
      commonName: 'Beta.Example',
      ms: 60,
      group: 'X25519',
    ),
    (20, _) => tls(
      t,
      names: ['beta.example'],
      group: 'X25519',
      dns: TlsDnsCheck.mismatch,
      ms: 60,
    ),
    (30, '') => tls(t, version: '1.2', names: ['old.example']),
    _ => refused(t),
  };
}

final class FakeTransport implements TlsScanTransport {
  FakeTransport({this.failures = 0, this.cancelAfter, this.token});
  int failures;
  final int? cancelAfter;
  final CancellationToken? token;
  final batches = <List<TlsScanTarget>>[];
  final resolves = <bool>[];
  @override
  Future<TlsScanBatch> scan(
    List<TlsScanTarget> targets,
    CancellationToken cancellation, {
    TlsScanLimits limits = const TlsScanLimits(),
    bool resolve = true,
    String directInterface = '',
  }) async {
    expect(targets.length, lessThanOrEqualTo(limits.batchSize));
    if (failures > 0) {
      failures--;
      return TlsScanBatch(
        status: TlsScanStatus.notTested,
        code: 'runtime_unavailable',
      );
    }
    batches.add(targets);
    resolves.add(resolve);
    if (cancelAfter != null && batches.length > cancelAfter!) {
      token!.cancel();
      return TlsScanBatch(status: TlsScanStatus.cancelled, code: 'cancelled');
    }
    return TlsScanBatch(
      status: TlsScanStatus.scanned,
      code: 'scanned',
      probes: [for (final t in targets) world(t)],
    );
  }
}

RealityTargetSearch search(
  TlsScanTransport transport, {
  String Function()? identity,
}) => RealityTargetSearch(
  transport: transport,
  network: () async => ProbeNetwork(identity?.call() ?? 'wifi-1', 'wifi'),
  limits: const TlsScanLimits(concurrency: 4),
  pause: Duration.zero,
  clock: () => now,
);

void main() {
  group('plan', () {
    test('neighbours of the server stay inside its /24', () {
      final plan = RealitySearchPlan.neighbors('8.8.8.37');
      expect(plan.addresses.length, 253);
      expect(plan.addresses.first.canonical, '8.8.8.1');
      expect(plan.addresses.last.canonical, '8.8.8.254');
      expect(
        plan.addresses.map((a) => a.canonical),
        isNot(contains('8.8.8.37')),
      );
      expect(plan.server!.canonical, '8.8.8.37');
      expect(
        RealitySearchPlan.neighbors(
          '8.8.8.37',
          prefix: 30,
        ).addresses.map((a) => a.canonical),
        ['8.8.8.38'],
      );
    });
    test('large, private or IPv6 ranges are refused', () {
      for (final make in <void Function()>[
        () => RealitySearchPlan.neighbors('8.8.8.37', prefix: 23),
        () =>
            RealitySearchPlan.neighbors('8.8.8.37', prefix: 16, limit: 100000),
        () => RealitySearchPlan.neighbors('10.0.0.5'),
        () => RealitySearchPlan.neighbors('2001:4860::1'),
        () => RealitySearchPlan.explicit(['8.8.8.8', '192.168.1.1']),
        () => RealitySearchPlan.explicit([]),
        () => RealitySearchPlan.explicit(['8.8.8.8'], server: 'vps'),
      ]) {
        expect(make, throwsA(isA<FormatException>()));
      }
      expect(
        RealitySearchPlan.neighbors(
          '8.8.8.37',
          prefix: 23,
          limit: 512,
        ).addresses.length,
        509,
      );
    });
    test('explicit addresses are deduplicated and keep their order', () {
      final plan = RealitySearchPlan.explicit([
        ' 1.1.1.1',
        '8.8.8.8',
        '1.1.1.1',
        '2606:4700::1111',
      ]);
      expect(plan.addresses.map((a) => a.canonical), [
        '1.1.1.1',
        '8.8.8.8',
        '2606:4700::1111',
      ]);
      expect(plan.server, isNull);
    });
  });

  group('rating', () {
    final server = IpAddress.parse('8.8.8.37');
    final pair = TlsScanTarget('8.8.8.10', 443, sni: 'alpha.example');
    test('a stable modern neighbour passes every gate', () {
      final observed = tls(
        pair,
        names: ['alpha.example'],
        dns: TlsDnsCheck.match,
      );
      final c = RealityCandidate.rate(
        observed,
        repeat: observed,
        server: server,
        now: now,
      );
      expect(c.level, RealityLevel.criteria);
      expect(c.score, 30 + 20 + 7 + 15 + 10 + 2 + 5);
      expect(
        c.reasons,
        containsAll([
          RealityReason.sameNetwork,
          RealityReason.dnsMatch,
          RealityReason.stable,
          RealityReason.modernKeyExchange,
          RealityReason.serverNotChecked,
        ]),
      );
      final unchecked = RealityCandidate.rate(
        observed,
        server: server,
        now: now,
      );
      expect(unchecked.score, c.score - 8);
      final changed = RealityCandidate.rate(
        observed,
        repeat: tls(pair, group: 'X25519'),
        server: server,
        now: now,
      );
      expect(changed.reasons, contains(RealityReason.unstable));
      expect(changed.score, c.score - 15);
    });
    test('gates keep a candidate below criteria with a zero score', () {
      for (final (observed, level, reason) in [
        (
          tls(pair, version: '1.2'),
          RealityLevel.confirmed,
          RealityReason.notTls13,
        ),
        (
          tls(pair, alpn: 'http/1.1'),
          RealityLevel.confirmed,
          RealityReason.noH2,
        ),
        (
          tls(pair, group: 'CurveP256'),
          RealityLevel.confirmed,
          RealityReason.unsupportedGroup,
        ),
        (
          tls(pair, check: TlsCertificateCheck.nameMismatch),
          RealityLevel.discovered,
          RealityReason.certificateInvalid,
        ),
        (
          tls(TlsScanTarget('104.16.1.1', 443, sni: 'alpha.example')),
          RealityLevel.confirmed,
          RealityReason.knownCdn,
        ),
        (
          TlsProbeResult(
            target: pair,
            reach: TlsReach.ok,
            handshake: TlsHandshake.reset,
          ),
          RealityLevel.discovered,
          RealityReason.handshakeFailed,
        ),
      ]) {
        final c = RealityCandidate.rate(observed, server: server, now: now);
        expect((c.level, c.score), (level, 0), reason: '$reason');
        expect(c.reasons, contains(reason));
      }
    });
    test('distance, DNS and expiry move the score', () {
      final far = TlsScanTarget('9.9.9.9', 443, sni: 'alpha.example');
      final near = TlsScanTarget('8.8.4.4', 443, sni: 'alpha.example');
      int score(TlsProbeResult p) =>
          RealityCandidate.rate(p, server: server, now: now).score;
      final base = score(tls(pair, dns: TlsDnsCheck.match));
      expect(score(tls(near, dns: TlsDnsCheck.match)), base - 15);
      expect(score(tls(far, dns: TlsDnsCheck.match)), base - 30);
      expect(score(tls(pair, dns: TlsDnsCheck.mismatch)), base - 20);
      expect(score(tls(pair, dns: TlsDnsCheck.unresolved)), base - 10);
      final expiring = RealityCandidate.rate(
        tls(
          pair,
          dns: TlsDnsCheck.match,
          notAfter: now.add(const Duration(days: 5)),
        ),
        server: server,
        now: now,
      );
      expect(expiring.score, base - 15);
      expect(expiring.reasons, contains(RealityReason.expiresSoon));
      expect(
        RealityCandidate.rate(tls(pair), now: now).proximity,
        RealityProximity.unknown,
      );
    });
    test('SNI candidates are concrete names only', () {
      final c = tls(
        TlsScanTarget('8.8.8.10', 443),
        names: ['*.a.example', 'a.example', 'b.example'],
        commonName: 'A.example',
      ).certificate!;
      expect(realitySniCandidates(c), ['a.example', 'b.example']);
    });
  });

  group('search', () {
    final plan = RealitySearchPlan.explicit([
      for (var i = 1; i <= 40; i++) '8.8.8.$i',
    ], server: '8.8.8.37');

    test('discovers, confirms names and repeats the best pairs', () async {
      final transport = FakeTransport();
      final phases = <RealitySearchPhase>[];
      final state = await search(transport).run(plan, CancellationToken(), (s) {
        if (phases.isEmpty || phases.last != s.phase) phases.add(s.phase);
      });
      expect(state.phase, RealitySearchPhase.done);
      expect(phases, [
        RealitySearchPhase.discovery,
        RealitySearchPhase.confirmation,
        RealitySearchPhase.stability,
        RealitySearchPhase.done,
      ]);
      expect(state.discoveries.length, 40);
      expect(state.tlsFound, 3);
      // Two concrete names per address; TLS 1.2 is not confirmed.
      expect(state.pairs.keys, [
        '8.8.8.10|443|alpha.example',
        '8.8.8.10|443|www.alpha.example',
        '8.8.8.20|443|beta.example',
      ]);
      expect(transport.resolves, [
        false,
        false,
        false,
        false,
        false,
        true,
        false,
      ]);
      final candidates = state.candidates(now);
      expect(candidates.first.target.key, '8.8.8.10|443|alpha.example');
      expect(candidates.first.level, RealityLevel.criteria);
      expect(candidates.first.reasons, contains(RealityReason.stable));
      expect(state.repeats.keys.toSet(), {
        for (final c in candidates.where(
          (c) => c.level == RealityLevel.criteria,
        ))
          c.target.key,
      });
    });

    test('the pair budget is finite', () async {
      final state = await RealityTargetSearch(
        transport: FakeTransport(),
        network: () async => const ProbeNetwork('wifi-1', 'wifi'),
        limits: const TlsScanLimits(concurrency: 4),
        maxPairs: 1,
        pause: Duration.zero,
        clock: () => now,
      ).run(plan, CancellationToken(), (_) {});
      expect(state.pairs.keys, ['8.8.8.10|443|alpha.example']);
    });

    test(
      'a cancelled search resumes from its checkpoint without repeats',
      () async {
        final token = CancellationToken();
        final first = FakeTransport(cancelAfter: 2, token: token);
        Map<String, dynamic>? checkpoint;
        final stopped = await search(first).run(
          plan,
          token,
          (s) => checkpoint =
              jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
        );
        expect(stopped.phase, RealitySearchPhase.cancelled);
        expect(stopped.discoveries.length, 16);
        final second = FakeTransport();
        final resumed = await search(
          second,
        ).run(plan, CancellationToken(), (_) {}, checkpoint: checkpoint);
        expect(resumed.phase, RealitySearchPhase.done);
        expect(resumed.discoveries.length, 40);
        expect(second.batches.first.first.ip.canonical, '8.8.8.17');
        expect(resumed.startedAt, stopped.startedAt);
        expect(
          resumed.candidates(now).map((c) => (c.target.key, c.score)),
          (await search(FakeTransport()).run(
            plan,
            CancellationToken(),
            (_) {},
          )).candidates(now).map((c) => (c.target.key, c.score)),
        );
      },
    );

    test('a checkpoint belongs to its plan and network', () async {
      final done = await search(
        FakeTransport(),
      ).run(plan, CancellationToken(), (_) {});
      final json =
          jsonDecode(jsonEncode(done.toJson())) as Map<String, dynamic>;
      final other = RealitySearchPlan.explicit(['8.8.8.1']);
      expect(
        () => RealitySearchState.fromJson(json, other),
        throwsA(isA<FormatException>()),
      );
      final tampered = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      (tampered['pairs'] as List).add({
        ...(tampered['pairs'] as List).first as Map,
        'ip': '1.1.1.1',
      });
      expect(
        () => RealitySearchState.fromJson(tampered, plan),
        throwsA(isA<FormatException>()),
      );
      final transport = FakeTransport();
      final moved = await search(
        transport,
        identity: () => 'lte-2',
      ).run(plan, CancellationToken(), (_) {}, checkpoint: json);
      expect(moved.phase, RealitySearchPhase.networkChanged);
      expect(transport.batches, isEmpty);
    });

    test('a network change stops the search between batches', () async {
      var calls = 0;
      final state = await search(
        FakeTransport(),
        identity: () => ++calls > 2 ? 'lte-2' : 'wifi-1',
      ).run(plan, CancellationToken(), (_) {});
      expect(state.phase, RealitySearchPhase.networkChanged);
      expect(state.discoveries.length, 8);
    });

    test(
      'one worker failure is retried, a second one stops the search',
      () async {
        final once = await search(
          FakeTransport(failures: 1),
        ).run(plan, CancellationToken(), (_) {});
        expect(once.phase, RealitySearchPhase.done);
        final twice = await search(
          FakeTransport(failures: 2),
        ).run(plan, CancellationToken(), (_) {});
        expect(
          (twice.phase, twice.code),
          (RealitySearchPhase.failed, 'runtime_unavailable'),
        );
        expect(twice.discoveries, isEmpty);
      },
    );

    test('a device VPN bypass interface is passed to every batch', () async {
      final seen = <String>[];
      final transport = _Recording(seen);
      await RealityTargetSearch(
        transport: transport,
        network: () async => const ProbeNetwork(
          'wifi-1',
          'wifi',
          vpn: true,
          bound: true,
          directInterface: 'wlan0',
          directSource: '192.168.1.5',
        ),
        pause: Duration.zero,
      ).run(
        RealitySearchPlan.explicit(['8.8.8.10']),
        CancellationToken(),
        (_) {},
      );
      expect(seen, isNotEmpty);
      expect(seen.toSet(), {'wlan0'});
    });
  });
}

final class _Recording implements TlsScanTransport {
  _Recording(this.seen);
  final List<String> seen;
  @override
  Future<TlsScanBatch> scan(
    List<TlsScanTarget> targets,
    CancellationToken cancellation, {
    TlsScanLimits limits = const TlsScanLimits(),
    bool resolve = true,
    String directInterface = '',
  }) async {
    seen.add(directInterface);
    return TlsScanBatch(
      status: TlsScanStatus.scanned,
      code: 'scanned',
      probes: [for (final t in targets) world(t)],
    );
  }
}
