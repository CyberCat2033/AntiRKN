import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter_test/flutter_test.dart';

const good = CoreTrafficCheck(
  status: CoreTrafficStatus.success,
  code: 'connected',
  tcp: true,
  udp: true,
  udpTested: true,
);
const bad = CoreTrafficCheck(
  status: CoreTrafficStatus.failed,
  code: 'udp_failed',
  tcp: true,
  udpTested: true,
);

class Network implements IpProbeTransport {
  int goodControls = 10, probes = 0;
  String identity = 'wifi-1';
  bool vpn = false;
  @override
  Future<ProbeNetwork> network() async =>
      ProbeNetwork(identity, 'wifi', vpn: vpn);
  @override
  Future<void> cancel() async {}
  @override
  Future<IpProbeResult> probe(
    IpProbeTarget target,
    ProbeNetwork network,
    Duration timeout,
    CancellationToken cancellation,
  ) async {
    cancellation.check();
    return IpProbeResult(
      probes++ % 10 < goodControls
          ? IpProbeStatus.reachable
          : IpProbeStatus.timeout,
      1,
    );
  }
}

class Core implements CoreProbeTransport {
  Core(this.answers);
  final List<CoreTrafficCheck> answers;
  final calls = <bool>[];
  void Function()? after;
  @override
  Future<CoreTrafficCheck> probe(
    Map<String, Object?>? proxy,
    CancellationToken cancellation, {
    required bool udp,
  }) async {
    calls.add(proxy == null);
    after?.call();
    return answers.removeAt(0);
  }
}

void main() {
  late Network network;
  late Core core;
  late CancellationToken token;
  late ConnectionProbeEngine engine;
  void setup(List<CoreTrafficCheck> results) {
    core = Core(results);
    network = Network();
    token = CancellationToken();
    engine = ConnectionProbeEngine(
      core: core,
      network: network,
      controls: [
        for (var i = 1; i <= 10; i++)
          IpControl('c$i', 'p$i', IpProbeTarget('192.0.2.$i', 443)),
      ],
    );
  }

  Future<ConnectionCheck> check() => engine.check({'type': 'wireguard'}, token);
  test(
    '9 of 10 healthy controls allow success and no direct fallback',
    () async {
      setup([good]);
      network.goodControls = 9;
      expect((await check()).status, ConnectionCheckStatus.working);
      expect(core.calls, [false]);
    },
  );
  test('degraded network does not touch the connection', () async {
    setup([]);
    network.goodControls = 8;
    expect((await check()).code, 'control_failed');
    expect(core.calls, isEmpty);
  });
  test(
    'UDP regression needs healthy destinations and a repeated failure',
    () async {
      setup([bad, good, bad]);
      expect((await check()).status, ConnectionCheckStatus.failed);
      expect(core.calls, [false, true, false]);
      expect(network.probes, 20);
    },
  );
  test('direct control success never counts as proxy success', () async {
    setup([bad, good, bad]);
    expect((await check()).traffic?.udp, false);
  });
  test('failed direct destination control cannot blame server', () async {
    setup([bad, bad]);
    expect((await check()).status, ConnectionCheckStatus.networkProblem);
    expect(core.calls, [false, true]);
  });
  test('retry can recover a transient connection failure', () async {
    setup([bad, good, good]);
    expect((await check()).status, ConnectionCheckStatus.working);
  });
  test('changing networks invalidates a success', () async {
    setup([good]);
    core.after = () => network.identity = 'mobile-2';
    expect((await check()).code, 'network_changed');
  });
  test('active system VPN cannot produce a green check', () async {
    setup([]);
    network.vpn = true;
    expect((await check()).code, 'vpn_active');
    expect(core.calls, isEmpty);
  });
  test(
    'cancellation after native reply cannot produce a green check',
    () async {
      setup([good]);
      core.after = token.cancel;
      expect((await check()).status, ConnectionCheckStatus.cancelled);
    },
  );
  test('unsupported route has no retry or direct substitute', () async {
    setup([
      const CoreTrafficCheck(
        status: CoreTrafficStatus.notTested,
        code: 'unsupported_route',
      ),
    ]);
    expect((await check()).status, ConnectionCheckStatus.notTested);
    expect(core.calls, [false]);
  });
}
