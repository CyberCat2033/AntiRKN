import 'package:antirkn_domain/antirkn_domain.dart';
import 'prepared_proxy.dart';
import 'proxy_name.dart';

PreparedProxy adoptedProxy(
  VpnWorkspace workspace,
  String userId,
  Map spec,
  Map observation,
  Map client,
  Map<String, String> serverNames,
) {
  final base = Map<String, Object?>.from(observation['proxy'] as Map);
  final reality = base['reality-opts'];
  if (reality is Map) {
    base['reality-opts'] = <String, Object?>{
      ...Map<String, Object?>.from(reality),
      // Xray 26.7+ accepts the hybrid key share and some REALITY targets now
      // require it. Mihomo otherwise removes it from the ClientHello.
      'support-x25519mlkem768': true,
    };
  }
  final proxy = PreparedProxy(
    imported: true,
    identity: AccessIdentity(
      id: spec['id'] as String,
      userId: userId,
      active: true,
      confirmed: true,
    ),
    fields: {
      ...base,
      'name': clientProxyName(
        workspace,
        userId,
        spec['id'] as String,
        serverNames,
      ),
      'server': spec['endpoint'],
      'port': spec['externalPort'],
      if (base['type'] == 'vless') 'uuid': client['uuid'],
      if (base['type'] == 'trusttunnel') ...{
        'username': client['username'],
        'password': client['password'],
      },
      if (base['type'] == 'wireguard') ...{
        'ip': client['address'],
        if (client['address6'] != null && client['address6'] != '')
          'ipv6': client['address6'],
        'private-key': client['privateKey'],
        'pre-shared-key': client['presharedKey'],
        'persistent-keepalive': 0,
      },
    },
  );
  proxy.validate();
  return proxy;
}
