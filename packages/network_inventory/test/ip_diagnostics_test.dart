import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_network_inventory/antirkn_network_inventory.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeProbes implements IpProbeTransport {
  final calls = <IpProbeTarget>[];
  String route = 'wifi';
  int closed = 0;
  FutureOr<IpProbeStatus> Function(IpProbeTarget)? answer;
  @override
  Future<ProbeNetwork> network() async => ProbeNetwork(route, route);
  @override
  Future<IpProbeResult> probe(
    IpProbeTarget target,
    ProbeNetwork network,
    Duration timeout,
    CancellationToken cancellation,
  ) async {
    calls.add(target);
    cancellation.check();
    return IpProbeResult(
      await answer?.call(target) ?? IpProbeStatus.reachable,
      1,
    );
  }

  @override
  Future<void> cancel() async {
    closed++;
  }
}

List<IpControl> controls({int count = 10, bool v6 = false}) => [
  for (var i = 1; i <= count; i++)
    IpControl(
      'control $i',
      'provider $i',
      IpProbeTarget(v6 ? '2001:db8::$i' : '192.0.2.$i', 53),
    ),
];
final first = IpProbeTarget('198.51.100.10', 443);
final second = IpProbeTarget('198.51.100.11', 443);

void main() {
  const policy = IpControlPolicy();
  test('9/10 and 13/14 are normal; one provider failure is not strong', () {
    for (final count in [10, 14]) {
      final list = controls(count: count);
      expect(
        policy.classify(list, {
          for (var i = 0; i < count; i++) list[i].target.key: i != 0,
        }),
        ControlHealth.healthy,
      );
    }
    final list = [
      for (final c in controls()) IpControl(c.name, 'one', c.target),
    ];
    expect(policy.classify(list, {}), ControlHealth.degraded);
  });
  test(
    'regional evidence needs independent foreign controls and a live RU control',
    () {
      final list = [
        for (var i = 0; i < 10; i++)
          IpControl(
            'c',
            'p$i',
            IpProbeTarget('192.0.2.${i + 1}', 53),
            region: i < 3
                ? 'foreign'
                : i == 3
                ? 'ru'
                : 'anycast',
          ),
      ];
      final now = {
        for (var i = 0; i < list.length; i++) list[i].target.key: i >= 3,
      };
      expect(policy.classify(list, now), ControlHealth.strong);
      now[list[3].target.key] = false;
      expect(policy.classify(list, now), ControlHealth.degraded);
    },
  );
  test('presets contain unique 14 IPv4 and 12 IPv6 public controls', () {
    final list = defaultIpControls();
    expect(
      list.where((c) => c.target.address.family == IpFamily.ipv4),
      hasLength(14),
    );
    expect(
      list.where((c) => c.target.address.family == IpFamily.ipv6),
      hasLength(12),
    );
    expect(list.map((c) => c.target.key).toSet(), hasLength(26));
    expect(
      list.every((c) => c.target.address.category == IpCategory.publicUnicast),
      isTrue,
    );
  });
  test(
    'successful targets run once in order after a stable baseline',
    () async {
      final transport = FakeProbes();
      final run = await IpDiagnosticEngine(
        transport: transport,
        controls: controls(),
      ).run([first, second], CancellationToken(), (_) {});
      expect(run.stage, IpDiagnosticStage.complete);
      expect(run.completed, 2);
      expect(transport.calls, hasLength(22));
      expect(transport.calls.skip(20), [first, second]);
      expect(transport.closed, 1);
    },
  );
  test(
    'failed target plus 9/10 controls continues without strong claim',
    () async {
      final transport = FakeProbes();
      transport.answer = (t) =>
          t == first ||
              transport.calls.length > 21 && t.address.canonical == '192.0.2.1'
          ? IpProbeStatus.timeout
          : IpProbeStatus.reachable;
      final run = await IpDiagnosticEngine(
        transport: transport,
        controls: controls(),
      ).run([first, second], CancellationToken(), (_) {});
      expect(run.stage, IpDiagnosticStage.complete);
      expect(run.suspectedStrong, isFalse);
      expect(transport.calls.where((t) => t == first), hasLength(1));
      expect(transport.calls.last, second);
    },
  );
  test(
    'two independent collapses stop queue and do not retry suspect',
    () async {
      final transport = FakeProbes();
      transport.answer = (t) => transport.calls.length > 20
          ? IpProbeStatus.timeout
          : IpProbeStatus.reachable;
      final run = await IpDiagnosticEngine(
        transport: transport,
        controls: controls(),
        recoveryWindow: Duration.zero,
      ).run([first, second], CancellationToken(), (_) {});
      expect(run.stage, IpDiagnosticStage.degraded);
      expect(run.suspectedStrong, isTrue);
      expect(run.completed, 1);
      expect(transport.calls.where((t) => t == first), hasLength(1));
      expect(transport.calls, isNot(contains(second)));
      expect(
        run.samples.where((s) => s.phase == 'confirmation'),
        hasLength(10),
      );
    },
  );
  test(
    'transient control loss recovers on confirmation and continues',
    () async {
      final transport = FakeProbes();
      transport.answer = (t) =>
          transport.calls.length > 20 && transport.calls.length <= 31
          ? IpProbeStatus.timeout
          : IpProbeStatus.reachable;
      final run = await IpDiagnosticEngine(
        transport: transport,
        controls: controls(),
      ).run([first, second], CancellationToken(), (_) {});
      expect(run.stage, IpDiagnosticStage.complete);
      expect(run.suspectedStrong, isFalse);
      expect(transport.calls.last, second);
    },
  );
  test(
    'recovery touches controls only and never resumes target queue',
    () async {
      final transport = FakeProbes();
      transport.answer = (t) =>
          transport.calls.length > 20 && transport.calls.length <= 41
          ? IpProbeStatus.timeout
          : IpProbeStatus.reachable;
      final run = await IpDiagnosticEngine(
        transport: transport,
        controls: controls(),
        recoveryInterval: const Duration(milliseconds: 1),
        recoveryWindow: const Duration(seconds: 1),
      ).run([first, second], CancellationToken(), (_) {});
      expect(run.suspectedStrong, isTrue);
      expect(run.recoveredAt, isNotNull);
      expect(transport.calls, isNot(contains(second)));
      expect(transport.calls.where((t) => t == first), hasLength(1));
    },
  );
  test('insufficient baseline does not contact a target', () async {
    final transport = FakeProbes()
      ..answer = (t) =>
          t.address.canonical.endsWith('.1') ||
              t.address.canonical.endsWith('.2') ||
              t.address.canonical.endsWith('.3')
          ? IpProbeStatus.timeout
          : IpProbeStatus.reachable;
    final run = await IpDiagnosticEngine(
      transport: transport,
      controls: controls(),
    ).run([first], CancellationToken(), (_) {});
    expect(run.stage, IpDiagnosticStage.insufficient);
    expect(transport.calls, isNot(contains(first)));
  });
  test(
    'targets are excluded from baseline even when listed as controls',
    () async {
      final list = controls();
      final transport = FakeProbes();
      final run = await IpDiagnosticEngine(
        transport: transport,
        controls: list,
      ).run([list.first.target], CancellationToken(), (_) {});
      expect(run.stage, IpDiagnosticStage.complete);
      expect(
        transport.calls.where((t) => t.address == list.first.target.address),
        hasLength(1),
      );
    },
  );
  test(
    'IPv6 needs its own baseline and cannot inherit IPv4 reachability',
    () async {
      final transport = FakeProbes()
        ..answer = (t) => t.address.family == IpFamily.ipv6
            ? IpProbeStatus.unavailable
            : IpProbeStatus.reachable;
      final v6 = IpProbeTarget('2001:db8:ffff::1', 443);
      final run = await IpDiagnosticEngine(
        transport: transport,
        controls: [...controls(), ...controls(v6: true)],
      ).run([first, v6], CancellationToken(), (_) {});
      expect(run.stage, IpDiagnosticStage.insufficient);
      expect(run.completed, 1);
      expect(transport.calls, isNot(contains(v6)));
    },
  );
  test('route changes invalidate result before next target', () async {
    final transport = FakeProbes();
    transport.answer = (t) {
      if (t == first) transport.route = 'mobile';
      return IpProbeStatus.reachable;
    };
    final run = await IpDiagnosticEngine(
      transport: transport,
      controls: controls(),
    ).run([first, second], CancellationToken(), (_) {});
    expect(run.stage, IpDiagnosticStage.networkChanged);
    expect(transport.calls, isNot(contains(second)));
    expect(transport.closed, 1);
  });
  test('stop during recovery cancels timer and closes transport', () async {
    final transport = FakeProbes();
    final token = CancellationToken();
    transport.answer = (t) => transport.calls.length > 20
        ? IpProbeStatus.timeout
        : IpProbeStatus.reachable;
    final run =
        await IpDiagnosticEngine(
          transport: transport,
          controls: controls(),
        ).run([first, second], token, (r) {
          if (r.stage == IpDiagnosticStage.recovery) token.cancel();
        });
    expect(run.stage, IpDiagnosticStage.cancelled);
    expect(transport.closed, 1);
    expect(transport.calls, isNot(contains(second)));
  });
}
