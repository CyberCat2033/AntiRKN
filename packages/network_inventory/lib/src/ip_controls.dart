import 'package:antirkn_domain/antirkn_domain.dart';

/// Versioned public measurement targets; sources and date in docs/ip-diagnostics.md.
/// Anycast operators are not treated as proof of a foreign route.
List<IpControl> defaultIpControls() {
  final values = <IpControl>[];
  void dns(String provider, List<String> addresses) {
    for (final address in addresses) {
      values.add(IpControl(provider, provider, IpProbeTarget(address, 53)));
    }
  }

  dns('Cloudflare', [
    '1.1.1.1',
    '1.0.0.1',
    '2606:4700:4700::1111',
    '2606:4700:4700::1001',
  ]);
  dns('Google', [
    '8.8.8.8',
    '8.8.4.4',
    '2001:4860:4860::8888',
    '2001:4860:4860::8844',
  ]);
  dns('Quad9', ['9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9']);
  dns('AdGuard', [
    '94.140.14.14',
    '94.140.15.15',
    '2a10:50c0::ad1:ff',
    '2a10:50c0::ad2:ff',
  ]);
  dns('Yandex', ['77.88.8.8', '77.88.8.1']);
  for (final anchor in [
    ('DE', 'AS200567', 'de-57x-as200567', '185.70.144.118', '2a05:2a80:1::300'),
    (
      'NL',
      'AS1101',
      'nl-ams-as1101',
      '145.220.0.55',
      '2001:67c:6ec:201:145:220:0:55',
    ),
    ('US', 'AS140627', 'gu-pit-as140627', '103.151.64.31', '2406:1540::5'),
    ('RU', 'AS58067', 'ru-cta-as58067', '176.114.16.104', '2a0b:97c0:0:110::2'),
  ]) {
    for (final ip in [anchor.$4, anchor.$5]) {
      values.add(
        IpControl(
          'RIPE Atlas ${anchor.$1}',
          anchor.$2,
          IpProbeTarget(
            ip,
            80,
            kind: IpProbeKind.http,
            host: '${anchor.$3}.anchors.atlas.ripe.net',
          ),
          region: anchor.$1 == 'RU' ? 'ru' : 'foreign',
        ),
      );
    }
  }
  return List.unmodifiable(values);
}
