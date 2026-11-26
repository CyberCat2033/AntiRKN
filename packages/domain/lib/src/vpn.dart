import 'dart:convert';
import 'awg.dart';
import 'adopted_resource.dart';
import 'tt.dart';
import 'dart:math';
import 'network/ip_address.dart';
import 'vless_contract.g.dart';
import 'runner.dart';
import 'service_mode.dart';

String newVpnId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// A terminal revocation state. `abandoned` records that local tracking was
/// deliberately stopped because the physical server is no longer accessible;
/// it must never be presented as a confirmed remote revocation.
bool vpnRevocationSettled(Object? target) =>
    target is Map && const {'revoked', 'abandoned'}.contains(target['status']);

final class VpnUser {
  VpnUser({
    required this.id,
    required this.login,
    required this.name,
    this.enabled = true,
    this.deletion,
    this.baseTemplate,
    this.baseTemplateName,
  }) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(login) ||
        name.isEmpty ||
        name.length > 80 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException('vpn_user_invalid');
    }
    if (baseTemplate != null &&
            (baseTemplate!.trim().isEmpty ||
                utf8.encode(baseTemplate!).length > 256 * 1024) ||
        baseTemplateName != null &&
            (baseTemplate == null ||
                baseTemplateName!.isEmpty ||
                baseTemplateName!.length > 255 ||
                baseTemplateName!.contains(RegExp(r'[\x00-\x1f\x7f]')))) {
      throw const FormatException('vpn_user_invalid');
    }
    if (deletion != null) {
      if (enabled ||
          deletion!['hidden'] != null && deletion!['hidden'] is! bool ||
          deletion!['version'] != 1 ||
          !RegExp(
            r'^[a-f0-9]{32}$',
          ).hasMatch(deletion!['id'] as String? ?? '') ||
          deletion!['targets'] is! Map ||
          (deletion!['targets'] as Map).length > 1000 ||
          deletion!['executor'] != null &&
              !RegExp(
                r'^[a-f0-9]{32}$',
              ).hasMatch(deletion!['executor'] as String)) {
        throw const FormatException('vpn_user_invalid');
      }
      for (final target in (deletion!['targets'] as Map).values) {
        if (target is! Map) {
          throw const FormatException('vpn_user_invalid');
        }
        final attempts = target['connectionAttempts'];
        final connectAfter = target['connectAfter'];
        if (attempts != null &&
                (attempts is! int || attempts < 0 || attempts > 3) ||
            connectAfter != null &&
                (connectAfter is! int || connectAfter < 0) ||
            ![
              'waiting',
              'running',
              'revoked',
              'abandoned',
              'error',
            ].contains(target['status'])) {
          throw const FormatException('vpn_user_invalid');
        }
        if (target['request'] case final Map request) {
          RunnerRequest.fromJson(Map<String, Object?>.from(request));
        }
      }
      if (deletion!['file'] case final Map file) {
        if (!['accountKey', 'fileId', 'registryId', 'folderId'].every(
              (key) => file[key] is String && (file[key] as String).isNotEmpty,
            ) ||
            !['waiting', 'deleted', 'error'].contains(file['status'])) {
          throw const FormatException('vpn_user_invalid');
        }
      }
    }
  }
  factory VpnUser.fromJson(Map<String, dynamic> j) {
    if ((j['deleted'] == true) != (j['deletion'] != null)) {
      throw const FormatException('vpn_user_invalid');
    }
    final base = j['baseConfig'];
    if (base != null &&
        (base is! Map || base['version'] != 1 || base['source'] is! String)) {
      throw const FormatException('vpn_user_invalid');
    }
    return VpnUser(
      id: j['id'] as String,
      login: j['login'] as String,
      name: j['name'] as String,
      enabled: j['enabled'] as bool,
      baseTemplate: base == null ? null : (base as Map)['source'] as String,
      baseTemplateName: base == null ? null : (base as Map)['name'] as String?,
      deletion: j['deletion'] == null
          ? null
          : Map<String, dynamic>.from(j['deletion'] as Map),
    );
  }
  final String id, login, name;
  final bool enabled;
  final String? baseTemplate, baseTemplateName;
  String profileTemplate(String sharedTemplate) =>
      baseTemplate ?? sharedTemplate;
  final Map<String, dynamic>? deletion;

  VpnUser copyWith({
    String? id,
    String? login,
    String? name,
    bool? enabled,
    String? baseTemplate,
    String? baseTemplateName,
    Map<String, dynamic>? deletion,
  }) => VpnUser(
    id: id ?? this.id,
    login: login ?? this.login,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    baseTemplate: baseTemplate ?? this.baseTemplate,
    baseTemplateName: baseTemplateName ?? this.baseTemplateName,
    deletion: deletion ?? this.deletion,
  );
  bool get deleted => deletion != null;
  bool get revocationComplete =>
      deleted &&
      (deletion!['targets'] as Map).values.every(
        (t) => t['status'] == 'revoked',
      );
  bool get revocationSettled =>
      deleted &&
      (deletion!['targets'] as Map).values.every(vpnRevocationSettled);
  bool get deletionComplete =>
      revocationSettled &&
      (deletion!['file'] == null || deletion!['file']['status'] == 'deleted');
  Map<String, Object?> toJson() => {
    'id': id,
    'login': login,
    'name': name,
    'enabled': enabled,
    if (baseTemplate != null)
      'baseConfig': {
        'version': 1,
        'source': baseTemplate,
        if (baseTemplateName != null) 'name': baseTemplateName,
      },
    if (deleted) ...{'deleted': true, 'deletion': deletion},
  };
}

