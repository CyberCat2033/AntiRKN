import 'awg.dart';

/// Where a physical server is in its service mode.
///
/// `active`: the server is serviced; its resources are left out of client
/// profiles, no new client is provisioned on it and it does not hold up
/// publication or other servers. `returning`: the way back is in progress;
/// until every target's readback matches the current desired payload the
/// server stays out of profiles exactly as in `active`.
enum ServerServiceState { active, returning }

final _deviceId = RegExp(r'^[a-f0-9]{32}$');

/// Service mode of one physical server (catalog id; the same for its VLESS,
/// `awg/` and `tt/` targets). Kept apart from per-target server records so
/// operation carry-over and cache pruning of those records never touch it.
final class ServerServiceMode {
  ServerServiceMode({
    required this.state,
    required DateTime since,
    this.executor,
  }) : since = since.toUtc() {
    if (executor != null &&
        (state != ServerServiceState.returning ||
            !_deviceId.hasMatch(executor!))) {
      throw const FormatException('vpn_service_mode_invalid');
    }
  }

  factory ServerServiceMode.fromJson(Object? value) {
    if (value is! Map ||
        value.length != (value.containsKey('executor') ? 4 : 3) ||
        value['version'] != 1 ||
        value['state'] is! String ||
        value['since'] is! String ||
        value.containsKey('executor') && value['executor'] is! String) {
      throw const FormatException('vpn_service_mode_invalid');
    }
    final state = ServerServiceState.values
        .where((s) => s.name == value['state'])
        .firstOrNull;
    final raw = value['since'] as String;
    final since = raw.length > 40 ? null : DateTime.tryParse(raw);
    // One canonical UTC form: what [toJson] writes is the only thing read.
    if (state == null ||
        since == null ||
        !since.isUtc ||
        since.toIso8601String() != raw) {
      throw const FormatException('vpn_service_mode_invalid');
    }
    return ServerServiceMode(
      state: state,
      since: since,
      executor: value['executor'] as String?,
    );
  }

  final ServerServiceState state;

  /// When the server entered service mode, in UTC.
  final DateTime since;

  /// The device that applies the way back (`returning` only). Only it
  /// resumes and retries the exit; the others show it as in progress
  /// elsewhere until a person takes it over. Absent on a device without a
  /// workspace identity.
  final String? executor;

  /// [next] as a new state; [executor] is kept only while returning.
  ServerServiceMode withState(ServerServiceState next, {String? executor}) =>
      ServerServiceMode(
        state: next,
        since: since,
        executor: next == ServerServiceState.returning ? executor : null,
      );

  Map<String, Object?> toJson() => {
    'version': 1,
    'state': state.name,
    'since': since.toIso8601String(),
    'executor': ?executor,
  };

  @override
  bool operator ==(Object other) =>
      other is ServerServiceMode &&
      other.state == state &&
      other.since == since &&
      other.executor == executor;

  @override
  int get hashCode => Object.hash(state, since, executor);
}

/// A physical server id as service mode stores it: a catalog id, never a
/// target form (`awg/<id>`, `tt/<id>`).
bool validServiceModeServerId(String id) =>
    id.isNotEmpty &&
    id.length <= 256 &&
    vpnServerId(id) == id &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(id);
