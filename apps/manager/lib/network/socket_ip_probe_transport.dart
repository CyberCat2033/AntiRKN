import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';

/// Desktop sockets use the current OS route; route changes invalidate a run.
class SocketIpProbeTransport implements IpProbeTransport {
  final _sockets = <Socket>{};
  final _pending = <ConnectionTask<Socket>>{};
  @override
  Future<ProbeNetwork> network() async {
    final interfaces = await NetworkInterface.list();
    final addresses = [
      for (final i in interfaces)
        '${i.name}:${i.addresses.map((a) => a.address).join(',')}',
    ]..sort();
    String routes = '';
    if (Platform.isLinux) {
      final tables = await Future.wait([
        Process.run('ip', [
          '-j',
          'route',
          'show',
          'table',
          'all',
        ]).timeout(const Duration(seconds: 2)),
        Process.run('ip', [
          '-j',
          '-6',
          'route',
          'show',
          'table',
          'all',
        ]).timeout(const Duration(seconds: 2)),
        Process.run('ip', [
          '-j',
          'rule',
          'show',
        ]).timeout(const Duration(seconds: 2)),
        Process.run('ip', [
          '-j',
          '-6',
          'rule',
          'show',
        ]).timeout(const Duration(seconds: 2)),
      ]);
      if (tables.any((t) => t.exitCode != 0)) {
        throw const FormatException('network_unknown');
      }
      routes = tables
          .map(
            (t) => canonicalJson([
              for (final value in jsonDecode(t.stdout as String) as List)
                (Map<String, dynamic>.from(value as Map)
                  ..remove('expires')
                  ..remove('cache')
                  ..remove('used')),
            ]),
          )
          .join('|');
    } else if (Platform.isWindows) {
      final table = await Process.run('route', [
        'PRINT',
      ]).timeout(const Duration(seconds: 3));
      if (table.exitCode != 0) throw const FormatException('network_unknown');
      routes = table.stdout as String;
    }
    // Names alone miss common clients: Mihomo/Clash create "Meta", sing-box
    // and Hiddify use their own names. A VPN in the path makes a failed probe
    // look like broken server settings, so detect TUN/TAP devices by kind.
    final vpn = interfaces.any((i) => _tunnel(i.name));
    final direct = vpn && Platform.isLinux
        ? await _directRoute()
        : (interface: '', source: '');
    return ProbeNetwork(
      '${addresses.join('|')}|$routes',
      'system',
      vpn: vpn,
      directInterface: direct.interface,
      directSource: direct.source,
    );
  }

  static bool _tunnel(String name) =>
      RegExp(
        r'^(tun|tap|wg|utun|meta|mihomo|clash|sing-?box|hiddify|wintun|nekoray|throne)|vpn|wireguard|tunnel',
        caseSensitive: false,
      ).hasMatch(name) ||
      (Platform.isLinux && File('/sys/class/net/$name/tun_flags').existsSync());

  /// Policy-routing VPNs (Mihomo/sing-box TUN) keep the physical default route
  /// in the main table. A socket bound to that interface's address leaves the
  /// device directly, so probes measure this network instead of the VPN. The
  /// kernel's own route lookup must confirm it; otherwise nothing is bypassed.
  static Future<({String interface, String source})> _directRoute() async {
    const none = (interface: '', source: '');
    Future<List> json(List<String> args) async {
      final r = await Process.run(
        'ip',
        args,
      ).timeout(const Duration(seconds: 2));
      if (r.exitCode != 0) return const [];
      return jsonDecode(r.stdout as String) as List? ?? const [];
    }

    try {
      final defaults =
          [
            for (final route in await json([
              '-j',
              '-4',
              'route',
              'show',
              'table',
              'main',
              'default',
            ]))
              if (route is Map &&
                  route['dev'] is String &&
                  !_tunnel(route['dev'] as String))
                route,
          ]..sort(
            (a, b) =>
                ((a['metric'] as int?) ?? 0) - ((b['metric'] as int?) ?? 0),
          );
      for (final route in defaults) {
        final dev = route['dev'] as String;
        var source = route['prefsrc'] as String?;
        if (source == null) {
          final links = await json(['-j', '-4', 'addr', 'show', 'dev', dev]);
          source = links
              .whereType<Map>()
              .expand((l) => (l['addr_info'] as List? ?? const []))
              .whereType<Map>()
              .where((a) => a['family'] == 'inet' && a['scope'] == 'global')
              .map((a) => a['local'])
              .whereType<String>()
              .firstOrNull;
        }
        if (source == null) continue;
        final check = await json([
          '-j',
          'route',
          'get',
          '1.1.1.1',
          'from',
          source,
        ]);
        if (check.whereType<Map>().any((r) => r['dev'] == dev)) {
          return (interface: dev, source: source);
        }
      }
    } catch (_) {
      /* No proven direct route: probes report the VPN as active. */
    }
    return none;
  }

