part of 'workspace_database.dart';

// Publication files keep their original namespace when independently created
// workspaces join one Google account. Recompilation must not create a new URL.
String _withAccountNamespaces(String source, String? previous) {
  final value = jsonDecode(source) as Map<String, dynamic>;
  final old = previous == null ? null : VpnWorkspace.decode(previous);
  final workspace = VpnWorkspace.decode(source);
  var changed = false;
  final servers = value['servers'] as Map;
  for (final target in {
    ...workspace.serverIds,
    ...servers.keys.cast<String>(),
  }) {
    final record =
        servers.putIfAbsent(target, () => <String, dynamic>{}) as Map;
    final owner =
        old?.servers[target]?['resourceWorkspaceId'] ??
        record['resourceWorkspaceId'] ??
        value['id'];
    if (owner is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(owner)) {
      throw const FormatException('resource_workspace');
    }
    if (record['resourceWorkspaceId'] != owner) {
      record['resourceWorkspaceId'] = owner;
      changed = true;
    }
  }
  for (final entry in (value['profiles'] as Map? ?? {}).entries) {
    final profile = entry.value as Map;
    final namespace =
        old?.profiles[entry.key]?['publicationWorkspaceId'] ??
        profile['publicationWorkspaceId'] ??
        value['id'];
    if (namespace is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(namespace)) {
      throw const FormatException('publication_workspace');
    }
    if (profile['publicationWorkspaceId'] != namespace) {
      profile['publicationWorkspaceId'] = namespace;
      changed = true;
    }
  }
  return changed ? jsonEncode(value) : source;
}
