/// A safe, structured reason why a complete client profile cannot be issued.
///
/// [subject] contains only display names (protocol, server and resource), never
/// credentials or serialized server state.
final class ProfileAccessException implements FormatException {
  const ProfileAccessException(this.code, this.subject);

  final String code;
  final String? subject;

  @override
  String get message => code;

  @override
  Object? get source => null;

  @override
  int? get offset => null;

  @override
  String toString() => 'ProfileAccessException($code, $subject)';
}

void reportPendingAccess(
  ProfileAccessException issue,
  void Function(ProfileAccessException)? receiver,
) {
  if (receiver == null) throw issue;
  receiver(issue);
}

String accessDiagnosticSubject(
  String protocol,
  String serverId,
  String resourceName,
  Map<String, String> serverNames,
) {
  final savedName = serverNames[serverId]?.trim();
  final server = savedName?.isNotEmpty == true ? savedName! : serverId;
  final resource = resourceName.trim().isEmpty ? protocol : resourceName.trim();
  return '$protocol · $server · $resource';
}
