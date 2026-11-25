import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'drive_conditional.dart';
import 'drive_http.dart';

/// Drive v3 adapter for appDataFolder. No OAuth token persistence or app UI.
final class GoogleDriveSyncStore
    implements SyncRemoteStore, SyncAccountStore, SyncSnapshotStore {
  GoogleDriveSyncStore({
    required SyncAccessTokenProvider tokens,
    DriveHttp? http,
  }) : _tokens = tokens,
       _http = http ?? NativeDriveHttp(),
       accountKey = tokens.accountKey;
  final SyncAccessTokenProvider _tokens;
  final DriveHttp _http;
  @override
  final String accountKey;
  static const scope = 'https://www.googleapis.com/auth/drive.appdata';
  static const _fileFields = 'id,name,mimeType,size,version,spaces,trashed';
  static const _v2FileFields =
      'id,title,fileSize,version,etag,createdDate,labels(trashed)';
  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,256}$');
  static final _packetName = RegExp('^$syncTransportNamePrefix[a-f0-9]{64}\$');
  static final _accountKeyName = RegExp('^$syncAccountKeyPrefix[a-f0-9]{32}\$');

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.https('www.googleapis.com', '/drive/v3/$path', query);
  void _id(String id) {
    if (!_idPattern.hasMatch(id)) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
  }

  String _token(Object? input) {
    if (input is! String || input.isEmpty || input.length > 4096) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    return input;
  }

  Future<DriveHttpResponse> _send(
    String method,
    Uri uri, {
    Uint8List? body,
    String? contentType,
    int limit = 1024 * 1024,
    bool page = false,
    Map<String, String> extraHeaders = const {},
  }) async {
    try {
      if (_tokens.accountKey != accountKey || accountKey.isEmpty) {
        throw const SyncTransportFailure(SyncTransportIssue.changed);
      }
      final token = await _tokens.accessToken();
      if (_tokens.accountKey != accountKey ||
          !RegExp(r'^[\x21-\x7e]{1,8192}$').hasMatch(token)) {
        throw const SyncTransportFailure(SyncTransportIssue.unauthorized);
      }
      final response = await _http.send(
        method,
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': ?contentType,
          ...extraHeaders,
        },
        body: body,
        responseLimit: limit,
      );
      if (response.bytes.length > limit) {
        throw const SyncTransportFailure(SyncTransportIssue.limit);
      }
      if (response.status >= 200 && response.status < 300) return response;
      if (_tokens case final RefreshableSyncAccessTokenProvider refreshable
          when response.status == 401) {
        await refreshable.invalidateAccessToken(token);
      }
      final issue = switch (response.status) {
        401 => SyncTransportIssue.unauthorized,
        403 =>
          _rateLimited(response.bytes)
              ? SyncTransportIssue.rateLimited
              : SyncTransportIssue.forbidden,
        404 => SyncTransportIssue.notFound,
        409 ||
        DriveConditional.preconditionFailed => SyncTransportIssue.conflict,
        410 when page => SyncTransportIssue.invalidCursor,
        400 when page => SyncTransportIssue.invalidCursor,
        429 => SyncTransportIssue.rateLimited,
        >= 500 => SyncTransportIssue.unavailable,
        _ => SyncTransportIssue.invalid,
      };
      throw SyncTransportFailure(
        issue,
        retryAfter: _retryAfter(response.headers['retry-after']),
      );
    } on GoogleAccountFailure {
      // Typed, sanitized authorization failures remain actionable in the UI.
      rethrow;
    } on SyncTransportFailure {
      rethrow;
    } catch (_) {
      throw const SyncTransportFailure(SyncTransportIssue.network);
    }
  }

  bool _rateLimited(Uint8List bytes) {
    try {
      final errors =
          (jsonDecode(utf8.decode(bytes)) as Map)['error']['errors'] as List;
      return errors.any(
        (e) =>
            e['reason'] == 'rateLimitExceeded' ||
            e['reason'] == 'userRateLimitExceeded',
      );
    } catch (_) {
      return false;
    }
  }

  Duration? _retryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value);
    return seconds == null || seconds < 0
        ? null
        : Duration(seconds: seconds.clamp(0, 86400));
  }

  Map<String, dynamic> _json(DriveHttpResponse response) {
    try {
      return jsonDecode(utf8.decode(response.bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
  }

  SyncRemoteFile _file(Object? input) {
    try {
      final map = input as Map;
      final id = map['id'] as String;
      _id(id);
      final name = map['name'] as String;
      if (name.length > 1024) throw const FormatException();
      final spaces = map['spaces'] as List;
      final packet =
          spaces.contains('appDataFolder') &&
          map['mimeType'] == 'application/octet-stream' &&
          _packetName.hasMatch(name);
      final size = int.tryParse(map['size'] as String? ?? '0');
      final version = map['version'] as String? ?? '0';
      if (size == null || size < 0 || version.length > 256) {
        throw const FormatException();
      }
      if (packet && size > syncTransportPacketLimit) {
        throw const SyncTransportFailure(SyncTransportIssue.limit);
      }
      return SyncRemoteFile(
        id: id,
        name: name,
        size: size,
        version: version,
        packet: packet,
        removed: map['trashed'] == true,
      );
    } on SyncTransportFailure {
      rethrow;
    } catch (_) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
  }

  /// Identity comes from Drive using the granted token, never a typed email.
  Future<GoogleDriveAccount> readAccount() async {
    final json = _json(
      await _send(
        'GET',
        _uri('about', {
          'fields': 'user(permissionId,emailAddress,displayName)',
        }),
        limit: 32768,
      ),
    );
    try {
      final user = json['user'] as Map;
      return GoogleDriveAccount.fromJson({
        'id': user['permissionId'],
        'email': user['emailAddress'],
        'name': user['displayName'] ?? '',
      });
    } catch (_) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
  }

  @override
  Future<String> generateFileId() async {
    final json = _json(
      await _send(
        'GET',
        _uri('files/generateIds', {
          'count': '1',
          'space': 'appDataFolder',
          'type': 'files',
          'fields': 'ids,space',
        }),
      ),
    );
    final ids = json['ids'];
    if (ids is! List ||
        ids.length != 1 ||
        ids.single is! String ||
        json['space'] != 'appDataFolder') {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    final id = ids.single as String;
    _id(id);
    return id;
  }

  @override
  Future<void> createPacket(String fileId, String name, Uint8List bytes) async {
    if (!_packetName.hasMatch(name)) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    await _createObject(fileId, name, bytes);
  }

  @override
  Future<void> createAccountKey(
    String fileId,
    String name,
    Uint8List bytes,
  ) async {
    if (!_accountKeyName.hasMatch(name) || bytes.length > 4096) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    await _createObject(fileId, name, bytes);
  }

  Future<void> _createObject(
    String fileId,
    String name,
    Uint8List bytes, {
    int maxBytes = syncTransportPacketLimit,
  }) async {
    _id(fileId);
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    // The generated ID is reused throughout this resumable creation request.
    final init = await _send(
      'POST',
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
        'uploadType': 'resumable',
        'fields': 'id',
      }),
      contentType: 'application/json; charset=UTF-8',
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'id': fileId,
            'name': name,
            'mimeType': 'application/octet-stream',
            'parents': ['appDataFolder'],
          }),
        ),
      ),
      extraHeaders: {
        'X-Upload-Content-Type': 'application/octet-stream',
        'X-Upload-Content-Length': '${bytes.length}',
      },
    );
    final location = init.headers['location'];
    final uri = location == null ? null : Uri.tryParse(location);
    // Never send the bearer token to an arbitrary Location or follow redirects.
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'www.googleapis.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.path != '/upload/drive/v3/files' ||
        !uri.queryParameters.containsKey('upload_id')) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    final result = _json(
      await _send(
        'PUT',
        uri,
        contentType: 'application/octet-stream',
        body: bytes,
      ),
    );
    if (result['id'] != fileId) {
      throw const SyncTransportFailure(SyncTransportIssue.conflict);
    }
  }

  @override
  Future<SyncRemoteFile> getFile(String fileId) async {
    _id(fileId);
    return _file(
      _json(await _send('GET', _uri('files/$fileId', {'fields': _fileFields}))),
    );
  }

  @override
  Future<Uint8List> download(String fileId) async {
    _id(fileId);
    return (await _send(
      'GET',
      _uri('files/$fileId', {'alt': 'media'}),
      limit: syncTransportPacketLimit,
    )).bytes;
  }

  @override
  Future<String> getStartPageToken() async => _token(
    _json(
      await _send(
        'GET',
        _uri('changes/startPageToken', {'fields': 'startPageToken'}),
      ),
    )['startPageToken'],
  );

  @override
  Future<SyncRemotePage> listFiles({String? pageToken}) async {
    return _listObjects(syncTransportNamePrefix, pageToken);
  }

  @override
  Future<SyncRemotePage> listAccountKeys({String? pageToken}) =>
      _listObjects(syncAccountKeyPrefix, pageToken);

  /// Drive v2 metadata: unlike v3 it carries the etag for conditional writes.
  SyncRemoteFile _v2File(Object? input) {
    try {
      final map = input as Map;
      final id = map['id'] as String;
      _id(id);
      final name = map['title'] as String;
      final size = int.tryParse('${map['fileSize'] ?? 0}');
      final version = '${map['version'] ?? 0}';
      final etag = map['etag'] as String? ?? '';
      final created = map['createdDate'] as String?;
      if (name.length > 1024 ||
          size == null ||
          size < 0 ||
          version.length > 256 ||
          etag.length > 1024) {
        throw const FormatException();
      }
      return SyncRemoteFile(
        id: id,
        name: name,
        size: size,
        version: version,
        packet: false,
        removed: (map['labels'] as Map?)?['trashed'] == true,
        etag: etag,
        createdAt: created == null ? null : DateTime.parse(created).toUtc(),
      );
    } catch (_) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
  }

  /// Devices creating the same object at once leave duplicates. Every device
  /// picks the same one: the earliest created, then the smallest id.
  static bool _wins(SyncRemoteFile file, SyncRemoteFile other) {
    final a = file.createdAt, b = other.createdAt;
    if (a != null && b != null && a != b) return a.isBefore(b);
    if ((a == null) != (b == null)) return a != null;
    return file.id.compareTo(other.id) < 0;
  }

  Future<SyncRemoteFile?> _singleNamed(String name) async {
    String? page;
    SyncRemoteFile? winner;
    var pages = 0;
    do {
      if (++pages > 20) {
        throw const SyncTransportFailure(SyncTransportIssue.limit);
      }
      final json = _json(
        await _send(
          'GET',
          DriveConditional.v2('files', {
            'spaces': 'appDataFolder',
            'maxResults': '100',
            'q': "title = '$name' and trashed = false",
            'fields': 'nextPageToken,incompleteSearch,items($_v2FileFields)',
            'pageToken': ?page,
          }),
          page: page != null,
        ),
      );
      if (json['incompleteSearch'] == true) {
        throw const SyncTransportFailure(SyncTransportIssue.unavailable);
      }
      final items = json['items'] ?? <dynamic>[];
      if (items is! List || items.length > 100) {
        throw const SyncTransportFailure(SyncTransportIssue.invalid);
      }
      for (final item in items) {
        final file = _v2File(item);
        if (file.name != name || file.removed) continue;
        if (winner == null || _wins(file, winner)) winner = file;
      }
      page = json['nextPageToken'] == null
          ? null
          : _token(json['nextPageToken']);
    } while (page != null);
    return winner;
  }

  @override
  Future<SyncRemoteFile?> findSnapshot() => _singleNamed(syncSnapshotName);

  @override
  Future<Uint8List> readSnapshot(String fileId) async {
    _id(fileId);
    return (await _send(
      'GET',
      _uri('files/$fileId', {'alt': 'media'}),
      limit: maxWorkspaceBackupBytes,
    )).bytes;
  }

  @override
  Future<SyncRemoteFile> writeSnapshot(
    SyncRemoteFile? expected,
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty || bytes.length > maxWorkspaceBackupBytes) {
      throw const SyncTransportFailure(SyncTransportIssue.limit);
    }
    if (expected == null) {
      final id = await generateFileId();
      await _createObject(
        id,
        syncSnapshotName,
        bytes,
        maxBytes: maxWorkspaceBackupBytes,
      );
      // Re-read: a snapshot another device created at the same time may win.
      final winner = await findSnapshot();
      if (winner == null) {
        throw const SyncTransportFailure(SyncTransportIssue.notFound);
      }
      if (winner.id != id) {
        throw const SyncTransportFailure(SyncTransportIssue.conflict);
      }
      return winner;
    }
    _id(expected.id);
    final precondition =
        DriveConditional.ifMatch(expected.etag) ??
        (throw const SyncTransportFailure(SyncTransportIssue.invalid));
    final result = _json(
      await _send(
        'PUT',
        DriveConditional.v2('files/${expected.id}', {
          'uploadType': 'media',
          'fields': 'id,version,etag',
        }, true),
        contentType: 'application/octet-stream',
        body: bytes,
        limit: 32768,
        extraHeaders: precondition,
      ),
    );
    if (result['id'] != expected.id) {
      throw const SyncTransportFailure(SyncTransportIssue.conflict);
    }
    final version = '${result['version'] ?? ''}';
    final etag = result['etag'];
    if (version.isEmpty ||
        version.length > 256 ||
        etag is! String ||
        DriveConditional.ifMatch(etag) == null) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    return SyncRemoteFile(
      id: expected.id,
      name: syncSnapshotName,
      size: bytes.length,
      version: version,
      packet: false,
      etag: etag,
      createdAt: expected.createdAt,
    );
  }

  @override
  Future<Uint8List?> readSnapshotKey() async {
    final file = await _singleNamed(syncSnapshotKeyName);
    if (file == null) return null;
    if (file.size > 4096) {
      throw const SyncTransportFailure(SyncTransportIssue.limit);
    }
    final bytes = await download(file.id);
    if (bytes.length != file.size || bytes.length > 4096) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    return bytes;
  }

  @override
  Future<Uint8List> createSnapshotKey(Uint8List bytes) async {
    if (bytes.length != 32) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    if (await _singleNamed(syncSnapshotKeyName) == null) {
      await _createObject(
        await generateFileId(),
        syncSnapshotKeyName,
        bytes,
        maxBytes: 4096,
      );
    }
    // Re-read: a key another device created at the same time may win.
    return await readSnapshotKey() ??
        (throw const SyncTransportFailure(SyncTransportIssue.notFound));
  }

  Future<SyncRemotePage> _listObjects(String prefix, String? pageToken) async {
    if (pageToken != null) _token(pageToken);
    final json = _json(
      await _send(
        'GET',
        _uri('files', {
          'spaces': 'appDataFolder',
          'pageSize': '100',
          'q': "trashed = false and name contains '$prefix'",
          'fields': 'nextPageToken,incompleteSearch,files($_fileFields)',
          'pageToken': ?pageToken,
        }),
        page: pageToken != null,
      ),
    );
    if (json['incompleteSearch'] == true) {
      throw const SyncTransportFailure(SyncTransportIssue.unavailable);
    }
    final files = json['files'] ?? <dynamic>[];
    if (files is! List || files.length > 100) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    return SyncRemotePage(
      files: files.map(_file).toList(),
      nextPageToken: json['nextPageToken'] == null
          ? null
          : _token(json['nextPageToken']),
    );
  }

  @override
  Future<SyncRemotePage> listChanges(String pageToken) async {
    _token(pageToken);
    final json = _json(
      await _send(
        'GET',
        _uri('changes', {
          'spaces': 'appDataFolder',
          'pageSize': '100',
          'pageToken': pageToken,
          'includeRemoved': 'true',
          'fields':
              'nextPageToken,newStartPageToken,changes(fileId,removed,file($_fileFields))',
        }),
        page: true,
      ),
    );
    final changes = json['changes'] ?? <dynamic>[];
    if (changes is! List || changes.length > 100) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    final files = <SyncRemoteFile>[];
    for (final change in changes) {
      if (change is! Map || change['fileId'] is! String) {
        throw const SyncTransportFailure(SyncTransportIssue.invalid);
      }
      final id = change['fileId'] as String;
      _id(id);
      if (change['removed'] == true) {
        files.add(
          SyncRemoteFile(
            id: id,
            name: '',
            size: 0,
            version: 'removed',
            packet: false,
            removed: true,
          ),
        );
      } else {
        final file = _file(change['file']);
        if (file.id != id) {
          throw const SyncTransportFailure(SyncTransportIssue.invalid);
        }
        files.add(file);
      }
    }
    return SyncRemotePage(
      files: files,
      nextPageToken: json['nextPageToken'] == null
          ? null
          : _token(json['nextPageToken']),
      newStartPageToken: json['newStartPageToken'] == null
          ? null
          : _token(json['newStartPageToken']),
    );
  }
}
