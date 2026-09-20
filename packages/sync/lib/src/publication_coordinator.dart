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

  Future<Map<String, dynamic>?> publish(
    String userId, {
    bool force = false,
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
    try {
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
      final fileId = entry['fileId'] as String;
      await saveQueue({...queue, 'fileId': fileId, 'registryId': registryId});
      PublicationFile? file;
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          try {
            file = await remote.getFile(fileId);
          } on PublicationFailure catch (e) {
            if (e.issue != PublicationIssue.missing ||
                entry['created'] == true) {
              rethrow;
            }
            await guard();
            try {
              await remote.createYaml(
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
          final snapshot = await _snapshot(fileId);
          file = snapshot.$1;
          if (file.properties['antirknWorkspace'] != draft.workspaceId ||
              file.properties['antirknUser'] !=
                  (entry['owner'] ?? draft.userId) ||
              !file.editable ||
              file.properties['antirknDeleted'] != null ||
              !file.binary ||
              file.trashed) {
            throw const PublicationFailure(PublicationIssue.invalid);
          }
          if (settings.access == PublicationAccess.private) {
            await remote.checkPrivate(fileId);
          }
          final head = file.properties['antirknHead'];
          if (head != draft.headId && !draft.ancestors.contains(head)) {
            throw const PublicationFailure(PublicationIssue.conflict);
          }
          final hash = await _hash(snapshot.$2);
          if (hash != draft.hash || head != draft.headId) {
            await guard();
            final props = {
              'antirknHead': draft.headId,
              'antirknExecutor': draft.deviceId,
              'antirknHash': draft.hash,
            };
            if (hash == draft.hash) {
              await remote.updateProperties(file, props);
            } else {
              await remote.updateFile(file, draft.bytes, properties: props);
            }
            final verified = await _snapshot(fileId);
            file = verified.$1;
            if (await _hash(verified.$2) != draft.hash ||
                file.properties['antirknHead'] != draft.headId) {
              throw const PublicationFailure(PublicationIssue.conflict);
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
        await _markCreated(registryId, draft.userId, fileId, guard);
      }
      final beforeSource = await repository.readPublicationDocument(
        'result/$userId',
      );
      final previous = beforeSource == null
          ? <String, dynamic>{}
          : jsonDecode(beforeSource) as Map<String, dynamic>;
      String? permissionId = previous['fileId'] == fileId
          ? previous['permissionId'] as String?
          : null;
      String? url = previous['fileId'] == fileId
          ? previous['url'] as String?
          : null;
      if (settings.access == PublicationAccess.link) {
        await guard();
        permissionId = await remote.enableLink(fileId);
        file = await remote.getFile(fileId);
        url ??= file.downloadUrl;
        if (url == null) {
          throw const PublicationFailure(PublicationIssue.linkUnavailable);
        }
        await remote.verifyPublicLink(url, draft.bytes);
      } else if (permissionId != null) {
        await guard();
        await remote.removeLink(fileId, permissionId);
        permissionId = null;
      }
      await guard();
      final finalSnapshot = await _snapshot(fileId);
      if (finalSnapshot.$1.properties['antirknHead'] != draft.headId ||
          await _hash(finalSnapshot.$2) != draft.hash) {
        throw const PublicationFailure(PublicationIssue.conflict);
      }
      final result = <String, dynamic>{
        'version': entry['binding'] == null ? 1 : 2,
        'binding': ?entry['binding'],
        'owner': ?entry['owner'],
        'resourceKey': ?entry['resourceKey'],
        'fileId': fileId,
        'registryId': registryId,
        'head': draft.headId,
        'hash': draft.hash,
        'executor': finalSnapshot.$1.properties['antirknExecutor'],
        'access': settings.access.name,
        'url': url,
        'permissionId': permissionId,
      };
      await repository.writePublicationDocument(
        'result/$userId',
        canonicalJson(result),
        expectedSource: beforeSource,
      );
      await saveQueue({
        ...queue,
        'status': 'published',
        'issue': null,
        'attempt': 0,
        'retryAt': now().millisecondsSinceEpoch + 300000,
      });
      return queue;
    } on SyncTransportFailure catch (e) {
      if (e.issue == SyncTransportIssue.cancelled) rethrow;
      rethrow;
    } on SyncMergeFailure {
      await saveQueue({
        ...queue,
        'status': 'waiting',
        'issue': 'changed',
        'retryAt': now().millisecondsSinceEpoch + 5000,
      });
      return queue;
    } on PublicationFailure catch (e) {
      final attempt = (queue['attempt'] as int? ?? 0) + 1;
      final seconds =
          (5 * (1 << (attempt - 1).clamp(0, 6))).clamp(5, 300) + jitter(4);
      final retry = e.retryAfter != null && e.retryAfter!.inSeconds > seconds
          ? e.retryAfter!.inSeconds
          : seconds;
      await saveQueue({
        ...queue,
        'status': 'error',
        'issue': e.issue.name,
        'attempt': attempt,
        'retryAt': now().millisecondsSinceEpoch + retry * 1000,
      });
      return queue;
    }
  }

  Future<String> _registry(
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
        _decodeRegistry(snapshot.$2, draft.workspaceId);
        _cachedRegistryId = id;
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
  ) async {
    String? candidate;
    for (var attempt = 0; attempt < 8; attempt++) {
      final snapshot = await _snapshot(registryId);
      final value = _decodeRegistry(snapshot.$2, draft.workspaceId);
      final users = value['users'] as Map<String, dynamic>;
      if (users[draft.userId] case final Map existing) {
        if (existing['pending'] == true) {
          await _finishBinding(
            registryId,
            draft,
            Map<String, dynamic>.from(existing),
            guard,
          );
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
          snapshot.$1,
          _bytes(next),
          properties: const {},
        );
      } on PublicationFailure catch (e) {
        if (e.issue != PublicationIssue.conflict) rethrow;
      }
    }
    throw const PublicationFailure(PublicationIssue.conflict);
  }

  Future<void> _markCreated(
    String registryId,
    String userId,
    String fileId,
    Future<void> Function() guard,
  ) async {
    for (var attempt = 0; attempt < 6; attempt++) {
      final snapshot = await _snapshot(registryId);
      final value =
          jsonDecode(utf8.decode(snapshot.$2)) as Map<String, dynamic>;
      final users = value['users'] as Map<String, dynamic>;
      final entry = users[userId] as Map<String, dynamic>;
      if (entry['fileId'] != fileId) {
        throw const PublicationFailure(PublicationIssue.conflict);
      }
      if (entry['created'] == true) return;
      await guard();
      try {
        await remote.updateFile(
          snapshot.$1,
          _bytes({
            ...value,
            'users': {
              ...users,
              userId: {...entry, 'created': true},
            },
          }),
          properties: const {},
        );
        return;
      } on PublicationFailure catch (e) {
        if (e.issue != PublicationIssue.conflict) rethrow;
      }
    }
    throw const PublicationFailure(PublicationIssue.conflict);
  }

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

  Future<(PublicationFile, Uint8List)> _snapshot(String id) async {
    final before = await remote.getFile(id);
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