final class VlessInbound {
  VlessInbound({required this.serverId, required Map<String, Object?> spec})
    : spec = Map.unmodifiable({
        ...spec,
        if (spec['adoption'] != null)
          'adoption': Map<String, Object?>.unmodifiable(
            spec['adoption'] as Map,
          ),
      }) {
    final rule =
        ((vlessSchema['properties'] as Map)['resources'] as Map)['items']
            as Map;
    validateVlessSchema(spec, rule);
    if (spec.containsKey('adoption')) {
      validateAdoptedResource(spec);
      return;
    }
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
    validateXhttpOptions(spec);
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
  bool get internal => spec['internal'] == true;
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
    List<AwgInterface> awgInterfaces = const [],
    List<TrustTunnelEndpoint> ttEndpoints = const [],
    Map<String, Map<String, dynamic>> servers = const {},
    Map<String, Map<String, dynamic>> profiles = const {},
    Map<String, ServerServiceMode> serviceMode = const {},
  }) : users = List.unmodifiable(users),
       serviceMode = Map.unmodifiable(serviceMode),
       inbounds = List.unmodifiable(inbounds),
       awgInterfaces = List.unmodifiable(awgInterfaces),
       ttEndpoints = List.unmodifiable(ttEndpoints),
       profiles = Map.unmodifiable(profiles),
       servers = Map.unmodifiable(
         servers.map(
           (k, v) => MapEntry(k, Map<String, dynamic>.unmodifiable(v)),
         ),
       ) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        users.where((u) => !u.deleted).length > 1000 ||
        users.length > 10000 ||
        users.map((u) => u.id).toSet().length != users.length ||
        users
                .where((u) => !u.deleted)
                .map((u) => u.login.toLowerCase())
                .toSet()
                .length !=
            users.where((u) => !u.deleted).length ||
        <dynamic>{
              ...inbounds.map((i) => i.id),
              ...awgInterfaces.map((i) => i.id),
              ...ttEndpoints.map((i) => i.id),
            }.length !=
            inbounds.length + awgInterfaces.length + ttEndpoints.length) {
      throw const FormatException('vpn_duplicate');
    }
    if (serviceMode.length > 1000 ||
        !serviceMode.keys.every(validServiceModeServerId)) {
      throw const FormatException('vpn_service_mode_invalid');
    }
  }
  factory VpnWorkspace.empty() => VpnWorkspace(id: newVpnId());
  factory VpnWorkspace.decode(String raw) {
    final j = jsonDecode(raw) as Map;
    if (![1, 2, 3, 4, 5, 6].contains(j['version'])) {
      throw const FormatException('vpn_version');
    }
    final serviceMode = j['serviceMode'];
    if (serviceMode != null && serviceMode is! Map) {
      throw const FormatException('vpn_service_mode_invalid');
    }
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
      awgInterfaces: (j['awgInterfaces'] as List? ?? [])
          .map((e) => AwgInterface.fromJson(e as Map))
          .toList(),
      ttEndpoints: (j['ttEndpoints'] as List? ?? [])
          .map((e) => TrustTunnelEndpoint.fromJson(e as Map))
          .toList(),
      profiles: (j['profiles'] as Map? ?? {}).map(
        (k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
      ),
      servers: (j['servers'] as Map).map(
        (k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
      ),
      serviceMode: (serviceMode as Map? ?? const {}).map(
        (k, v) => MapEntry(k as String, ServerServiceMode.fromJson(v)),
      ),
    );
  }
  final String id;
  final List<VpnUser> users;
  final List<VlessInbound> inbounds;
  final List<AwgInterface> awgInterfaces;
  final List<TrustTunnelEndpoint> ttEndpoints;
  final Map<String, Map<String, dynamic>> servers, profiles;

  /// Physical servers in service mode, by catalog id. Absent: not in it.
  final Map<String, ServerServiceMode> serviceMode;

  /// The service mode of the physical server behind [target], which may be
  /// a catalog id or any target form (`awg/<id>`, `tt/<id>`).
  ServerServiceMode? serviceModeOf(String target) =>
      serviceMode[vpnServerId(target)];

  /// Whether [target]'s physical server is in service mode, `active` or
  /// `returning`: either way it stays out of profiles and provisioning.
  bool inServiceMode(String target) => serviceModeOf(target) != null;

  late final Map<String, VpnUser> _userMap = {for (final u in users) u.id: u};

  VpnUser? userById(String id) => _userMap[id];

  /// Keep the namespace used to derive credentials on the actual server when
  /// an independently created local workspace joins the same Google account.
  String resourceWorkspaceId(String target) {
    final value = servers[target]?['resourceWorkspaceId'] ?? id;
    if (value is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
      throw const FormatException('vpn_workspace');
    }
    return value;
  }

  String encode() => jsonEncode({
    // A newer version only when the document holds what an older reader
    // would misread; older readers then refuse it instead of dropping it.
    'version': serviceMode.isNotEmpty
        ? 6
        : users.any(
            (user) =>
                user.deleted &&
                (user.deletion!['targets'] as Map).values.any(
                  (target) => target['status'] == 'abandoned',
                ),
          )
        ? 5
        : users.any((u) => u.deleted)
        ? 4
        : 3,
    'id': id,
    'users': users.map((e) => e.toJson()).toList(),
    'inbounds': inbounds.map((e) => e.toJson()).toList(),
    'awgInterfaces': awgInterfaces.map((e) => e.toJson()).toList(),
    'ttEndpoints': ttEndpoints.map((e) => e.toJson()).toList(),
    'servers': servers,
    'profiles': profiles,
    if (serviceMode.isNotEmpty)
      'serviceMode': {
        for (final e in serviceMode.entries) e.key: e.value.toJson(),
      },
  });
  VpnWorkspace copy({
    List<VpnUser>? users,
    List<VlessInbound>? inbounds,
    List<AwgInterface>? awgInterfaces,
    List<TrustTunnelEndpoint>? ttEndpoints,
    Map<String, Map<String, dynamic>>? servers,
    Map<String, Map<String, dynamic>>? profiles,
    Map<String, ServerServiceMode>? serviceMode,
  }) => VpnWorkspace(
    id: id,
    users: users ?? this.users,
    inbounds: inbounds ?? this.inbounds,
    awgInterfaces: awgInterfaces ?? this.awgInterfaces,
    ttEndpoints: ttEndpoints ?? this.ttEndpoints,
    servers: servers ?? this.servers,
    profiles: profiles ?? this.profiles,
    serviceMode: serviceMode ?? this.serviceMode,
  );

  /// The resource specs [target] should have, deleted ones included, in
  /// the order of its desired payload.
  List<Map<String, Object?>> desiredResources(String target) {
    final server = vpnServerId(target);
    final resources = isTtTarget(target)
        ? [
            for (final r in ttEndpoints)
              if (r.serverId == server) (id: r.id, spec: r.spec),
          ]
        : isAwgTarget(target)
        ? [
            for (final r in awgInterfaces)
              if (r.serverId == server) (id: r.id, spec: r.spec),
          ]
        : [
            for (final r in inbounds)
              if (r.serverId == target) (id: r.id, spec: r.spec),
          ];
    resources.sort((a, b) => a.id.compareTo(b.id));
    return [for (final r in resources) r.spec];
  }

  Map<String, Object?> desired(String serverId, String panelId) {
    final owner = resourceWorkspaceId(serverId);
    if (isTtTarget(serverId)) {
      final clients = users.where((u) => !u.deleted).toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      final result = <String, Object?>{
        'version': 1,
        'protocol': 'tt',
        'workspaceId': owner,
        'panelId': owner,
        'resources': desiredResources(serverId),
        'users': clients
            .map(
              (u) => <String, Object?>{
                'id': u.id,
                'enabled': u.enabled,
                'login': u.login,
              },
            )
            .toList(),
      };
      validateTtPayload(result);
      return result;
    }
    if (isAwgTarget(serverId)) {
      final clients = users.where((u) => !u.deleted).toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      final result = <String, Object?>{
        'version': 1,
        'protocol': 'awg',
        'workspaceId': owner,
        'panelId': owner,
        'resources': desiredResources(serverId),
        'users': clients
            .map((u) => <String, Object?>{'id': u.id, 'enabled': u.enabled})
            .toList(),
      };
      validateAwgPayload(result);
      return result;
    }
    final clients = users.where((u) => !u.deleted).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final result = <String, Object?>{
      'version': 1,
      'workspaceId': owner,
      'panelId': panelId,
      'resources': desiredResources(serverId),
      'users': clients
          .map((u) => <String, Object?>{'id': u.id, 'enabled': u.enabled})
          .toList(),
    };
    validateVlessSchema(result);
    return result;
  }

  Set<String> get serverIds => {
    ...inbounds.where((i) => !i.deleted).map((i) => i.serverId),
    ...awgInterfaces.where((i) => !i.deleted).map((i) => awgTarget(i.serverId)),
    ...ttEndpoints.where((i) => !i.deleted).map((i) => ttTarget(i.serverId)),
  };
  @override
  String toString() => 'VpnWorkspace(<redacted>)';
}

