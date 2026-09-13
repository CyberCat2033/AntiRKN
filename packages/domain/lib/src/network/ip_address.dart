enum IpFamily { ipv4, ipv6 }

enum AddressClass { external, internal }

enum IpCategory {
  publicUnicast,
  private,
  loopback,
  linkLocal,
  shared,
  documentation,
  multicast,
  unspecified,
  special,
}

/// A numeric address only. Zones, prefixes, brackets and DNS are separate fields.
final class IpAddress implements Comparable<IpAddress> {
  IpAddress._(this.family, List<int> bytes) : bytes = List.unmodifiable(bytes);

  final IpFamily family;
  final List<int> bytes;
  AddressClass get addressClass => category == IpCategory.publicUnicast
      ? AddressClass.external
      : AddressClass.internal;

  static IpAddress? tryParse(String value) {
    if (value.isEmpty || value.length > 45) return null;
    if (!value.contains(':')) {
      final octets = value.split('.');
      if (octets.length != 4) return null;
      final bytes = <int>[];
      for (final part in octets) {
        if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) return null;
        final byte = int.parse(part);
        if (byte > 255) return null;
        bytes.add(byte);
      }
      return IpAddress._(IpFamily.ipv4, bytes);
    }
    var input = value;
    if (input.contains('.')) {
      final split = input.lastIndexOf(':');
      final v4 = tryParse(input.substring(split + 1));
      if (v4 == null || v4.family != IpFamily.ipv4) return null;
      final b = v4.bytes;
      input =
          '${input.substring(0, split + 1)}'
          '${((b[0] << 8) | b[1]).toRadixString(16)}:'
          '${((b[2] << 8) | b[3]).toRadixString(16)}';
    }
    final sides = input.split('::');
    if (sides.length > 2) return null;
    List<int>? words(String side) {
      if (side.isEmpty) return [];
      final result = <int>[];
      for (final word in side.split(':')) {
        if (!RegExp(r'^[0-9a-fA-F]{1,4}$').hasMatch(word)) return null;
        result.add(int.parse(word, radix: 16));
      }
      return result;
    }

    final left = words(sides.first);
    final right = sides.length == 2 ? words(sides.last) : <int>[];
    if (left == null || right == null) return null;
    final missing = 8 - left.length - right.length;
    if (sides.length == 1 ? missing != 0 : missing < 1) return null;
    return IpAddress._(IpFamily.ipv6, [
      for (final word in [...left, ...List.filled(missing, 0), ...right]) ...[
        word >> 8,
        word & 255,
      ],
    ]);
  }

  factory IpAddress.parse(String value) =>
      tryParse(value) ?? (throw const FormatException('invalid_ip_address'));

  bool inSubnet(String prefix, int bits) {
    final network = IpAddress.parse(prefix);
    if (family != network.family || bits < 0 || bits > bytes.length * 8) {
      return false;
    }
    for (var i = 0; i < bits; i++) {
      final mask = 1 << (7 - i % 8);
      if (bytes[i ~/ 8] & mask != network.bytes[i ~/ 8] & mask) return false;
    }
    return true;
  }

  /// Conservative endpoint suggestions: IANA special-purpose ranges remain
  /// special even if some of their assignments are globally reachable.
  IpCategory get category {
    if (bytes.every((b) => b == 0)) return IpCategory.unspecified;
    final blocks = family == IpFamily.ipv4 ? _v4Blocks : _v6Blocks;
    for (final block in blocks) {
      if (inSubnet(block.$1, block.$2)) return block.$3;
    }
    if (family == IpFamily.ipv6 && !inSubnet('2000::', 3)) {
      return IpCategory.special;
    }
    return IpCategory.publicUnicast;
  }

  String get canonical {
    if (family == IpFamily.ipv4) return bytes.join('.');
    final words = [
      for (var i = 0; i < 16; i += 2) (bytes[i] << 8) | bytes[i + 1],
    ];
    var bestStart = -1;
    var bestLength = 1;
    for (var i = 0; i < words.length;) {
      if (words[i] != 0) {
        i++;
        continue;
      }
      final start = i;
      while (i < words.length && words[i] == 0) {
        i++;
      }
      if (i - start > bestLength) {
        bestStart = start;
        bestLength = i - start;
      }
    }
    final hex = words.map((w) => w.toRadixString(16)).toList();
    if (bestStart < 0) return hex.join(':');
    return '${hex.take(bestStart).join(':')}::'
        '${hex.skip(bestStart + bestLength).join(':')}';
  }

  @override
  int compareTo(IpAddress other) {
    if (family != other.family) {
      return family.index.compareTo(other.family.index);
    }
    for (var i = 0; i < bytes.length; i++) {
      final order = bytes[i].compareTo(other.bytes[i]);
      if (order != 0) return order;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) => other is IpAddress && compareTo(other) == 0;
  @override
  int get hashCode => Object.hash(family, Object.hashAll(bytes));
  @override
  String toString() => canonical;
}

const _v4Blocks = [
  ('127.0.0.0', 8, IpCategory.loopback),
  ('10.0.0.0', 8, IpCategory.private),
  ('172.16.0.0', 12, IpCategory.private),
  ('192.168.0.0', 16, IpCategory.private),
  ('169.254.0.0', 16, IpCategory.linkLocal),
  ('100.64.0.0', 10, IpCategory.shared),
  ('192.0.2.0', 24, IpCategory.documentation),
  ('198.51.100.0', 24, IpCategory.documentation),
  ('203.0.113.0', 24, IpCategory.documentation),
  ('224.0.0.0', 4, IpCategory.multicast),
  ('0.0.0.0', 8, IpCategory.special),
  ('192.0.0.0', 24, IpCategory.special),
  ('192.31.196.0', 24, IpCategory.special),
  ('192.52.193.0', 24, IpCategory.special),
  ('192.88.99.0', 24, IpCategory.special),
  ('192.175.48.0', 24, IpCategory.special),
  ('198.18.0.0', 15, IpCategory.special),
  ('240.0.0.0', 4, IpCategory.special),
];

const _v6Blocks = [
  ('::1', 128, IpCategory.loopback),
  ('fc00::', 7, IpCategory.private),
  ('fe80::', 10, IpCategory.linkLocal),
  ('2001:db8::', 32, IpCategory.documentation),
  ('3fff::', 20, IpCategory.documentation),
  ('ff00::', 8, IpCategory.multicast),
  ('2001::', 23, IpCategory.special),
  ('2002::', 16, IpCategory.special),
  ('2620:4f:8000::', 48, IpCategory.special),
];
