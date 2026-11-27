/// Per-client traffic counted on the servers by the runner (`traffic_read`).
///
/// The runner keeps a lifetime sum and the sums of the last twelve calendar
/// months (UTC) per protocol resource and client; this side only reads,
/// caches and adds them up. "down" is what the client downloaded.
library;

final class TrafficUsage {
  const TrafficUsage(this.down, this.up);
  static const zero = TrafficUsage(0, 0);
  final int down, up;
  TrafficUsage operator +(TrafficUsage other) =>
      TrafficUsage(down + other.down, up + other.up);
  bool get isZero => down == 0 && up == 0;
  @override
  bool operator ==(Object other) =>
      other is TrafficUsage && other.down == down && other.up == up;
  @override
  int get hashCode => Object.hash(down, up);
}

/// How the runner could read one resource this time.
enum TrafficSourceState {
  ok,

  /// Counters unreadable now (service down, interface missing).
  unavailable,

  /// The resource is turned off.
  disabled,

  /// The resource does not count per client (TrustTunnel metrics off).
  off,

  /// The resource no longer exists; its counted traffic remains.
  gone,
}

final class TrafficCounters {
  const TrafficCounters({required this.total, required this.months});
  final TrafficUsage total;

  /// `YYYY-MM` (UTC) to that month's traffic.
  final Map<String, TrafficUsage> months;
}

final class TrafficResourceReading {
  const TrafficResourceReading({
    required this.protocol,
    required this.id,
    required this.state,
    required this.users,
  });
  final String protocol, id;
  final TrafficSourceState state;
  final Map<String, TrafficCounters> users;
}

int _count(Object? value) {
  if (value is! int || value < 0) throw const FormatException('traffic');
  return value;
}

final _month = RegExp(r'^\d{4}-(0[1-9]|1[0-2])$');
const _protocols = {'vless', 'awg', 'tt'};

/// One server's answer, as read or as cached on this device.
final class ServerTrafficReading {
  const ServerTrafficReading({required this.readAt, required this.resources});

  /// The `traffic` object of a `traffic_read` response; also the cache form.
  factory ServerTrafficReading.fromRunner(Map<String, dynamic> json) {
    final readAt = _count(json['readAt']);
    final resources = <TrafficResourceReading>[];
    for (final raw in json['resources'] as List? ?? const []) {
      final r = Map<String, dynamic>.from(raw as Map);
      final protocol = r['protocol'], id = r['id'];
      if (!_protocols.contains(protocol) || id is! String || id.isEmpty) {
        throw const FormatException('traffic');
      }
      final state = TrafficSourceState.values
          .where((s) => s.name == r['state'])
          .firstOrNull;
      if (state == null) throw const FormatException('traffic');
      final users = <String, TrafficCounters>{};
      for (final rawUser in r['users'] as List? ?? const []) {
        final u = Map<String, dynamic>.from(rawUser as Map);
        final uid = u['id'];
        if (uid is! String || uid.isEmpty) {
          throw const FormatException('traffic');
        }
        final months = <String, TrafficUsage>{};
        for (final rawMonth in u['months'] as List? ?? const []) {
          final m = Map<String, dynamic>.from(rawMonth as Map);
          final key = m['month'];
          if (key is! String || !_month.hasMatch(key)) {
            throw const FormatException('traffic');
          }
          months[key] = TrafficUsage(_count(m['down']), _count(m['up']));
        }
        users[uid] = TrafficCounters(
          total: TrafficUsage(_count(u['down']), _count(u['up'])),
          months: months,
        );
      }
      resources.add(
        TrafficResourceReading(
          protocol: protocol as String,
          id: id,
          state: state,
          users: users,
        ),
      );
    }
    return ServerTrafficReading(
      readAt: DateTime.fromMillisecondsSinceEpoch(readAt * 1000, isUtc: true),
      resources: resources,
    );
  }

  final DateTime readAt;
  final List<TrafficResourceReading> resources;