final class VpnStoredDocument {
  const VpnStoredDocument(this.source, this.revision, {this.workspaceId});
  final String? source;
  final int revision;
  final String? workspaceId;
}

abstract interface class VpnRepository {
  Future<VpnStoredDocument> readVpn();
  Future<int> writeVpn(String source, {required int expectedRevision});
}

/// Lets repositories encode a workspace where the write actually runs.
/// Callers can retain VpnRepository compatibility with string-backed stores.
abstract interface class VpnWorkspaceWriter {
  Future<int> writeVpnWorkspace(
    VpnWorkspace workspace, {
    required int expectedRevision,
  });
}

/// Applies one user edit with the same workspace revision and journal CAS.
abstract interface class VpnUserWriter {
  Future<int> upsertVpnUser(VpnUser user, {required int expectedRevision});
}

abstract interface class VpnProfileWriter {
  Future<int> upsertVpnProfile(
    String userId,
    Map<String, dynamic> profile, {
    required int expectedRevision,
  });
}

abstract interface class ProfileExporter {
  Future<bool> save(String name, String source);
}

Map get xhttpOptionsSchema =>
    (((vlessSchema['properties'] as Map)['resources'] as Map)['items']
            as Map)['properties']['xhttp']
        as Map;

void validateXhttpOptions(Map spec) {
  final extra = spec['xhttp'] as Map? ?? {};
  if (extra.isEmpty) return;
  if (spec['transport'] != 'xhttp') {
    throw const FormatException('vless_invalid');
  }
  final headers = extra['headers'] as Map? ?? {};
  if (headers.keys.any((key) => key.toString().toLowerCase() == 'host')) {
    throw const FormatException('vless_invalid');
  }
  if ((extra['uplinkHTTPMethod'] == 'GET' ||
          ['header', 'cookie'].contains(extra['uplinkDataPlacement'])) &&
      spec['mode'] != 'packet-up') {
    throw const FormatException('vless_invalid');
  }
  int lower(Object? value) =>
      value == null ? 0 : int.parse('$value'.split('-').first);
  int upper(Object? value) =>
      value == null ? 0 : int.parse('$value'.split('-').last);
  if (extra.containsKey('xPaddingBytes') &&
      lower(extra['xPaddingBytes']) == 0 &&
      upper(extra['xPaddingBytes']) > 0) {
    throw const FormatException('vless_invalid');
  }
  final xmux = extra['xmux'] as Map? ?? {};
  if (upper(xmux['maxConcurrency']) > 0 && upper(xmux['maxConnections']) > 0) {
    throw const FormatException('vless_invalid');
  }
  if (extra.containsKey('sessionIDTable')) {
    final lengths = (extra['sessionIDLength'] as String? ?? '16-32')
        .split('-')
        .map(int.parse)
        .toList();
    if (lengths.first < 10 || lengths.last > 128) {
      throw const FormatException('vless_invalid');
    }
  }
}

