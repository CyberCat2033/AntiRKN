import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';

part 'publication_binding.dart';

/// Coordinates one agreed Drive folder. Conditional writes serialize registry
/// allocation and profile updates; local clocks never grant ownership.
final class PublicationCoordinator {
  PublicationCoordinator({
    required this.repository,
    required this.remote,
    this.eligible,
    this.workspaceId,
    DateTime Function()? now,
    int Function(int)? jitter,
  }) : now = now ?? DateTime.now,
       jitter = jitter ?? Random.secure().nextInt;
  final PublicationRepository repository;
  final PublicationRemoteStore remote;
  final Future<bool> Function(PublicationDraft)? eligible;
  final String? workspaceId;
  final DateTime Function() now;
  final int Function(int) jitter;
  String? _cachedRegistryId;
  Future<String>? _registryFuture;
  (PublicationFile, Map<String, dynamic>)? _cachedRegistry;
  Future<(PublicationFile, Map<String, dynamic>)>? _registrySnapshotFuture;
  Future<void> _registryLock = Future.value();

  Future<T> _lockRegistry<T>(Future<T> Function() action) {
    final next = _registryLock.then((_) => action());
    _registryLock = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<(PublicationFile, Map<String, dynamic>)> _fetchRegistry(
    String registryId,
    String workspaceId,
  ) {
    return _registrySnapshotFuture ??= () async {
      final cached = _cachedRegistry;
      if (cached != null && cached.$1.id == registryId) {
        final current = await remote.getFile(registryId);
        if (current.etag == cached.$1.etag) {
          return cached;
        }
        final snapshot = await _snapshot(registryId, file: current);
        final decoded = _decodeRegistry(snapshot.$2, workspaceId);
        final result = (snapshot.$1, decoded);
        _cachedRegistry = result;
        return result;
      }
      final snapshot = await _snapshot(registryId);
      final decoded = _decodeRegistry(snapshot.$2, workspaceId);
      final result = (snapshot.$1, decoded);
      _cachedRegistry = result;
      return result;
    }().whenComplete(() {
      _registrySnapshotFuture = null;
    });
  }

  void _invalidateRegistryCache() {
    _cachedRegistry = null;
  }

  Future<Map<String, dynamic>?> publish(
    String userId, {
    bool force = false,
    bool forceUpload = false,
    SyncCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? SyncCancellation();
    final settingsSource = await repository.readPublicationDocument('settings');
    if (settingsSource == null) return null;
    final settings = PublicationSettings.fromJson(
      jsonDecode(settingsSource) as Map<String, dynamic>,
    );
    if (!settings.enabled || !settings.folderReady) return null;
    if (settings.accountKey != remote.accountKey) {
      throw const PublicationFailure(PublicationIssue.accountChanged);
    }
    final draft = await repository.readPublicationDraft(userId);
    if (draft == null || eligible != null && !await eligible!(draft)) {
      return null;
    }
    var queueSource = await repository.readPublicationQueue(userId);
    var queue = queueSource == null
        ? <String, dynamic>{}
        : jsonDecode(queueSource) as Map<String, dynamic>;
    final same = queue['head'] == draft.headId;
    if (!force &&
        same &&
        queue['status'] == 'published' &&
        queue['hash'] == draft.hash) {
      return queue;
    }
    if (!force &&
        same &&
        (queue['retryAt'] as int? ?? 0) > now().millisecondsSinceEpoch) {
      return queue;
    }
    Future<void> saveQueue(Map<String, dynamic> next) async {
      final source = canonicalJson(next);
      await repository.writePublicationQueue(
        userId,
        source,
        expectedSource: queueSource,
      );
      queueSource = source;
      queue = next;
    }

    final intentSource = await repository.readPublicationDocument(
      'binding/$userId',
    );
    (String, String)? registryFence;
    Future<void> guard() async {
      cancel.check();
      if (await repository.readPublicationDocument('settings') !=
              settingsSource ||
          await repository.readPublicationDocument('binding/$userId') !=
              intentSource ||
          eligible != null && !await eligible!(draft)) {
        throw const SyncMergeFailure(SyncMergeIssue.changed);
      }
      await repository.checkPublicationDraft(draft);
      if (registryFence case final fence?) {
        final snapshot = await _snapshot(fence.$1);
        final value = _decodeRegistry(snapshot.$2, draft.workspaceId);
        if (canonicalJson((value['users'] as Map)[userId]) != fence.$2) {
          throw const PublicationFailure(PublicationIssue.conflict);
        }
      }
      cancel.check();
    }

    try {
      await saveQueue({
        ...queue,
        'version': 1,
        'head': draft.headId,
        'hash': draft.hash,
        'status': 'waiting',
        'attempt': same ? queue['attempt'] ?? 0 : 0,
        'retryAt': 0,
        'issue': null,
      });
      await guard();
      final registryId = await _registry(settings, draft, guard);
      if (intentSource != null) {
        await _startBinding(
          registryId,
          draft,
          jsonDecode(intentSource) as Map<String, dynamic>,
          guard,
        );
      }
      final entry = await _reserve(registryId, draft, guard);
      // Uncreated automatic entries change in _markCreated; bound entries are
      // already final and can be fenced for the whole publication.
      if (entry['binding'] != null) {
        registryFence = (registryId, canonicalJson(entry));
      }
      _resourceKey(entry);
      var fileId = entry['fileId'] as String;
      await saveQueue({...queue, 'fileId': fileId, 'registryId': registryId});
      final beforeSource = await repository.readPublicationDocument(
        'result/$userId',
      );
      final previous = beforeSource == null
          ? <String, dynamic>{}
          : jsonDecode(beforeSource) as Map<String, dynamic>;
      final previousEtag = previous['fileId'] == fileId
          ? previous['etag'] as String?
          : null;

      PublicationFile? file;
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          try {
            file = await remote.getFile(fileId);
          } on PublicationFailure catch (e) {
            if (e.issue != PublicationIssue.missing) {
              rethrow;
            }
            if (entry['created'] == true) {
              // Drive file was deleted externally after a successful publication.
              // Reset the registry entry to allow recreation with a fresh fileId.
              await guard();
              fileId = await _resetEntry(
                registryId,
                draft.workspaceId,
                draft.userId,
                fileId,
                guard,
              );
              await saveQueue({
                ...queue,
                'fileId': fileId,
                'registryId': registryId,
              });
              entry['created'] = false;
            }
            await guard();
            try {
              file = await remote.createYaml(
                fileId: fileId,
                folderId: settings.folderId,
                name: '${draft.name}.yml',
                workspaceId: draft.workspaceId,
                userId: draft.userId,
                headId: draft.headId,
                executorId: draft.deviceId,
                bytes: draft.bytes,
              );
            } on PublicationFailure catch (e) {
              if (e.issue != PublicationIssue.conflict) rethrow;
            }
          }
          file ??= await remote.getFile(fileId);
          final f = file;
          if (f.properties['antirknWorkspace'] != draft.workspaceId ||
              f.properties['antirknUser'] !=
                  (entry['owner'] ?? draft.userId) ||
              !f.editable ||
              f.properties['antirknDeleted'] != null ||
              !f.binary ||
              f.trashed) {
            throw const PublicationFailure(PublicationIssue.invalid);
          }
          if (settings.access == PublicationAccess.private) {
            await remote.checkPrivate(fileId);
          }
          final head = f.properties['antirknHead'];
          if (!force &&
              head != draft.headId &&
              !draft.ancestors.contains(head)) {
            throw const PublicationFailure(PublicationIssue.conflict);
          }
          final remoteHash = f.properties['antirknHash'];
          final canSkipDownload = forceUpload ||
              (previousEtag != null &&
                  previousEtag == f.etag &&
                  remoteHash != null);
          final String hash;
          if (canSkipDownload) {
            hash = remoteHash ?? '';
          } else {
            final snapshot = await _snapshot(fileId, file: f);
            file = snapshot.$1;
            hash = await _hash(snapshot.$2);
          }
          if (forceUpload || hash != draft.hash || head != draft.headId) {
            await guard();
            final props = {
              'antirknHead': draft.headId,
              'antirknExecutor': draft.deviceId,
              'antirknHash': draft.hash,
            };
            if (!forceUpload && hash == draft.hash) {
              file = await remote.updateProperties(file, props);
            } else {
              file = await remote.updateFile(file, draft.bytes, properties: props);
            }
          }
          break;
        } on PublicationFailure catch (e) {
          if (e.issue != PublicationIssue.conflict || attempt == 3) rethrow;
          await guard();
        }
      }
      await guard();
      if (entry['created'] != true) {
        await _markCreated(
          registryId,
          draft.workspaceId,
          draft.userId,
          fileId,
          guard,
        );
      }
      String? permissionId = previous['fileId'] == fileId
          ? previous['permissionId'] as String?
          : null;
      String? url = previous['fileId'] == fileId
          ? previous['url'] as String?
          : null;
      if (settings.access == PublicationAccess.link) {
        await guard();
        if (permissionId == null || url == null) {
          permissionId = await remote.enableLink(fileId);
          file = await remote.getFile(fileId);
          url = file.downloadUrl;
          if (url == null) {
            throw const PublicationFailure(PublicationIssue.linkUnavailable);
          }
          await remote.verifyPublicLink(url, draft.bytes);
        }
      } else if (permissionId != null) {
        await guard();
        await remote.removeLink(fileId, permissionId);
        permissionId = null;
      }
      await guard();
      final executor = file!.properties['antirknExecutor'] ?? draft.deviceId;
      final result = <String, dynamic>{
        'version': entry['binding'] == null ? 1 : 2,
        'binding': ?entry['binding'],
        'owner': ?entry['owner'],
        'resourceKey': ?entry['resourceKey'],
        'fileId': fileId,
        'registryId': registryId,
        'head': draft.headId,
        'hash': draft.hash,
        'executor': executor,
        'access': settings.access.name,
        'url': url,
        'permissionId': permissionId,
        'etag': file.etag,
      };
      await repository.writePublicationDocument(
        'result/$userId',
        canonicalJson(result),
        expectedSource: beforeSource,
      );
      final successQueue = {
        ...queue,
        'status': 'published',
        'issue': null,
        'attempt': 0,
        'retryAt': now().millisecondsSinceEpoch + 300000,
      };
      await saveQueue(successQueue);
      return successQueue;
    } on SyncTransportFailure catch (e) {
      if (e.issue == SyncTransportIssue.cancelled) rethrow;
      rethrow;
    } on SyncMergeFailure {
      final nextQueue = {
        ...queue,
        'status': 'waiting',
        'issue': 'changed',
        'retryAt': now().millisecondsSinceEpoch + 5000,
      };
      try {
        await saveQueue(nextQueue);
      } catch (_) {}
      return nextQueue;
    } on PublicationFailure catch (e) {
      final attempt = (queue['attempt'] as int? ?? 0) + 1;
      final seconds =
          (5 * (1 << (attempt - 1).clamp(0, 6))).clamp(5, 300) + jitter(4);
      final retry = e.retryAfter != null && e.retryAfter!.inSeconds > seconds
          ? e.retryAfter!.inSeconds
          : seconds;
      final nextQueue = {
        ...queue,
        'status': 'error',
        'issue': e.issue.name,
        'attempt': attempt,
        'retryAt': now().millisecondsSinceEpoch + retry * 1000,
      };
      try {
        await saveQueue(nextQueue);
      } catch (_) {}
      return nextQueue;
    }
  }