  /// Answers for several resource workspaces of one server read together.
  ServerTrafficReading merge(ServerTrafficReading other) {
    final seen = {for (final r in resources) '${r.protocol}/${r.id}'};
    return ServerTrafficReading(
      readAt: readAt.isBefore(other.readAt) ? readAt : other.readAt,
      resources: [
        ...resources,
        ...other.resources.where(
          (r) => !seen.contains('${r.protocol}/${r.id}'),
        ),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'readAt': readAt.millisecondsSinceEpoch ~/ 1000,
    'resources': [
      for (final r in resources)
        {
          'protocol': r.protocol,
          'id': r.id,
          'state': r.state.name,
          'users': [
            for (final e in r.users.entries)
              {
                'id': e.key,
                'down': e.value.total.down,
                'up': e.value.total.up,
                'months': [
                  for (final m in e.value.months.entries)
                    {'month': m.key, 'down': m.value.down, 'up': m.value.up},
                ],
              },
          ],
        },
    ],
  };
}

/// `YYYY-MM` of [at] in UTC, as the runner names months.
String trafficMonth(DateTime at) {
  final utc = at.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}';
}

/// The [count] months up to the one of [now], oldest first.
List<String> trafficMonths(DateTime now, {int count = 12}) {
  final utc = now.toUtc();
  return [
    for (var i = count - 1; i >= 0; i--)
      trafficMonth(DateTime.utc(utc.year, utc.month - i)),
  ];
}

/// One protocol of one server, all its resources together.
final class ProtocolTraffic {
  const ProtocolTraffic({
    required this.protocol,
    required this.total,
    required this.months,
    required this.state,
  });
  final String protocol;
  final TrafficUsage total;
  final Map<String, TrafficUsage> months;

  /// `ok` when any resource counted now; otherwise the most telling state.
  final TrafficSourceState state;

  TrafficUsage usage(String? month) =>
      month == null ? total : months[month] ?? TrafficUsage.zero;
}

final class ServerClientTraffic {
  const ServerClientTraffic({
    required this.serverId,
    required this.readAt,
    required this.protocols,
  });
  final String serverId;
  final DateTime readAt;
  final List<ProtocolTraffic> protocols;

  TrafficUsage usage(String? month) =>
      protocols.fold(TrafficUsage.zero, (a, p) => a + p.usage(month));
}

/// One client's traffic over every server read so far.
final class ClientTrafficSummary {
  const ClientTrafficSummary({required this.servers});

  factory ClientTrafficSummary.of(
    String userId,
    Map<String, ServerTrafficReading> readings,
  ) {
    const order = ['vless', 'awg', 'tt'];
    final servers = <ServerClientTraffic>[];
    for (final entry in readings.entries) {
      final byProtocol = <String, List<TrafficResourceReading>>{};
      for (final r in entry.value.resources) {
        // A resource without this client counts for it only when it says
        // why nothing can be counted there.
        if (r.users.containsKey(userId) ||
            r.state == TrafficSourceState.off ||
            r.state == TrafficSourceState.unavailable) {
          byProtocol.putIfAbsent(r.protocol, () => []).add(r);
        }
      }
      final protocols = <ProtocolTraffic>[];
      for (final protocol in order.where(byProtocol.containsKey)) {
        final resources = byProtocol[protocol]!;
        var total = TrafficUsage.zero;
        final months = <String, TrafficUsage>{};
        for (final r in resources) {
          final c = r.users[userId];
          if (c == null) continue;
          total += c.total;
          for (final m in c.months.entries) {
            months[m.key] = (months[m.key] ?? TrafficUsage.zero) + m.value;
          }
        }
        final states = resources.map((r) => r.state).toSet();
        final state = states.contains(TrafficSourceState.ok)
            ? TrafficSourceState.ok
            : states.contains(TrafficSourceState.unavailable)
            ? TrafficSourceState.unavailable
            : states.contains(TrafficSourceState.off)
            ? TrafficSourceState.off
            : states.first;
        protocols.add(
          ProtocolTraffic(
            protocol: protocol,
            total: total,
            months: months,
            state: state,
          ),
        );
      }
      if (protocols.isNotEmpty) {
        servers.add(
          ServerClientTraffic(
            serverId: entry.key,
            readAt: entry.value.readAt,
            protocols: protocols,
          ),
        );
      }
    }
    return ClientTrafficSummary(servers: servers);
  }

  final List<ServerClientTraffic> servers;

  bool get isEmpty => servers.isEmpty;

  /// [month] (`YYYY-MM`) or, when null, all the time.
  TrafficUsage usage(String? month) =>
      servers.fold(TrafficUsage.zero, (a, s) => a + s.usage(month));

  /// The oldest reading the figures rest on.
  DateTime? get readAt => servers.isEmpty
      ? null
      : servers.map((s) => s.readAt).reduce((a, b) => a.isBefore(b) ? a : b);
}
