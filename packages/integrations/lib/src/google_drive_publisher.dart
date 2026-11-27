import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';

import 'drive_conditional.dart';
import 'drive_http.dart';

/// Ordinary Drive files, separate from the encrypted appData sync transport.
final class GoogleDrivePublisher
    implements PublicationRemoteStore, PublicationResourceKeys {
  GoogleDrivePublisher({required this.tokens, DriveHttp? http})
    : _http = http ?? NativeDriveHttp(),
      _accountKey = tokens.accountKey;
  final SyncAccessTokenProvider tokens;
  final DriveHttp _http;
  final String _accountKey;
  final _resourceKeys = <String, String>{};
  @override
  void useResourceKey(PublicationTarget target) {
    if (target.resourceKey != null) {
      _resourceKeys[target.fileId] = target.resourceKey!;
    }
  }

  @override
  String get accountKey => _accountKey;
  static const _v2Fields =
      'id,title,mimeType,version,etag,shared,labels(trashed),webContentLink,resourceKey,properties,capabilities(canEdit)';
  static const _fields =
      'id,name,mimeType,version,shared,trashed,webContentLink,resourceKey,appProperties,capabilities(canEdit)';

  void _account() {
    if (tokens.accountKey != _accountKey) {
      throw const PublicationFailure(PublicationIssue.accountChanged);
    }
  }

  String _id(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(id)) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    return id;
  }

  Uri _uri(String path, [Map<String, String>? query, bool upload = false]) =>
      Uri.https(
        'www.googleapis.com',
        '${upload ? '/upload' : ''}/drive/v3/$path',
        query,
      );

  Future<DriveHttpResponse> _send(
    String method,
    Uri uri, {
    Uint8List? body,
    Map<String, String> headers = const {},
    int limit = publicationProfileLimit,
  }) async {
    _account();
    String? token;
    try {
      token = await tokens.accessToken();
      _account();
      final segments = uri.pathSegments;
      final filesIndex = segments.indexOf('files');
      final resourceId = filesIndex >= 0 && filesIndex + 1 < segments.length
          ? segments[filesIndex + 1]
          : null;
      final response = await _http.send(
        method,
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          if (_resourceKeys.containsKey(resourceId))
            'X-Goog-Drive-Resource-Keys':
                '$resourceId/${_resourceKeys[resourceId]}',
          ...headers,
        },
        body: body,
        responseLimit: limit,
      );
      _account();
      if (response.status >= 200 && response.status < 300) return response;
      if (response.status == 401 &&
          tokens is RefreshableSyncAccessTokenProvider) {
        await (tokens as RefreshableSyncAccessTokenProvider)
            .invalidateAccessToken(token);
      }
      final delay = int.tryParse(response.headers['retry-after'] ?? '');
      throw PublicationFailure(
        switch (response.status) {
          401 => PublicationIssue.unauthorized,
          403 =>
            _rateLimited(response.bytes)
                ? PublicationIssue.rateLimited
                : PublicationIssue.forbidden,
          404 => PublicationIssue.missing,
          409 ||
          DriveConditional.preconditionFailed => PublicationIssue.conflict,
          429 => PublicationIssue.rateLimited,
          >= 500 => PublicationIssue.unavailable,
          _ => PublicationIssue.invalid,
        },
        retryAfter: delay == null
            ? null
            : Duration(seconds: delay.clamp(0, 86400)),
      );
    } on PublicationFailure {
      rethrow;
    } on SyncTransportFailure catch (e) {
      throw PublicationFailure(switch (e.issue) {
        SyncTransportIssue.unauthorized => PublicationIssue.unauthorized,
        SyncTransportIssue.forbidden => PublicationIssue.forbidden,
        SyncTransportIssue.limit => PublicationIssue.size,
        _ => PublicationIssue.network,
      });
    } on GoogleAccountFailure catch (e) {
      throw PublicationFailure(
        e.issue == GoogleAccountIssue.reauthorize
            ? PublicationIssue.unauthorized
            : PublicationIssue.network,
      );
    }
  }

  Map<String, dynamic> _json(DriveHttpResponse response) {
    try {
      return jsonDecode(utf8.decode(response.bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
  }

  bool _rateLimited(Uint8List bytes) {
    try {
      final errors =
          (jsonDecode(utf8.decode(bytes)) as Map)['error']['errors'] as List;
      return errors.any(
        (e) => [
          'rateLimitExceeded',
          'userRateLimitExceeded',
        ].contains(e['reason']),
      );
    } catch (_) {
      return false;
    }
  }

  PublicationFile _file(Map<String, dynamic> value) {
    try {
      final properties = value.containsKey('properties')
          ? <String, String>{
              for (final p in value['properties'] as List)
                if ((p as Map)['visibility'] == 'PRIVATE')
                  p['key'] as String: p['value'] as String,
            }
          : (value['appProperties'] as Map? ?? {}).map(
              (k, v) => MapEntry(k as String, v as String),
            );
      return PublicationFile(
        id: _id(value['id'] as String),
        name: (value['name'] ?? value['title']) as String,
        mimeType: value['mimeType'] as String,
        version: value['version'] as String? ?? '',
        etag: value['etag'] as String? ?? '',
        editable: (value['capabilities'] as Map?)?['canEdit'] == true,
        properties: Map.unmodifiable(properties),
        shared: value['shared'] == true,
        trashed:
            value['trashed'] == true ||
            (value['labels'] as Map?)?['trashed'] == true,
        downloadUrl: value['webContentLink'] as String?,
        resourceKey: value['resourceKey'] as String?,
      );
    } catch (_) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
  }

  @override
  Future<String> generateFileId() async {
    final value = _json(
      await _send(
        'GET',
        _uri('files/generateIds', {
          'count': '1',
          'space': 'drive',
          'type': 'files',
        }),
      ),
    );
    try {
      return _id((value['ids'] as List).single as String);
    } catch (_) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
  }

  Uri _v2(String path, [Map<String, String>? query, bool upload = false]) =>
      DriveConditional.v2(path, query, upload);
  @override
  Future<PublicationFile> getFile(String fileId) async => _file(
    _json(
      await _send('GET', _v2('files/${_id(fileId)}', {'fields': _v2Fields})),
    ),
  );

  @override
  Future<List<PublicationFile>> listFolders() async {
    final folders = <PublicationFile>[];
    String? page;
    final seen = <String>{};
    do {
      if (page != null && (!seen.add(page) || seen.length > 20)) {
        throw const PublicationFailure(PublicationIssue.size);
      }
      final value = _json(
        await _send(
          'GET',
          _uri('files', {
            'q':
                "trashed = false and mimeType = 'application/vnd.google-apps.folder'",
            'spaces': 'drive',
            'pageSize': '100',
            'fields': 'nextPageToken,files($_fields)',
            'pageToken': ?page,
          }),
        ),
      );
      try {
        folders.addAll(
          (value['files'] as List)
              .map((v) => _file(v as Map<String, dynamic>))
              .where((f) => f.editable && f.folder && !f.trashed && !f.shared),
        );
        page = value['nextPageToken'] as String?;
      } catch (_) {
        throw const PublicationFailure(PublicationIssue.invalid);
      }
      if (folders.length > 1000) {
        throw const PublicationFailure(PublicationIssue.size);
      }
    } while (page != null);
    return folders;
  }

  @override
  Future<void> createFolder(String fileId, String name) async {
    await _send(
      'POST',
      _uri('files'),
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'id': _id(fileId),
            'name': name,
            'mimeType': 'application/vnd.google-apps.folder',
          }),
        ),
      ),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
    );
  }

  @override
  Future<void> renameFolder(String fileId, String name) async {
    await _send(
      'PATCH',
      _uri('files/${_id(fileId)}', {'fields': 'id'}),
      body: Uint8List.fromList(utf8.encode(jsonEncode({'name': name}))),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
    );
  }

  /// The v3 create response carries only kind/id/name/mimeType: no v2 ETag,
  /// private properties or capabilities. The created file is therefore read
  /// back through v2, which is also the confirmation of the remote state.
  @override
  Future<PublicationFile> createYaml({
    required String fileId,
    required String folderId,
    required String name,
    required String workspaceId,
    required String userId,
    required String headId,
    required String executorId,
    required Uint8List bytes,
  }) async {
    await _create(
      fileId: fileId,
      folderId: folderId,
      name: name,
      workspaceId: workspaceId,
      userId: userId,
      headId: headId,
      executorId: executorId,
      bytes: bytes,
    );
    return getFile(fileId);
  }

  Future<void> _create({
    required String fileId,
    required String folderId,
    required String name,
    required String workspaceId,
    required String userId,
    required String headId,
    required String executorId,
    required Uint8List bytes,
  }) async {
    if (bytes.length > publicationProfileLimit) {
      throw const PublicationFailure(PublicationIssue.size);
    }
    final boundary =
        'antirkn-${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final hashDigest = (await Sha256().hash(
      bytes,
    )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final metadata = jsonEncode({
      'id': _id(fileId),
      'name': name,
      'parents': [_id(folderId)],
      'mimeType': 'application/yaml',
      'appProperties': {
        'antirknWorkspace': workspaceId,
        'antirknUser': userId,
        'antirknHead': headId,
        'antirknExecutor': executorId,
        'antirknHash': hashDigest,
      },
    });
    final body = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n--$boundary\r\nContent-Type: application/yaml\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final created = _json(
      await _send(
        'POST',
        _uri('files', {'uploadType': 'multipart', 'fields': 'id'}, true),
        body: body.takeBytes(),
        headers: {'Content-Type': 'multipart/related; boundary=$boundary'},
      ),
    );
    if (created['id'] != fileId) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
  }

  Map<String, Object?> _propertyBody(Map<String, String> properties) => {
    'properties': [
      for (final p in properties.entries)
        {'key': p.key, 'value': p.value, 'visibility': 'PRIVATE'},
    ],
  };
  Map<String, String> _ifMatch(PublicationFile file) =>
      DriveConditional.ifMatch(file.etag) ??
      (throw const PublicationFailure(PublicationIssue.invalid));

  @override
  Future<PublicationFile> updateProperties(
    PublicationFile expected,
    Map<String, String> properties,
  ) async {
    final response = await _send(
      'PUT',
      _v2('files/${_id(expected.id)}'),
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode(_propertyBody({...expected.properties, ...properties})),
        ),
      ),
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        ..._ifMatch(expected),
      },
    );
    final json = _json(response);
    return json['id'] is String
        ? _file(json)
        : PublicationFile(
            id: expected.id,
            name: expected.name,
            mimeType: expected.mimeType,
            version: json['version'] as String? ?? expected.version,
            etag: json['etag'] as String? ?? expected.etag,
            editable: expected.editable,
            properties: {...expected.properties, ...properties},
            shared: expected.shared,
            trashed: expected.trashed,
            downloadUrl: expected.downloadUrl,
            resourceKey: expected.resourceKey,
          );
  }

  @override
  Future<void> trashFile(PublicationFile expected, String deletionId) async {
    if (!expected.binary ||
        !expected.editable ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(deletionId)) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    await _send(
      'PATCH',
      _v2('files/${_id(expected.id)}'),
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            ..._propertyBody({
              ...expected.properties,
              'antirknDeleted': deletionId,
            }),
            'labels': {'trashed': true},
          }),
        ),
      ),
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        ..._ifMatch(expected),
      },
    );
  }

  @override
  Future<PublicationFile> updateFile(
    PublicationFile expected,
    Uint8List bytes, {
    required Map<String, String> properties,
  }) async {
    if (bytes.length > publicationProfileLimit) {
      throw const PublicationFailure(PublicationIssue.size);
    }
    final boundary =
        'antirkn-${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final hashDigest = (await Sha256().hash(
      bytes,
    )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final metadata = jsonEncode(
      _propertyBody({
        ...expected.properties,
        ...properties,
        'antirknHash': hashDigest,
      }),
    );
    final body = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n--$boundary\r\nContent-Type: application/octet-stream\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    // The response is the file as the server stored it, with the new ETag
    // and properties; no field is guessed from the request.
    final written = _file(
      _json(
        await _send(
          'PUT',
          _v2('files/${_id(expected.id)}', {
            'uploadType': 'multipart',
            'fields': _v2Fields,
          }, true),
          body: body.takeBytes(),
          headers: {
            'Content-Type': 'multipart/related; boundary=$boundary',
            ..._ifMatch(expected),
          },
        ),
      ),
    );
    if (written.id != expected.id) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    return written;
  }

  @override
  Future<void> createRegistry(
    String fileId,
    String folderId,
    String workspaceId,
    Uint8List bytes,
  ) async {
    // The coordinator reads the registry back with a hash-checked snapshot.
    await _create(
      fileId: fileId,
      folderId: folderId,
      name: '.antirkn-publications-$workspaceId.json',
      workspaceId: workspaceId,
      userId: 'registry',
      headId: 'registry',
      executorId: 'registry',
      bytes: bytes,
    );
  }

  @override
  Future<Uint8List> download(String fileId) async => (await _send(
    'GET',
    _uri('files/${_id(fileId)}', {'alt': 'media'}),
  )).bytes;
  Future<List<Map<String, dynamic>>> _permissions(String fileId) async {
    final result = <Map<String, dynamic>>[];
    String? page;
    for (var i = 0; i < 10; i++) {
      final value = _json(
        await _send(
          'GET',
          _uri('files/${_id(fileId)}/permissions', {
            'fields':
                'nextPageToken,permissions(id,type,role,allowFileDiscovery)',
            'pageSize': '100',
            'pageToken': ?page,
          }),
          limit: 65536,
        ),
      );
      if (value['permissions'] is! List) {
        throw const PublicationFailure(PublicationIssue.invalid);
      }
      result.addAll(
        (value['permissions'] as List).map(
          (v) => Map<String, dynamic>.from(v as Map),
        ),
      );
      page = value['nextPageToken'] as String?;
      if (page == null) return result;
    }
    throw const PublicationFailure(PublicationIssue.size);
  }

  @override
  Future<void> checkPrivate(String fileId) async {
    if ((await _permissions(fileId)).any((p) => p['type'] == 'anyone')) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
  }

  @override
  Future<String> enableLink(String fileId) async {
    final existing = (await _permissions(
      fileId,
    )).where((p) => p['type'] == 'anyone').firstOrNull;
    if (existing != null) {
      if (existing['role'] != 'reader' ||
          existing['allowFileDiscovery'] == true) {
        throw const PublicationFailure(PublicationIssue.conflict);
      }
      return _id(existing['id'] as String);
    }
    final value = _json(
      await _send(
        'POST',
        _uri('files/${_id(fileId)}/permissions', {'fields': 'id'}),
        body: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'anyone',
              'role': 'reader',
              'allowFileDiscovery': false,
            }),
          ),
        ),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
      ),
    );
    if (value['id'] is! String) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    return _id(value['id'] as String);
  }

  @override
  Future<void> removeLink(String fileId, String permissionId) async {
    final existing = (await _permissions(
      fileId,
    )).where((p) => p['id'] == permissionId).firstOrNull;
    if (existing == null) return;
    if (existing['type'] != 'anyone' || existing['role'] != 'reader') {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    await _send(
      'DELETE',
      _uri('files/${_id(fileId)}/permissions/${_id(permissionId)}'),
    );
  }

  @override
  Future<void> verifyPublicLink(String url, Uint8List expected) async {
    var uri = Uri.tryParse(url);
    try {
      for (var i = 0; i < 6; i++) {
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.userInfo.isNotEmpty ||
            uri.port != 443 ||
            !(const {
                  'drive.google.com',
                  'drive.usercontent.google.com',
                }.contains(uri.host) ||
                uri.host.endsWith('.googleusercontent.com'))) {
          throw const PublicationFailure(PublicationIssue.linkUnavailable);
        }
        final response = await _http.send(
          'GET',
          uri,
          headers: const {},
          responseLimit: publicationProfileLimit,
        );
        if (const {301, 302, 303, 307, 308}.contains(response.status)) {
          final target = response.headers['location'];
          if (target == null) break;
          uri = uri.resolve(target);
          continue;
        }
        if (response.status != 200 ||
            response.bytes.length != expected.length) {
          break;
        }
        for (var n = 0; n < expected.length; n++) {
          if (response.bytes[n] != expected[n]) {
            throw const PublicationFailure(PublicationIssue.linkUnavailable);
          }
        }
        return;
      }
    } on PublicationFailure {
      rethrow;
    } catch (_) {
      throw const PublicationFailure(PublicationIssue.linkUnavailable);
    }
    throw const PublicationFailure(PublicationIssue.linkUnavailable);
  }
}
