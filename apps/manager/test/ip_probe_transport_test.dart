import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/network/socket_ip_probe_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const network = ProbeNetwork('fixture', 'loopback');
  late SocketIpProbeTransport transport;
  late ServerSocket server;
  final connections = <Socket>[];
  setUp(() async {
    transport = SocketIpProbeTransport();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });
  tearDown(() async {
    await transport.cancel();
    for (final s in connections) {
      s.destroy();
    }
    connections.clear();
    await server.close();
  });
  Future<IpProbeResult> probe(
    IpProbeKind kind, {
    CancellationToken? token,
    Duration timeout = const Duration(seconds: 1),
  }) => transport.probe(
    IpProbeTarget('127.0.0.1', server.port, kind: kind, host: 'localhost'),
    network,
    timeout,
    token ?? CancellationToken(),
  );

  test(
    'Linux route snapshot reads both families without probing an endpoint',
    () async {
      final observed = await transport.network();
      expect(observed.kind, 'system');
      expect(observed.identity, isNotEmpty);
      expect(observed.bound, isFalse);
    },
    skip: !Platform.isLinux,
  );

  test('TCP handshake succeeds on an actual local socket', () async {
    server.listen(connections.add);
    expect((await probe(IpProbeKind.tcp)).status, IpProbeStatus.reachable);
  });
  test(
    'SSH accepts a banner after preliminary lines without authentication',
    () async {
      server.listen((s) {
        connections.add(s);
        s.add(ascii.encode('Welcome\r\nSSH-2.0-TestServer\r\n'));
      });
      expect((await probe(IpProbeKind.ssh)).status, IpProbeStatus.reachable);
    },
  );
  test('HTTP control requests /0 and validates the status', () async {
    final request = Completer<String>();
    server.listen((s) {
      connections.add(s);
      s.listen((data) {
        if (!request.isCompleted) request.complete(ascii.decode(data));
        s.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'));
      });
    });
    expect((await probe(IpProbeKind.http)).status, IpProbeStatus.reachable);
    expect(
      await request.future,
      startsWith('GET /0 HTTP/1.0\r\nHost: localhost'),
    );
  });
  test('wrong banner is a protocol result, not a timeout', () async {
    server.listen((s) async {
      connections.add(s);
      s.add(ascii.encode('not SSH\n'));
      await s.close();
    });
    expect((await probe(IpProbeKind.ssh)).status, IpProbeStatus.protocolError);
  });
  test('silent service is bounded by the whole-probe deadline', () async {
    server.listen(connections.add);
    final watch = Stopwatch()..start();
    expect(
      (await probe(
        IpProbeKind.ssh,
        timeout: const Duration(milliseconds: 40),
      )).status,
      IpProbeStatus.timeout,
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });
  test('cancellation closes a connected socket during banner wait', () async {
    final accepted = Completer<void>();
    final closed = Completer<void>();
    server.listen((s) {
      connections.add(s);
      accepted.complete();
      s.listen((_) {}, onDone: closed.complete);
    });
    final token = CancellationToken();
    final work = probe(IpProbeKind.ssh, token: token);
    final expectation = expectLater(
      work,
      throwsA(
        isA<SshFailure>().having((e) => e.issue, 'issue', SshIssue.cancelled),
      ),
    );
    await accepted.future;
    token.cancel();
    await expectation;
    await closed.future.timeout(const Duration(seconds: 1));
  });
  test('closed local port reports connection refused separately', () async {
    final port = server.port;
    await server.close();
    final result = await transport.probe(
      IpProbeTarget('127.0.0.1', port),
      network,
      const Duration(seconds: 1),
      CancellationToken(),
    );
    expect(result.status, IpProbeStatus.refused);
  });
}