Map<String, Object?> xhttpMihomoOptions(Map options, [Map? schema]) {
  final properties = (schema ?? xhttpOptionsSchema)['properties'] as Map;
  final result = <String, Object?>{};
  for (final e in options.entries) {
    final prop = properties[e.key];
    if (prop is! Map) continue;
    final name = prop['mihomo'];
    if (name is! String) continue;
    if (e.key == 'xmux') {
      if (e.value is Map) {
        result[name] = xhttpMihomoOptions(e.value as Map, prop);
      }
    } else {
      var val = e.value;
      if (val is String && val.trim().isEmpty) {
        val = prop['default'];
      }
      if (val != null && (val is! String || val.isNotEmpty)) {
        result[name] = val;
      }
    }
  }
  return result;
}

List<String> get vlessFingerprints => List<String>.from(
  ((vlessSchema['properties']
          as Map)['resources']['items']['properties']['fingerprint']['enum'])
      as List,
);

/// Explicit non-empty defaults from 3x-ui 3.7.0. Empty upstream values keep
/// their inherited meaning; an existing XMUX strategy is never overwritten.
Map<String, Object?> xhttpFormDefaults([Map initial = const {}]) {
  final properties = xhttpOptionsSchema['properties'] as Map;
  final xmux = (properties['xmux'] as Map)['properties'] as Map;
  final existing = Map<String, Object?>.from(initial['xmux'] as Map? ?? {});
  final multiplex = <String, Object?>{
    for (final e in xmux.entries) e.key as String: (e.value as Map)['default'],
    for (final e in existing.entries)
      if (e.value != null &&
          (e.value is! String || (e.value as String).trim().isNotEmpty))
        e.key: e.value,
  };
  if (existing.isNotEmpty && !existing.containsKey('maxConnections')) {
    multiplex['maxConnections'] = '0';
  }
  return {
    for (final e in properties.entries)
      if ((e.value as Map).containsKey('default'))
        e.key as String: e.value['default'],
    for (final e in initial.entries)
      if (e.key != 'xmux' &&
          e.value != null &&
          (e.value is! String ||
              (e.value as String).trim().isNotEmpty ||
              ((properties[e.key] as Map?)?.containsKey('enum') ?? false)))
        e.key as String: e.value,
    'xmux': multiplex,
  };
}