  Future<String> _registry(
    PublicationSettings settings,
    PublicationDraft draft,
    Future<void> Function() guard,
  ) {
    if (_cachedRegistryId != null) return Future.value(_cachedRegistryId!);
    return _registryFuture ??= _resolveRegistry(
      settings,
      draft,
      guard,
    ).whenComplete(() {
      _registryFuture = null;
    });
  }

  Future<String> _resolveRegistry(
    PublicationSettings settings,
    PublicationDraft draft,
    Future<void> Function() guard,
  ) async {
    if (_cachedRegistryId != null) return _cachedRegistryId!;
    final key = 'antirknRegistry.${draft.workspaceId}';
    for (var attempt = 0; attempt < 6; attempt++) {
      final folder = await remote.getFile(settings.folderId);
      if (!folder.folder ||
          folder.trashed ||
          !folder.editable ||
          folder.shared) {
        throw const PublicationFailure(PublicationIssue.invalid);
      }
      final pointer = folder.properties[key];
      if (pointer == null) {
        final candidate = await remote.generateFileId();
        await guard();
        try {
          await remote.updateProperties(folder, {key: 'allocated:$candidate'});
        } on PublicationFailure catch (e) {
          if (e.issue != PublicationIssue.conflict) rethrow;
        }
        continue;
      }
      final parts = pointer.split(':');
      if (parts.length != 2 || !['allocated', 'ready'].contains(parts[0])) {
        throw const PublicationFailure(PublicationIssue.invalid);
      }
      final id = parts[1];
      if (parts[0] == 'ready') {
        final snapshot = await _snapshot(id);
        final decoded = _decodeRegistry(snapshot.$2, draft.workspaceId);
        _cachedRegistryId = id;
        _cachedRegistry = (snapshot.$1, decoded);
        return id;
      }
      try {
        final snapshot = await _snapshot(id);
        _decodeRegistry(snapshot.$2, draft.workspaceId);
      } on PublicationFailure catch (e) {
        if (e.issue != PublicationIssue.missing) rethrow;
        await guard();
        try {
          await remote.createRegistry(
            id,
            settings.folderId,
            draft.workspaceId,
            _bytes({
              'version': 1,
              'workspaceId': draft.workspaceId,
              'users': <String, dynamic>{},
            }),
          );
        } on PublicationFailure catch (e) {
          if (e.issue != PublicationIssue.conflict) rethrow;
        }
        continue;
      }
      await guard();
      try {
        await remote.updateProperties(folder, {key: 'ready:$id'});
        _cachedRegistryId = id;
      } on PublicationFailure catch (e) {
        if (e.issue != PublicationIssue.conflict) rethrow;
      }
    }
    throw const PublicationFailure(PublicationIssue.conflict);
  }

