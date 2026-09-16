import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/services.dart';

class AndroidIpProbeTransport implements IpProbeTransport {
  static const channel = MethodChannel('org.antirkn/ip_diagnostics');
  @override
  Future<ProbeNetwork> network() async {
    final value = (await channel.invokeMapMethod<String, dynamic>('network'))!;
    return ProbeNetwork(
      value['identity'] as String,
      value['kind'] as String,
      vpn: value['vpn'] == true,
      bound: value['bound'] == true,
    );
  }

  @override
  Future<IpProbeResult> probe(
    IpProbeTarget target,
    ProbeNetwork network,
    Duration timeout,
    CancellationToken cancellation,
  ) async {
    cancellation.check();
    final value = (await cancellation.bind(
      channel.invokeMapMethod<String, dynamic>('probe', {
        ...target.toJson(),
        'network': network.identity,
        'timeout': timeout.inMilliseconds,
      }),
    ))!;
    cancellation.check();
    if (value['status'] == 'network_changed') {
      throw const FormatException('network_changed');
    }
    return IpProbeResult(
      IpProbeStatus.values.byName(value['status'] as String),
      value['ms'] as int,
    );
  }

  @override
  Future<void> cancel() => channel.invokeMethod<void>('cancel');
}
