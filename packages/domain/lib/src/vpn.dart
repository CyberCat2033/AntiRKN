import 'dart:convert';
import 'dart:math';
import 'network/ip_address.dart';
import 'vless_contract.g.dart';

String newVpnId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

final class VpnUser {
  VpnUser({
    required this.id,
    required this.login,
    required this.name,
    this.enabled = true,
  }) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(login) ||
        name.isEmpty ||
        name.length > 80 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException('vpn_user_invalid');
    }
  }
  factory VpnUser.fromJson(Map<String, dynamic> j) => VpnUser(
    id: j['id'] as String,
    login: j['login'] as String,
    name: j['name'] as String,
    enabled: j['enabled'] as bool,
  );
  final String id, login, name;
  final bool enabled;
  Map<String, Object?> toJson() => {
    'id': id,
    'login': login,
    'name': name,
    'enabled': enabled,
  };
}

final class VlessInbound {
  VlessInbound({required this.serverId, required Map<String, Object?> spec})
    : spec = Map.unmodifiable(spec) {
    final rule =
        ((vlessSchema['properties'] as Map)['resources'] as Map)['items']
            as Map;
    validateVlessSchema(spec, rule);
    final listen = IpAddress.parse(spec['listen'] as String);
    if (listen.category == IpCategory.multicast ||
        ['0.0.0.0', '::'].contains(spec['endpoint'])) {
      throw const FormatException('vless_invalid');
    }
    if (transport == 'raw' && security != 'reality') {
      throw const FormatException('vless_invalid');
    }
    if (security == 'tls' &&
        (spec['certificate'] == '' || spec['certificateKey'] == '')) {
      throw const FormatException('vless_invalid');
    }
    if (transport == 'xhttp' &&
        security == 'reality' &&
        !['auto', 'stream-one'].contains(spec['mode'])) {
      throw const FormatException('vless_invalid');
    }
    final target = Uri.tryParse('http://${spec['target']}');
    if (target == null ||
        target.host.isEmpty ||
        !target.hasPort ||
        target.port < 1 ||
        target.port > 65535) {
      throw const FormatException('vless_invalid');
    }
    if (deleted && enabled) throw const FormatException('vless_invalid');
  }
  factory VlessInbound.fromJson(Map<String, dynamic> j) => VlessInbound(
    serverId: j['serverId'] as String,
    spec: Map<String, Object?>.from(j['spec'] as Map),
  );
  static Map<String, Object?> defaults() => {
    'id': newVpnId(),
    'name': 'VLESS',
    'enabled': true,
    'deleted': false,
    'listen': '0.0.0.0',
    'port': 443,
    'endpoint': '',
    'externalPort': 443,
    'transport': 'raw',
    'security': 'reality',
    'sni': '',
    'target': '',
    'path': '/',
    'host': '',
    'mode': 'auto',
    'certificate': '',
    'certificateKey': '',
    'region': '',
  };
  final String serverId;
  final Map<String, Object?> spec;
  String get id => spec['id'] as String;
  String get name => spec['name'] as String;
  String get transport => spec['transport'] as String;
  String get security => spec['security'] as String;
  bool get enabled => spec['enabled'] as bool;
  bool get deleted => spec['deleted'] as bool;
  Map<String, Object?> toJson() => {'serverId': serverId, 'spec': spec};
}

/// One atomic encrypted document contains desired entities, observed bindings,
/// and pending server operations. Revisions prevent concurrent writer loss.
final class VpnWorkspace {
  VpnWorkspace({
    required this.id,
    List<VpnUser> users = const [],
    List<VlessInbound> inbounds = const [],
    Map<String, Map<String, dynamic>> servers = const {},
    Map<String, Map<String, dynamic>> profiles = const {},
  }) : users = List.unmodifiable(users),
       inbounds = List.unmodifiable(inbounds),
       profiles = Map.unmodifiable(profiles),
       servers = Map.unmodifiable(
         servers.map(
           (k, v) => MapEntry(k, Map<String, dynamic>.unmodifiable(v)),
         ),
       ) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        users.length > 1000 ||
        users.map((u) => u.id).toSet().length != users.length ||
        users.map((u) => u.login.toLowerCase()).toSet().length !=
            users.length ||
        inbounds.map((i) => i.id).toSet().length != inbounds.length) {
      throw const FormatException('vpn_duplicate');
    }
  }
  factory VpnWorkspace.empty() => VpnWorkspace(id: newVpnId());
  factory VpnWorkspace.decode(String raw) {
    final j = jsonDecode(raw) as Map;
    if (j['version'] != 1) throw const FormatException('vpn_version');
    return VpnWorkspace(
      id: j['id'] as String,
      users: (j['users'] as List)
          .map((e) => VpnUser.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      inbounds: (j['inbounds'] as List)
          .map(
            (e) => VlessInbound.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
      profiles: (j['profiles'] as Map? ?? {}).map(
        (k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
      ),
      servers: (j['servers'] as Map).map(
        (k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
      ),
    );
  }
  final String id;
  final List<VpnUser> users;
  final List<VlessInbound> inbounds;
  final Map<String, Map<String, dynamic>> servers, profiles;
  String encode() => jsonEncode({
    'version': 1,
    'id': id,
    'users': users.map((e) => e.toJson()).toList(),
    'inbounds': inbounds.map((e) => e.toJson()).toList(),
    'servers': servers,
    'profiles': profiles,
  });
  VpnWorkspace copy({
    List<VpnUser>? users,
    List<VlessInbound>? inbounds,
    Map<String, Map<String, dynamic>>? servers,
    Map<String, Map<String, dynamic>>? profiles,
  }) => VpnWorkspace(
    id: id,
    users: users ?? this.users,
    inbounds: inbounds ?? this.inbounds,
    servers: servers ?? this.servers,
    profiles: profiles ?? this.profiles,
  );
  Map<String, Object?> desired(String serverId, String panelId) {
    final resources = inbounds.where((i) => i.serverId == serverId).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final clients = users.toList()..sort((a, b) => a.id.compareTo(b.id));
    final result = <String, Object?>{
      'version': 1,
      'workspaceId': id,
      'panelId': panelId,
      'resources': resources.map((r) => r.spec).toList(),
      'users': clients
          .map((u) => <String, Object?>{'id': u.id, 'enabled': u.enabled})
          .toList(),
    };
    validateVlessSchema(result);
    return result;
  }

  Set<String> get serverIds => inbounds.map((i) => i.serverId).toSet();
  @override
  String toString() => 'VpnWorkspace(<redacted>)';
}

final class VpnStoredDocument {
  const VpnStoredDocument(this.source, this.revision);
  final String? source;
  final int revision;
}

abstract interface class VpnRepository {
  Future<VpnStoredDocument> readVpn();
  Future<int> writeVpn(String source, {required int expectedRevision});
}

abstract interface class ProfileExporter {
  Future<bool> save(String name, String source);
}