  Future<Map<String, dynamic>> _reserve(
    String registryId,
    PublicationDraft draft,
    Future<void> Function() guard,
  ) => _lockRegistry(() async {
    String? candidate;
    for (var attempt = 0; attempt < 8; attempt++) {
      final (file, value) = await _fetchRegistry(registryId, draft.workspaceId);
      final users = value['users'] as Map<String, dynamic>;
      if (users[draft.userId] case final Map existing) {
        if (existing['pending'] == true) {
          await _finishBinding(
            registryId,
            draft,
            Map<String, dynamic>.from(existing),
            guard,
          );
          _invalidateRegistryCache();
          continue;
        }
        return Map<String, dynamic>.from(existing);
      }
      candidate ??= await remote.generateFileId();
      final next = {
        ...value,
        'users': {
          ...users,
          draft.userId: {'fileId': candidate, 'created': false},
        },
      };
      await guard();
      try {
        await remote.updateFile(
          file,
          _bytes(next),
          properties: const {},
        );
        final freshSnapshot = await _snapshot(registryId);
        _cachedRegistry = (freshSnapshot.$1, next);
        return {'fileId': candidate, 'created': false};
      } on PublicationFailure catch (e) {
        _invalidateRegistryCache();
        if (e.issue != PublicationIssue.conflict) rethrow;
      }
    }
    throw const PublicationFailure(PublicationIssue.conflict);
  });

