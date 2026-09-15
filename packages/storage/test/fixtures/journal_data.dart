import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/src/profile_codec.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sqlite3/sqlite3.dart';

const fixtureWorkspaceId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const fixtureUserId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const fixtureServerId = 'journal-server-fixture';
const fixtureSecret = 'private-journal-credential-fixture';
SecretKeyData fixtureKey() => SecretKeyData(List.filled(32, 19));

SshProfile fixtureServer([String host = 'fixture.example']) => SshProfile(
  host: host,
  port: 22,
  username: 'fixture-admin',
  authMethod: SshAuthMethod.password,
  hostKey: const TrustedHostKey('ssh-ed25519', 'SHA256:fixture-trust'),
  secrets: const {
    ServerSecret.sshPassword: fixtureSecret,
    ServerSecret.privateKey: 'private-ssh-fixture',
    ServerSecret.sudoPassword: 'private-sudo-fixture',
  },
);

VpnWorkspace fixtureVpn([String id = fixtureWorkspaceId]) => VpnWorkspace(
  id: id,
  users: [
    VpnUser(id: fixtureUserId, login: 'fixture-client', name: 'Fixture client'),
  ],
  inbounds: [
    VlessInbound(
      serverId: fixtureServerId,
      spec: {
        ...VlessInbound.defaults(),
        'id': 'c' * 32,
        'endpoint': '203.0.113.1',
        'sni': 'example.com',
        'target': 'example.com:443',
      },
    ),
  ],
  awgInterfaces: [
    AwgInterface(
      serverId: fixtureServerId,
      spec: {
        'id': 'd' * 32,
        'name': 'AWG',
        'enabled': true,
        'deleted': false,
        'endpoint': '203.0.113.1',
        'port': 51820,
        'externalPort': 51820,
        'pool': '10.10.0.0/20',
        'pool6': '',
        'mtu': 1280,
        'keepalive': 25,
        'options': {
          for (final e in awgOptionRules.entries)
            e.key as String: e.value['default'],
        },
      },
    ),
  ],
  ttEndpoints: [
    TrustTunnelEndpoint(
      serverId: fixtureServerId,
      spec: {
        'id': 'e' * 32,
        'name': 'TT',
        'enabled': true,
        'deleted': false,
        'listen': '0.0.0.0',
        'port': 8443,
        'endpoint': '203.0.113.1',
        'externalPort': 8443,
        'domain': 'vpn.example.com',
        'certificateId': 'f' * 32,
        'quic': false,
        'ipv6': false,
        'allowPrivate': false,
        'outbound': 'direct',
        'socksAddress': '127.0.0.1:1080',
        'rotation': 0,
      },
    ),
  ],
  servers: {
    fixtureServerId: {
      'observed': [
        {
          'uuid': 'private-vless-fixture',
          'clients': [
            {'id': fixtureUserId, 'uuid': fixtureSecret},
          ],
        },
      ],
      'pending': {'id': 'private-operation-fixture'},
      'authorizedPayload': fixtureSecret,
      'unknown-fixture-field': {'preserved': true},
    },
    awgTarget(fixtureServerId): {
      'observed': [
        {
          'privateKey': 'private-awg-key-fixture',
          'presharedKey': fixtureSecret,
        },
      ],
    },
    ttTarget(fixtureServerId): {
      'observed': [
        {'password': 'private-tt-password-fixture'},
      ],
    },
  },
  profiles: {
    fixtureUserId: {
      'yaml': 'private-yaml-fixture',
      'hash': 'fixture-hash',
      'history': [
        {'yaml': 'private-old-yaml-fixture'},
      ],
    },
  },
);

/// Independent writer for the shipped schema v1 and its original AAD.
Future<void> createV1(String path, {int vpnVersion = 3}) async {
  final db = sqlite3.open(path);
  final key = fixtureKey();
  try {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute(
      'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE servers (id TEXT PRIMARY KEY, payload BLOB NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), updated_at INTEGER NOT NULL)',
    );
    db.execute(
      'CREATE TABLE documents (id TEXT PRIMARY KEY, payload BLOB NOT NULL, revision INTEGER NOT NULL CHECK(revision>0))',
    );
    db.execute('CREATE TABLE migrations (id TEXT PRIMARY KEY)');
    Future<List<int>> encrypt(
      String scope,
      int revision,
      String source,
    ) async => (await AesGcm.with256bits().encrypt(
      utf8.encode(source),
      secretKey: key,
      aad: utf8.encode('antirkn:1:$scope:$revision'),
    )).concatenation();
    final server = await encrypt(
      'server:$fixtureServerId',
      7,
      jsonEncode({...encodeProfile(fixtureServer()), 'id': fixtureServerId}),
    );
    db.execute('INSERT INTO servers VALUES (?,?,7,1)', [
      fixtureServerId,
      server,
    ]);
    final vpn = jsonDecode(fixtureVpn().encode()) as Map<String, dynamic>;
    vpn['version'] = vpnVersion;
    if (vpnVersion < 3) vpn.remove('ttEndpoints');
    if (vpnVersion < 2) vpn.remove('awgInterfaces');
    for (final entry in {
      'vpn-workspace-v1': jsonEncode(vpn),
      'template-draft': 'private-template-fixture',
      'runner/$fixtureServerId': jsonEncode({
        'version': 1,
        'cursor': 4,
        'pending': {'id': 'private-runner-fixture'},
        'panelAccess': {'password': fixtureSecret},
      }),
    }.entries) {
      db.execute('INSERT INTO documents VALUES (?,?,9)', [
        entry.key,
        await encrypt(entry.key, 9, entry.value),
      ]);
    }
    db.execute(
      "INSERT INTO settings VALUES ('language','ru'),('theme','dark')",
    );
    db.execute("INSERT INTO migrations VALUES ('legacy-vault-v1')");
    db.userVersion = 1;
  } finally {
    key.destroy();
    db.dispose();
  }
}
