import 'dart:async';
import 'ssh.dart';
import 'network/ip_address.dart';
import 'network/ip_diagnostics.dart';

enum CoreTrafficStatus { success, failed, notTested, cancelled }

final class CoreTrafficCheck {
  const CoreTrafficCheck({
    required this.status,
    required this.code,
    this.tcp = false,
    this.udp = false,
    this.udpTested = false,
    this.milliseconds = 0,
  });
  final CoreTrafficStatus status;
  final String code;
  final bool tcp, udp, udpTested;
  final int milliseconds;
}

abstract interface class CoreProbeTransport {
  /// null runs the same fixed targets directly as controls, never a fallback.
  Future<CoreTrafficCheck> probe(
    Map<String, Object?>? proxy,
    CancellationToken cancellation, {
    required bool udp,
  });
}

enum ConnectionCheckStatus {
  working,
  failed,
  networkProblem,
  notTested,
  cancelled,
}

final class ConnectionCheck {
  const ConnectionCheck({
    required this.status,
    required this.code,
    required this.at,
    this.traffic,
    this.networkIdentity = '',
  });
  final ConnectionCheckStatus status;
  final String code, networkIdentity;
  final DateTime at;
  final CoreTrafficCheck? traffic;
}

/// Shared policy for automatic checks, manual checks and upgrade comparisons.
final class ConnectionProbeEngine {
  ConnectionProbeEngine({
    required this.core,
    required this.network,
    required this.controls,
  });
  final CoreProbeTransport core;
  final IpProbeTransport network;
  final List<IpControl> controls;
  bool _running = false;
  final _waitQueue = <Completer<void>>[];
  Future<ConnectionCheck> check(
    Map<String, Object?> proxy,
    CancellationToken token, {
    bool udp = true,
  }) async {
    var identity = '';
    ConnectionCheck result(
      ConnectionCheckStatus status,
      String code, [
      CoreTrafficCheck? traffic,
    ]) => ConnectionCheck(
      status: status,
      code: code,
      traffic: traffic,
      networkIdentity: identity,
      at: DateTime.now().toUtc(),
    );
    if (_running) {
      final wait = Completer<void>();
      _waitQueue.add(wait);
      try {
        await token.bind(wait.future);
      } catch (_) {
        _waitQueue.remove(wait);
        rethrow;
      }
    }
    _running = true;
    final deadline = Timer(const Duration(seconds: 65), token.cancel);
    try {
      final before = await token.bind(network.network());
      identity = before.identity;
      if (before.vpn) {
        return result(ConnectionCheckStatus.networkProblem, 'vpn_active');
      }
      Future<void> sameNetwork() async {
        token.check();
        final current = await token.bind(network.network());
        if (current.vpn || current.identity != identity) {
          throw const FormatException('network_changed');
        }
      }

      Future<bool> healthy() async {
        final targets = controls
            .where((c) => c.target.address.family == IpFamily.ipv4)
            .take(10)
            .toList();
        if (targets.length < 10) return false;
        var reached = 0;
        for (var i = 0; i < targets.length; i += 3) {
          await sameNetwork();
          final values = await Future.wait(
            targets
                .skip(i)
                .take(3)
                .map(
                  (control) => network.probe(
                    control.target,
                    before,
                    const Duration(seconds: 2),
                    token,
                  ),
                ),
          );
          reached += values.where((v) => v.reachable).length;
        }
        return reached >= 9;
      }

      if (!await healthy()) {
        return result(ConnectionCheckStatus.networkProblem, 'control_failed');
      }
      await sameNetwork();
      var traffic = await core.probe(proxy, token, udp: udp);
      await sameNetwork();
      if (traffic.status == CoreTrafficStatus.success) {
        return result(ConnectionCheckStatus.working, 'connected', traffic);
      }
      if (traffic.status == CoreTrafficStatus.notTested) {
        return result(ConnectionCheckStatus.notTested, traffic.code, traffic);
      }
      if (traffic.status == CoreTrafficStatus.cancelled) {
        return result(ConnectionCheckStatus.cancelled, 'cancelled', traffic);
      }
      // Only an independently healthy network and reachable identical destinations
      // allow a repeated proxy failure to be offered for reconfiguration.
      if (!await healthy()) {
        return result(
          ConnectionCheckStatus.networkProblem,
          'control_failed',
          traffic,
        );
      }
      final control = await core.probe(null, token, udp: udp);
      await sameNetwork();
      if (control.status != CoreTrafficStatus.success) {
        return result(
          ConnectionCheckStatus.networkProblem,
          'target_unavailable',
          traffic,
        );
      }
      traffic = await core.probe(proxy, token, udp: udp);
      await sameNetwork();
      if (traffic.status == CoreTrafficStatus.success) {
        return result(ConnectionCheckStatus.working, 'connected', traffic);
      }
      return result(
        traffic.status == CoreTrafficStatus.failed
            ? ConnectionCheckStatus.failed
            : ConnectionCheckStatus.notTested,
        traffic.code,
        traffic,
      );
    } on FormatException catch (error) {
      return result(
        ConnectionCheckStatus.networkProblem,
        error.message == 'network_changed'
            ? 'network_changed'
            : 'control_failed',
      );
    } catch (_) {
      return result(
        token.isCancelled
            ? ConnectionCheckStatus.cancelled
            : ConnectionCheckStatus.notTested,
        token.isCancelled ? 'cancelled' : 'runtime_unavailable',
      );
    } finally {
      deadline.cancel();
      _running = false;
      if (_waitQueue.isNotEmpty) {
        _waitQueue.removeAt(0).complete();
      }
    }
  }
}
