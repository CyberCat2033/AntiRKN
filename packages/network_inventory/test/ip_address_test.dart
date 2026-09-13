import 'dart:io';
import 'dart:math';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canonical IPv6 compression, ties and embedded IPv4', () {
    for (final entry in {
      '0:0:0:0:0:0:0:0': '::',
      '0:0:0:0:0:0:0:1': '::1',
      '2001:0DB8:0:0:1:0:0:1': '2001:db8::1:0:0:1',
      '1:2:3:4:5:6:7:0': '1:2:3:4:5:6:7:0',
      '1:0:0:2:0:0:3:4': '1::2:0:0:3:4',
      '1:2:3:4:0:0:0:0': '1:2:3:4::',
      '::ffff:192.0.2.1': '::ffff:c000:201',
    }.entries) {
      final parsed = IpAddress.parse(entry.key);
      expect(parsed.canonical, entry.value);
      expect(parsed, IpAddress.parse(entry.value));
      expect(parsed.hashCode, IpAddress.parse(entry.value).hashCode);
    }
  });

  test('strict numeric IP boundary rejects ambiguous or decorated values', () {
    for (final invalid in [
      '',
      '1.2.3',
      '1.2.3.4.5',
      '256.1.2.3',
      '-1.0.0.0',
      '01.2.3.4',
      '0x7f.0.0.1',
      '2130706433',
      '1.2.3.4\n',
      ' 1.2.3.4',
      '1.2.3.4/24',
      'example.com',
      '[::1]',
      'fe80::1%eth0',
      ':1',
      '1:',
      '1::2::3',
      ':::1',
      '12345::',
      'gggg::',
      '1:2:3:4:5:6:7',
      '1:2:3:4:5:6:7:8:9',
      '1:2:3:4:5:6:7::8',
      '::ffff:192.0.2.999',
      '::ffff:192.00.2.1',
    ]) {
      expect(IpAddress.tryParse(invalid), isNull, reason: invalid);
    }
  });

  test(
    'numeric parsing matches the platform parser across seeded addresses',
    () {
      final random = Random(812);
      for (var i = 0; i < 512; i++) {
        for (final length in [4, 16]) {
          final bytes = List.generate(length, (_) => random.nextInt(256));
          final input = length == 4
              ? bytes.join('.')
              : [
                  for (var k = 0; k < 16; k += 2)
                    ((bytes[k] << 8) | bytes[k + 1]).toRadixString(16),
                ].join(':');
          final parsed = IpAddress.parse(input);
          expect(parsed.bytes, InternetAddress(input).rawAddress);
          expect(IpAddress.parse(parsed.canonical).bytes, bytes);
        }
      }
    },
  );

  test('special ranges never become public merely because scope is global', () {
    for (final entry in {
      '0.0.0.0': IpCategory.unspecified,
      '0.1.2.3': IpCategory.special,
      '127.255.255.254': IpCategory.loopback,
      '10.1.2.3': IpCategory.private,
      '172.16.0.1': IpCategory.private,
      '172.31.255.255': IpCategory.private,
      '172.32.0.1': IpCategory.publicUnicast,
      '192.168.2.1': IpCategory.private,
      '100.64.0.1': IpCategory.shared,
      '100.127.255.254': IpCategory.shared,
      '100.128.0.1': IpCategory.publicUnicast,
      '169.254.1.2': IpCategory.linkLocal,
      '192.0.2.3': IpCategory.documentation,
      '198.51.100.9': IpCategory.documentation,
      '203.0.113.9': IpCategory.documentation,
      '192.0.0.9': IpCategory.special,
      '192.31.196.1': IpCategory.special,
      '192.52.193.1': IpCategory.special,
      '192.88.99.2': IpCategory.special,
      '192.175.48.1': IpCategory.special,
      '198.19.255.255': IpCategory.special,
      '224.0.0.1': IpCategory.multicast,
      '255.255.255.255': IpCategory.special,
      '93.184.215.14': IpCategory.publicUnicast,
      '::': IpCategory.unspecified,
      '::1': IpCategory.loopback,
      '::ffff:8.8.8.8': IpCategory.special,
      '64:ff9b::808:808': IpCategory.special,
      '100:0:0:1::1': IpCategory.special,
      'fc00::1': IpCategory.private,
      'fdff::1': IpCategory.private,
      'fe80::1': IpCategory.linkLocal,
      'febf::1': IpCategory.linkLocal,
      'ff02::1': IpCategory.multicast,
      '2001:db8::1': IpCategory.documentation,
      '3fff:fff::1': IpCategory.documentation,
      '2001:2::1': IpCategory.special,
      '2002:808:808::1': IpCategory.special,
      '2620:4f:8000::1': IpCategory.special,
      '4000::1': IpCategory.special,
      '2a01:4f8::1': IpCategory.publicUnicast,
    }.entries) {
      expect(
        IpAddress.parse(entry.key).category,
        entry.value,
        reason: entry.key,
      );
    }
  });

  test('prefix matching and ordering include family and full address', () {
    expect(IpAddress.parse('10.0.0.1').inSubnet('10.0.0.0', 32), isFalse);
    expect(IpAddress.parse('10.0.0.1').inSubnet('10.0.0.0', 24), isTrue);
    expect(IpAddress.parse('::1').inSubnet('0.0.0.0', 0), isFalse);
    final addresses = [
      '::1',
      '10.0.0.10',
      '10.0.0.2',
    ].map(IpAddress.parse).toList()..sort();
    expect(addresses.map((a) => a.canonical), ['10.0.0.2', '10.0.0.10', '::1']);
  });
}