  Future<void> _markCreated(
    String registryId,
    String workspaceId,
    String userId,
    String fileId,
    Future<void> Function() guard,
  ) => _lockRegistry(() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      final (file, value) = await _fetchRegistry(registryId, workspaceId);
      final users = value['users'] as Map<String, dynamic>;
      final entry = users[userId] as Map<String, dynamic>?;
      if (entry == null || entry['fileId'] != fileId) {
        _invalidateRegistryCache();
        throw const PublicationFailure(PublicationIssue.conflict);
      }
      if (entry['created'] == true) return;
      await guard();
      final nextUsers = {
        ...users,
        userId: {...entry, 'created': true},
      };
      final next = {
        ...value,
        'users': nextUsers,
      };
      try {
        await remote.updateFile(
          file,
          _bytes(next),
          properties: const {},
        );
        final freshSnapshot = await _snapshot(registryId);
        _cachedRegistry = (freshSnapshot.$1, next);
        return;
      } on PublicationFailure catch (e) {
        _invalidateRegistryCache();
        if (e.issue != PublicationIssue.conflict) rethrow;
      }
    }
    throw const PublicationFailure(PublicationIssue.conflict);
  });

  /// Resets a registry entry after the Drive file was externally deleted.
  ///
  /// Generates a fresh [fileId] and writes `{fileId: newId, created: false}`
  /// into the registry, so the next [createYaml] call can recreate the file.
  /// Returns the new [fileId].
  Future<String> _resetEntry(
    String registryId,
    String workspaceId,
    String userId,
    String oldFileId,
    Future<void> Function() guard,
  ) => _lockRegistry(() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      final (file, value) = await _fetchRegistry(registryId, workspaceId);
      final users = value['users'] as Map<String, dynamic>;
      final entry = users[userId] as Map<String, dynamic>?;
      // If the registry was already updated concurrently, accept the new fileId.
      if (entry == null || entry['fileId'] != oldFileId) {
        _invalidateRegistryCache();
        throw const PublicationFailure(PublicationIssue.conflict);
      }
      final newFileId = await remote.generateFileId();
      await guard();
      final nextUsers = {
        ...users,
        userId: {'fileId': newFileId, 'created': false},
      };
      final next = {...value, 'users': nextUsers};
      try {
        await remote.updateFile(file, _bytes(next), properties: const {});
        final freshSnapshot = await _snapshot(registryId);
        _cachedRegistry = (freshSnapshot.$1, next);
        return newFileId;
      } on PublicationFailure catch (e) {
        _invalidateRegistryCache();
        if (e.issue != PublicationIssue.conflict) rethrow;
      }
    }
    throw const PublicationFailure(PublicationIssue.conflict);
  });

  Map<String, dynamic> _decodeRegistry(Uint8List bytes, String workspaceId) {
    try {
      final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (![1, 2].contains(value['version']) ||
          value['workspaceId'] != workspaceId ||
          value['users'] is! Map ||
          (value['users'] as Map).length > 1000) {
        throw const FormatException();
      }
      for (final e in (value['users'] as Map).entries) {
        if (e.key is! String ||
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(e.key as String) ||
            e.value is! Map ||
            e.value['fileId'] is! String ||
            e.value['created'] is! bool) {
          throw const FormatException();
        }
      }
      final ids = <String>{};
      for (final entry in (value['users'] as Map).values) {
        if (!ids.add((entry as Map)['fileId'] as String)) {
          throw const FormatException();
        }
        if (entry['pending'] == true) {
          validatePublicationBinding(
            Map<String, dynamic>.from(entry['consent'] as Map),
          );
        }
      }
      return value;
    } catch (_) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
  }

  Future<(PublicationFile, Uint8List)> _snapshot(
    String id, {
    PublicationFile? file,
  }) async {
    final before = file ?? await remote.getFile(id);
    if (before.trashed || !before.binary) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    final bytes = await remote.download(id);
    final after = await remote.getFile(id);
    if (before.etag != after.etag) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    if (await _hash(bytes) != after.properties['antirknHash']) {
      throw const PublicationFailure(PublicationIssue.readback);
    }
    return (after, bytes);
  }

  static Uint8List _bytes(Map<String, dynamic> value) =>
      Uint8List.fromList(utf8.encode(canonicalJson(value)));
  static Future<String> _hash(Uint8List bytes) async => (await Sha256().hash(
    bytes,
  )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
}
