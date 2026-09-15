import 'dart:typed_data';

enum PublicationAccess { private, link }

enum PublicationIssue {
  unauthorized,
  forbidden,
  missing,
  conflict,
  network,
  rateLimited,
  unavailable,
  invalid,
  size,
  readback,
  linkUnavailable,
  accountChanged,
}

final class PublicationFailure implements Exception {
  const PublicationFailure(this.issue, {this.retryAfter});
  final PublicationIssue issue;
  final Duration? retryAfter;
  @override
  String toString() => 'PublicationFailure(${issue.name})';
}

final class PublicationFile {
  const PublicationFile({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.version,
    required this.etag,
    required this.editable,
    required this.properties,
    this.downloadUrl,
    this.resourceKey,
    this.trashed = false,
    this.shared = false,
  });
  final String id, name, mimeType, version, etag;
  final bool editable, trashed, shared;
  final Map<String, String> properties;
  final String? downloadUrl, resourceKey;
  bool get folder => mimeType == 'application/vnd.google-apps.folder';
  bool get binary => !mimeType.startsWith('application/vnd.google-apps.');
  @override
  String toString() => 'PublicationFile(<private>)';
}

/// File operations only. A coordinator must grant permission before mutations;
/// a successful HTTP write is not a verified publication or a working link.
abstract interface class PublicationRemoteStore {
  String get accountKey;
  Future<String> generateFileId();
  Future<PublicationFile> getFile(String fileId);
  Future<List<PublicationFile>> listFolders();
  Future<void> createFolder(String fileId, String name);
  Future<void> createYaml({
    required String fileId,
    required String folderId,
    required String name,
    required String workspaceId,
    required String userId,
    required String headId,
    required String executorId,
    required Uint8List bytes,
  });
  Future<void> updateFile(
    PublicationFile expected,
    Uint8List bytes, {
    required Map<String, String> properties,
  });
  Future<void> updateProperties(
    PublicationFile expected,
    Map<String, String> properties,
  );
  Future<void> createRegistry(
    String fileId,
    String folderId,
    String workspaceId,
    Uint8List bytes,
  );
  Future<Uint8List> download(String fileId);
  Future<String> enableLink(String fileId);
  Future<void> checkPrivate(String fileId);
  Future<void> removeLink(String fileId, String permissionId);
  Future<void> verifyPublicLink(String url, Uint8List expected);
}

const publicationProfileLimit = 4 * 1024 * 1024;

/// The snapshot is meaningful only while its local stamp and profile head are
/// still current. Ancestors prove causality; wall-clock timestamps never do.
final class PublicationDraft {
  PublicationDraft({
    required this.workspaceId,
    required this.deviceId,
    required this.userId,
    required this.name,
    required this.headId,
    required this.hash,
    required this.stamp,
    required this.bytes,
    required Set<String> ancestors,
  }) : ancestors = Set.unmodifiable(ancestors);
  final String workspaceId, deviceId, userId, name, headId, hash, stamp;
  final Uint8List bytes;
  final Set<String> ancestors;
  @override
  String toString() => 'PublicationDraft(<private>)';
}

abstract interface class PublicationRepository {
  Future<String?> readPublicationDocument(String id);
  Future<void> writePublicationDocument(
    String id,
    String source, {
    required String? expectedSource,
  });
  Future<String?> readPublicationQueue(String userId);
  Future<void> writePublicationQueue(
    String userId,
    String source, {
    required String? expectedSource,
  });
  Future<PublicationDraft?> readPublicationDraft(String userId);
  Future<void> checkPublicationDraft(PublicationDraft draft);
}

final class PublicationSettings {
  const PublicationSettings({
    required this.accountKey,
    required this.folderId,
    required this.folderName,
    required this.access,
    this.enabled = true,
    this.folderReady = true,
  });
  final String accountKey, folderId, folderName;
  final PublicationAccess access;
  final bool enabled, folderReady;
  Map<String, Object?> toJson() => {
    'version': 1,
    'accountKey': accountKey,
    'folderId': folderId,
    'folderName': folderName,
    'access': access.name,
    'enabled': enabled,
    'folderReady': folderReady,
  };
  factory PublicationSettings.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1 ||
        value['accountKey'] is! String ||
        value['folderId'] is! String ||
        value['folderName'] is! String ||
        value['enabled'] is! bool ||
        value['folderReady'] is! bool) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    return PublicationSettings(
      accountKey: value['accountKey'] as String,
      folderId: value['folderId'] as String,
      folderName: value['folderName'] as String,
      access: PublicationAccess.values.byName(value['access'] as String),
      enabled: value['enabled'] as bool,
      folderReady: value['folderReady'] as bool,
    );
  }
  PublicationSettings copy({
    bool? enabled,
    bool? folderReady,
    PublicationAccess? access,
  }) => PublicationSettings(
    accountKey: accountKey,
    folderId: folderId,
    folderName: folderName,
    access: access ?? this.access,
    enabled: enabled ?? this.enabled,
    folderReady: folderReady ?? this.folderReady,
  );
}