  @override
  Future<IpProbeResult> probe(
    IpProbeTarget target,
    ProbeNetwork network,
    Duration timeout,
    CancellationToken cancellation,
  ) async {
    final watch = Stopwatch()..start();
    Socket? socket;
    var finished = false;
    ConnectionTask<Socket>? task;
    IpProbeStatus status = IpProbeStatus.unavailable;
    Duration remaining() => Duration(
      milliseconds: (timeout.inMilliseconds - watch.elapsedMilliseconds).clamp(
        1,
        timeout.inMilliseconds,
      ),
    );
    try {
      cancellation.check();
      final address = InternetAddress(target.address.canonical);
      if (network.vpn &&
          (!network.direct || address.type != InternetAddressType.IPv4)) {
        // Through the VPN this would describe the VPN, never this network.
        return IpProbeResult(IpProbeStatus.unavailable, 0);
      }
      task = await cancellation.bind<ConnectionTask<Socket>>(
        Socket.startConnect(
          address,
          target.port,
          sourceAddress: network.vpn ? network.directSource : null,
        ).timeout(remaining()),
      );
      _pending.add(task);
      unawaited(
        task.socket.then((value) {
          if (finished || cancellation.isCancelled) value.destroy();
        }, onError: (Object _) {}),
      );
      socket = await cancellation.bind<Socket>(
        task.socket.timeout(remaining()),
      );
      _pending.remove(task);
      _sockets.add(socket);
      cancellation.check();
      if (target.kind == IpProbeKind.tls) {
        final plain = socket;
        final secure = SecureSocket.secure(plain, host: target.host);
        // If cancellation wins during handshake, close any late socket as well.
        unawaited(
          secure.then((value) {
            if (finished || cancellation.isCancelled) value.destroy();
          }, onError: (Object _) {}),
        );
        socket = await cancellation.bind<SecureSocket>(
          secure.timeout(remaining()),
        );
        _sockets.remove(plain);
        _sockets.add(socket);
      } else if (target.kind == IpProbeKind.ssh ||
          target.kind == IpProbeKind.http) {
        if (target.kind == IpProbeKind.http) {
          socket.add(
            ascii.encode(
              'GET /0 HTTP/1.0\r\nHost: ${target.host.isEmpty ? target.address.canonical : target.host}\r\nConnection: close\r\n\r\n',
            ),
          );
          await cancellation.bind(socket.flush().timeout(remaining()));
        }
        final bytes = <int>[];
        final done = Completer<bool>();
        final subscription = socket.listen(
          (chunk) {
            bytes.addAll(chunk.take((8192 - bytes.length).clamp(0, 8192)));
            final text = latin1.decode(bytes);
            final valid = target.kind == IpProbeKind.ssh
                ? RegExp(r'(^|\n)SSH-(2\.0|1\.99)-[^\r\n]+\r?\n').hasMatch(text)
                : RegExp(r'^HTTP/1\.[01] 200[ \r\n]').hasMatch(text);
            if (!done.isCompleted &&
                (valid ||
                    bytes.length >= 8192 ||
                    target.kind == IpProbeKind.http && text.contains('\n'))) {
              done.complete(valid);
            }
          },
          onError: (Object error) {
            if (!done.isCompleted) done.completeError(error);
          },
          onDone: () {
            if (!done.isCompleted) done.complete(false);
          },
        );
        try {
          if (!await cancellation.bind(done.future.timeout(remaining()))) {
            return IpProbeResult(
              IpProbeStatus.protocolError,
              watch.elapsedMilliseconds,
            );
          }
        } finally {
          await subscription.cancel();
        }
      }
      status = IpProbeStatus.reachable;
    } on TimeoutException {
      status = IpProbeStatus.timeout;
    } on HandshakeException {
      status = IpProbeStatus.tlsError;
    } on SocketException catch (e) {
      status = const {61, 111, 10061}.contains(e.osError?.errorCode)
          ? IpProbeStatus.refused
          : IpProbeStatus.unavailable;
    } finally {
      finished = true;
      if (task != null) {
        task.cancel();
        _pending.remove(task);
      }
      if (socket != null) {
        socket.destroy();
        _sockets.remove(socket);
      }
    }
    cancellation.check();
    return IpProbeResult(status, watch.elapsedMilliseconds);
  }

  @override
  Future<void> cancel() async {
    for (final task in _pending.toList()) {
      task.cancel();
    }
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _pending.clear();
    _sockets.clear();
  }
}
