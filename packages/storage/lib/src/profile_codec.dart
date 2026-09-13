import 'package:antirkn_domain/antirkn_domain.dart';
import 'server_info_codec.dart';

Map<String, Object?> encodeProfile(SshProfile profile) => {
  'id': profile.id,
  'name': profile.name,
  'host': profile.host,
  'port': profile.port,
  'username': profile.username,
  'authMethod': profile.authMethod.name,
  'keyName': profile.keyName,
  'jumpServerId': profile.jumpServerId,
  'lastInfo': profile.lastInfo == null
      ? null
      : encodeServerInfo(profile.lastInfo!),
  'secrets': profile.secrets.map((k, v) => MapEntry(k.name, v)),
  'hostKey': profile.hostKey == null
      ? null
      : {
          'algorithm': profile.hostKey!.algorithm,
          'fingerprint': profile.hostKey!.fingerprint,
        },
};

SshProfile decodeProfile(Map<String, Object?> server) {
  final hostKey = server['hostKey'] as Map<String, Object?>?;
  final profile = SshProfile(
    id: server['id'] as String? ?? SshProfile.serverId,
    name: server['name'] as String? ?? '',
    host: server['host']! as String,
    port: server['port']! as int,
    username: server['username']! as String,
    authMethod: SshAuthMethod.values.byName(server['authMethod']! as String),
    keyName: server['keyName'] as String?,
    jumpServerId: server['jumpServerId'] as String?,
    lastInfo: server['lastInfo'] == null
        ? null
        : decodeServerInfo(server['lastInfo'] as Map<String, Object?>),
    hostKey: hostKey == null
        ? null
        : TrustedHostKey(
            hostKey['algorithm']! as String,
            hostKey['fingerprint']! as String,
          ),
    secrets: (server['secrets']! as Map<String, Object?>).map(
      (k, v) => MapEntry(ServerSecret.values.byName(k), v! as String),
    ),
  );
  if (!profile.valid) throw const VaultFailure(VaultIssue.corrupt);
  return profile;
}
