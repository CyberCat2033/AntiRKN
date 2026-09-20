import 'dart:convert';
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
  Future<void> trashFile(PublicationFile expected, String deletionId);
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
    this.pickerApiKey,
    this.pickerAppId,
  });
  final String accountKey, folderId, folderName;
  final PublicationAccess access;
  final bool enabled, folderReady;
  final String? pickerApiKey, pickerAppId;
  Map<String, Object?> toJson() => {
    'version': 1,
    'accountKey': accountKey,
    'folderId': folderId,
    'folderName': folderName,
    'access': access.name,
    'enabled': enabled,
    'folderReady': folderReady,
    'pickerApiKey': ?pickerApiKey,
    'pickerAppId': ?pickerAppId,
  };
  factory PublicationSettings.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1 ||
        value['accountKey'] is! String ||
        value['folderId'] is! String ||
        value['folderName'] is! String ||
        value['enabled'] is! bool ||
        value['folderReady'] is! bool ||
        value['pickerApiKey'] != null &&
            (value['pickerApiKey'] is! String ||
                !RegExp(
                  r'^[A-Za-z0-9_-]{20,256}$',
                ).hasMatch(value['pickerApiKey'] as String)) ||
        value['pickerAppId'] != null &&
            (value['pickerAppId'] is! String ||
                !RegExp(
                  r'^[0-9]{1,30}$',
                ).hasMatch(value['pickerAppId'] as String))) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    return PublicationSettings(
      accountKey: value['accountKey'] as String,
      folderId: value['folderId'] as String,
      folderName: value['folderName'] as String,
      access: PublicationAccess.values.byName(value['access'] as String),
      enabled: value['enabled'] as bool,
      folderReady: value['folderReady'] as bool,
      pickerApiKey: value['pickerApiKey'] as String?,
      pickerAppId: value['pickerAppId'] as String?,
    );
  }
  PublicationSettings copy({
    bool? enabled,
    bool? folderReady,
    PublicationAccess? access,
    String? pickerApiKey,
    String? pickerAppId,
  }) => PublicationSettings(
    accountKey: accountKey,
    folderId: folderId,
    folderName: folderName,
    access: access ?? this.access,
    enabled: enabled ?? this.enabled,
    folderReady: folderReady ?? this.folderReady,
    pickerApiKey: pickerApiKey ?? this.pickerApiKey,
    pickerAppId: pickerAppId ?? this.pickerAppId,
  );
}

/// A Drive URL is a locator, not an authorization grant.
final class PublicationTarget {
  PublicationTarget(this.fileId, {this.resourceKey}) {
    if (!_id(fileId) || resourceKey != null && !_id(resourceKey!)) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
  }
  final String fileId;
  final String? resourceKey;
  static bool _id(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(value);
  factory PublicationTarget.parse(String input) {
    var value = input.trim();
    if (_id(value)) return PublicationTarget(value);
    if (value.startsWith('drive.google.com/') ||
        value.startsWith('drive.usercontent.google.com/')) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        ![
          'drive.google.com',
          'drive.usercontent.google.com',
        ].contains(uri.host)) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    String? id;
    if (uri.host == 'drive.google.com') {
      final segments = uri.pathSegments;
      final dIndex = segments.indexOf('d');
      if (dIndex >= 0 && dIndex + 1 < segments.length) {
        id = segments[dIndex + 1];
      } else if (['/open', '/uc', '/download'].contains(uri.path) ||
          ['open', 'uc', 'download'].contains(segments.lastOrNull)) {
        if (uri.queryParametersAll['id']?.length != 1) {
          throw const PublicationFailure(PublicationIssue.invalid);
        }
        id = uri.queryParameters['id'];
      }
    } else if (['/open', '/uc', '/download'].contains(uri.path)) {
      if (uri.queryParametersAll['id']?.length != 1) {
        throw const PublicationFailure(PublicationIssue.invalid);
      }
      id = uri.queryParameters['id'];
    }
    final resourceKeys = [
      ...?uri.queryParametersAll['resourcekey'],
      ...?uri.queryParametersAll['resourceKey'],
    ];
    if (id == null || resourceKeys.length > 1) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    return PublicationTarget(
      id,
      resourceKey: resourceKeys.singleOrNull,
    );
  }
  @override
  String toString() => 'PublicationTarget(<private>)';
}

abstract interface class PublicationResourceKeys {
  void useResourceKey(PublicationTarget target);
}

abstract interface class PublicationFilePicker {
  Future<PublicationTarget?> pick({
    required String apiKey,
    required String appId,
  });
  void cancel();
}

final class PublicationBindingPreview {
  const PublicationBindingPreview({
    required this.file,
    required this.content,
    required this.hash,
    required this.draft,
    required this.settingsSource,
    required this.intentSource,
    required this.registryId,
    required this.entry,
  });
  final PublicationFile file;
  final String content, hash, settingsSource;
  final String? intentSource, registryId;
  final Map<String, dynamic>? entry;
  final PublicationDraft draft;
  @override
  String toString() => 'PublicationBindingPreview(<private>)';
}

/// Encrypted shared consent. Contains identity/revision only; profile secrets
/// remain in the existing profile storage. Consent includes later auto updates.
void validatePublicationBinding(Map<String, dynamic> value) {
  if (value['version'] != 1 ||
      ![
        'id',
        'workspaceId',
        'userId',
        'accountKey',
        'fileId',
        'etag',
        'hash',
      ].every((k) => value[k] is String && (value[k] as String).isNotEmpty) ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['id'] as String) ||
      value['previous'] != null && value['previous'] is! Map ||
      !['private', 'link'].contains(value['access']) ||
      utf8.encode(jsonEncode(value)).length > 32768) {
    throw const PublicationFailure(PublicationIssue.invalid);
  }
  PublicationTarget(
    value['fileId'] as String,
    resourceKey: value['resourceKey'] as String?,
  );
}
