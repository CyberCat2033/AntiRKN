import 'dart:convert';

import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:test/test.dart';

/// Reads a `tt://?` link back into its TLV entries (DEEP_LINK.md).
Map<int, List<List<int>>> decodeTt(String link) {
  expect(link, startsWith('tt://?'));
  var raw = link.substring(6);
  raw += '=' * ((4 - raw.length % 4) % 4);
  final bytes = base64Url.decode(raw);
  var at = 0;
  int varint() {
    final first = bytes[at];
    final size = 1 << (first >> 6);
    var value = first & 0x3f;
    for (var i = 1; i < size; i++) {
      value = (value << 8) | bytes[at + i];
    }
    at += size;
    return value;
  }

  final result = <int, List<List<int>>>{};
  while (at < bytes.length) {
    final tag = varint(), length = varint();
    result.putIfAbsent(tag, () => []).add(bytes.sublist(at, at + length));
    at += length;
  }
  return result;
}

void main() {
  test('VLESS Reality link carries the access and the Reality keys', () {
    final link = proxyShareLink({
      'type': 'vless',
      'server': 'vpn.example.com',
      'port': 443,
      'uuid': '11111111-2222-4333-8444-555555555555',
      'tls': true,
      'servername': 'www.example.org',
      'client-fingerprint': 'chrome',
      'network': 'tcp',
      'flow': 'xtls-rprx-vision',
      'reality-opts': {'public-key': 'PUB', 'short-id': 'ab12'},
    }, 'Server · Main · test')!;
    expect(link.kind, ShareLinkKind.vless);
    final uri = Uri.parse(link.text);
    expect(uri.scheme, 'vless');
    expect(uri.userInfo, '11111111-2222-4333-8444-555555555555');
    expect(uri.host, 'vpn.example.com');
    expect(uri.port, 443);
    expect(uri.queryParameters, {
      'encryption': 'none',
      'type': 'tcp',
      'security': 'reality',
      'sni': 'www.example.org',
      'fp': 'chrome',
      'flow': 'xtls-rprx-vision',
      'pbk': 'PUB',
      'sid': 'ab12',
    });
    expect(Uri.decodeComponent(uri.fragment), 'Server · Main · test');
    expect('$link', isNot(contains('1111')));
  });

  test('VLESS XHTTP link names extra options as Xray does', () {
    final link = proxyShareLink({
      'type': 'vless',
      'server': '2001:db8::1',
      'port': 8443,
      'uuid': '11111111-2222-4333-8444-555555555555',
      'tls': true,
      'servername': 'cdn.example.org',
      'network': 'xhttp',
      'xhttp-opts': {
        'path': '/x',
        'host': 'cdn.example.org',
        'mode': 'auto',
        'no-grpc-header': true,
        'reuse-settings': {'max-concurrency': '16-32'},
      },
    }, 'n')!;
    final uri = Uri.parse(link.text);
    expect(uri.host, '2001:db8::1');
    expect(uri.queryParameters['security'], 'tls');
    expect(uri.queryParameters['path'], '/x');
    expect(uri.queryParameters['mode'], 'auto');
    expect(jsonDecode(uri.queryParameters['extra']!), {
      'noGRPCHeader': true,
      'xmux': {'maxConcurrency': '16-32'},
    });
  });

  test('VLESS option without an Xray name gives no link', () {
    expect(
      proxyShareLink({
        'type': 'vless',
        'server': 'a.example',
        'port': 1,
        'uuid': 'u',
        'tls': true,
        'network': 'xhttp',
        'xhttp-opts': {'path': '/', 'unknown-option': 1},
      }, 'n'),
      isNull,
    );
    expect(
      proxyShareLink({
        'type': 'vless',
        'server': 'a.example',
        'port': 1,
        'uuid': 'u',
        'network': 'h2',
      }, 'n'),
      isNull,
    );
  });

  test('AmneziaWG config has the keys awg reads', () {
    final link = proxyShareLink({
      'type': 'wireguard',
      'server': '203.0.113.5',
      'port': 51820,
      'ip': '10.8.0.2',
      'ipv6': 'fd00::2',
      'private-key': 'PRIV',
      'public-key': 'PUB',
      'pre-shared-key': 'PSK',
      'mtu': 1280,
      'persistent-keepalive': 0,
      'allowed-ips': ['0.0.0.0/0', '::/0'],
      'amnezia-wg-option': {
        'version': 3,
        'jc': 4,
        'jmin': 10,
        'random-trailers': true,
        'header-protection-key': 'HPK',
        'h1': '1',
      },
    }, 'Server · AWG · test')!;
    expect(link.kind, ShareLinkKind.awg);
    expect(
      link.text,
      '# Server · AWG · test\n'
      '[Interface]\n'
      'PrivateKey = PRIV\n'
      'Address = 10.8.0.2/32, fd00::2/128\n'
      'MTU = 1280\n'
      'Jc = 4\n'
      'Jmin = 10\n'
      'RandomTrailers = on\n'
      'HeaderProtectionKey = HPK\n'
      'H1 = 1\n'
      '\n'
      '[Peer]\n'
      'PublicKey = PUB\n'
      'PresharedKey = PSK\n'
      'Endpoint = 203.0.113.5:51820\n'
      'AllowedIPs = 0.0.0.0/0, ::/0\n',
    );
  });

  test('TrustTunnel deep link follows the TLV format', () {
    final link = proxyShareLink({
      'type': 'trusttunnel',
      'server': '198.51.100.7',
      'port': 443,
      'username': 'antirkn-test',
      'password': 'secret',
      'sni': 'tt.example.com',
      'quic': true,
    }, 'Server · TT · test')!;
    expect(link.kind, ShareLinkKind.trustTunnel);
    expect(link.text, isNot(contains('=')));
    final tlv = decodeTt(link.text);
    String text(int tag) => utf8.decode(tlv[tag]!.single);
    expect(tlv[0x00]!.single, [2]);
    expect(text(0x01), 'tt.example.com');
    expect(text(0x02), '198.51.100.7:443');
    expect(text(0x05), 'antirkn-test');
    expect(text(0x06), 'secret');
    expect(tlv[0x09]!.single, [0x02]);
    expect(text(0x0C), 'Server · TT · test');
  });

  test('a long TrustTunnel field uses a two-byte length', () {
    final link = proxyShareLink({
      'type': 'trusttunnel',
      'server': 'h.example',
      'port': 443,
      'username': 'u',
      'password': 'p' * 300,
      'sni': 'h.example',
      'quic': false,
    }, 'n')!;
    final tlv = decodeTt(link.text);
    expect(utf8.decode(tlv[0x06]!.single), 'p' * 300);
    expect(tlv[0x09]!.single, [0x01]);
  });
}
