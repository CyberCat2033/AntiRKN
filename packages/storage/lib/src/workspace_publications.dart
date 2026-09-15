part of 'workspace_database.dart';

bool _isPublicationDocument(String id) =>
    RegExp(r'^publication/(settings|result/[a-f0-9]{32})$').hasMatch(id);

void _validatePublicationDocument(String id, String source) {
  if (!_isPublicationDocument(id) || utf8.encode(source).length > 65536) {
    throw const PublicationFailure(PublicationIssue.invalid);
  }
  final value = jsonDecode(source) as Map<String, dynamic>;
  if (id == 'publication/settings') {
    PublicationSettings.fromJson(value);
    return;
  }
  if (value['version'] != 1 ||
      !['private', 'link'].contains(value['access']) ||
      ![
        'fileId',
        'registryId',
        'head',
        'hash',
        'executor',
      ].every((k) => value[k] is String) ||
      value['url'] != null && value['url'] is! String ||
      value['permissionId'] != null && value['permissionId'] is! String) {
    throw const PublicationFailure(PublicationIssue.invalid);
  }
}

extension WorkspacePublications on WorkspaceDatabase {
  String _publicationInputStamp() => jsonEncode(
    _db
        .select(
          "SELECT id,revision FROM documents WHERE id IN ('vpn-workspace-v1','template-draft') ORDER BY id",
        )
        .map((r) => [r['id'], r['revision']])
        .toList(),
  );
  String _publicationId(String id) {
    if (!RegExp(
      r'^(settings|queue/[a-f0-9]{32}|result/[a-f0-9]{32})$',
    ).hasMatch(id)) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    return 'publication/$id';
  }
}
