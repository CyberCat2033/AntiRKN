part of 'publication_coordinator.dart';

extension PublicationBinding on PublicationCoordinator {
  void _resourceKey(Map value) {
    final target = PublicationTarget(
      value['fileId'] as String,
      resourceKey: value['resourceKey'] as String?,
    );
    if (remote case final PublicationResourceKeys keys) {
      keys.useResourceKey(target);
    } else if (target.resourceKey != null) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
  }

  Future<PublicationBindingPreview> inspectBinding(
    String userId,
    PublicationTarget target,
  ) async {
    final settingsSource = await repository.readPublicationDocument('settings');
    if (settingsSource == null) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    final settings = PublicationSettings.fromJson(
      jsonDecode(settingsSource) as Map<String, dynamic>,
    );
    if (!settings.enabled ||
        !settings.folderReady ||
        settings.accountKey != remote.accountKey) {
      throw const PublicationFailure(PublicationIssue.accountChanged);
    }
    final draft = await repository.readPublicationDraft(userId);
    if (draft != null) {
      if (eligible != null && !await eligible!(draft)) {
        throw const PublicationFailure(PublicationIssue.invalid);
      }
      await repository.checkPublicationDraft(draft);
    }
    final effectiveWorkspaceId = draft?.workspaceId ?? workspaceId ?? '';
    final folder = await remote.getFile(settings.folderId);
    final pointer = effectiveWorkspaceId.isNotEmpty
        ? folder.properties['antirknRegistry.$effectiveWorkspaceId']
        : null;
    String? registryId;
    Map<String, dynamic>? entry;
    if (pointer != null) {
      if (!pointer.startsWith('ready:')) {
        throw const PublicationFailure(PublicationIssue.conflict);
      }
      registryId = pointer.substring(6);
      final snapshot = await _snapshot(registryId);
      final users =
          _decodeRegistry(snapshot.$2, effectiveWorkspaceId)['users'] as Map;
      if (users[userId] case final Map existing) {
        entry = Map<String, dynamic>.from(existing);
      }
      for (final e in users.entries) {
        if (e.key != userId &&
            (e.value['fileId'] == target.fileId ||
                e.value['previous']?['fileId'] == target.fileId)) {
          throw const PublicationFailure(PublicationIssue.conflict);
        }
      }
    }
    if (entry?['pending'] != true && entry?['fileId'] == target.fileId) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    _resourceKey({'fileId': target.fileId, 'resourceKey': target.resourceKey});
    final before = await remote.getFile(target.fileId);
    final owner = before.properties['antirknUser'];
    if (!before.binary || before.trashed) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    if (!before.editable) {
      throw const PublicationFailure(PublicationIssue.forbidden);
    }
    if (before.properties['antirknDeleted'] != null ||
        owner != null &&
            !(entry?['pending'] == true &&
                (owner == entry?['owner'] ||
                    target.fileId == entry?['previous']?['fileId'] &&
                        owner == 'retired:$userId')) ||
        effectiveWorkspaceId.isNotEmpty &&
            before.properties['antirknWorkspace'] != null &&
            before.properties['antirknWorkspace'] != effectiveWorkspaceId) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    final bytes = await remote.download(target.fileId);
    if (bytes.length > publicationProfileLimit) {
      throw const PublicationFailure(PublicationIssue.size);
    }
    final after = await remote.getFile(target.fileId);
    if (before.etag != after.etag) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    if (settings.access == PublicationAccess.private) {
      await remote.checkPrivate(target.fileId);
    }
    String content;
    try {
      content = utf8.decode(bytes);
    } catch (_) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    if (content.contains('\u0000')) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    final file = PublicationFile(
      id: after.id,
      name: after.name,
      mimeType: after.mimeType,
      version: after.version,
      etag: after.etag,
      editable: after.editable,
      properties: after.properties,
      shared: after.shared,
      downloadUrl: after.downloadUrl,
      resourceKey: target.resourceKey ?? after.resourceKey,
    );
    return PublicationBindingPreview(
      file: file,
      content: content,
      hash: await PublicationCoordinator._hash(bytes),
      draft: draft,
      settingsSource: settingsSource,
      intentSource: await repository.readPublicationDocument('binding/$userId'),
      registryId: registryId,
      entry: entry,
      workspaceId: effectiveWorkspaceId,
      userId: userId,
    );
  }

  /// Call only after the user confirms this exact preview and future updates.
  /// Persisting the consent precedes every remote mutation.
  Future<void> acceptBinding(PublicationBindingPreview preview) async {
    final draft = preview.draft;
    if (draft != null) {
      await repository.checkPublicationDraft(draft);
      if (eligible != null && !await eligible!(draft)) {
        throw const PublicationFailure(PublicationIssue.conflict);
      }
    }
    if (await repository.readPublicationDocument('settings') !=
            preview.settingsSource ||
        remote.accountKey !=
            PublicationSettings.fromJson(
              jsonDecode(preview.settingsSource) as Map<String, dynamic>,
            ).accountKey) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    _resourceKey({
      'fileId': preview.file.id,
      'resourceKey': preview.file.resourceKey,
    });
    if ((await remote.getFile(preview.file.id)).etag != preview.file.etag) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    final settings = PublicationSettings.fromJson(
      jsonDecode(preview.settingsSource) as Map<String, dynamic>,
    );
    final effectiveWorkspaceId =
        draft?.workspaceId ?? preview.workspaceId ?? '';
    final effectiveUserId = draft?.userId ?? preview.userId ?? '';
    final intent = <String, dynamic>{
      'version': 1,
      'id': newVpnId(),
      'workspaceId': effectiveWorkspaceId,
      'userId': effectiveUserId,
      'accountKey': remote.accountKey,
      'registryId': preview.registryId,
      'fileId': preview.file.id,
      'name': preview.file.name,
      'etag': preview.file.etag,
      'hash': preview.hash,
      'resourceKey': ?preview.file.resourceKey,
      'priorOwner': ?preview.file.properties['antirknUser'],
      'expectedEntry': preview.entry,
      'previous': (preview.entry?['pending'] == true)
          ? (preview.entry?['previous'])
          : preview.entry,
      'access': settings.access.name,
      if (draft != null) 'profileHead': draft.headId,
      if (draft != null) 'profileHash': draft.hash,
    };
    validatePublicationBinding(intent);
    await repository.writePublicationDocument(
      'binding/$effectiveUserId',
      canonicalJson(intent),
      expectedSource: preview.intentSource,
    );
  }

  Future<void> _startBinding(
    String registryId,
    PublicationDraft draft,
    Map<String, dynamic> intent,
    Future<void> Function() guard,
  ) async {
    validatePublicationBinding(intent);
    final settingsSource = await repository.readPublicationDocument('settings');
    if (settingsSource == null ||
        PublicationSettings.fromJson(
              jsonDecode(settingsSource) as Map<String, dynamic>,
            ).access.name !=
            intent['access']) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }

    if (intent['workspaceId'] != draft.workspaceId ||
        intent['userId'] != draft.userId ||
        intent['accountKey'] != remote.accountKey ||
        intent['registryId'] != null && intent['registryId'] != registryId) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    for (var attempt = 0; attempt < 8; attempt++) {
      final snapshot = await _snapshot(registryId);
      final registry = _decodeRegistry(snapshot.$2, draft.workspaceId);
      final users = registry['users'] as Map<String, dynamic>;
      final entry = users[draft.userId] as Map?;
      if (entry?['binding'] == intent['id']) return;
      if (canonicalJson(entry) != canonicalJson(intent['expectedEntry'])) {
        throw const PublicationFailure(PublicationIssue.conflict);
      }
      for (final e in users.entries) {
        if (e.key != draft.userId &&
            (e.value['fileId'] == intent['fileId'] ||
                e.value['previous']?['fileId'] == intent['fileId'])) {
          throw const PublicationFailure(PublicationIssue.conflict);
        }
      }
      if (entry?['pending'] == true && entry?['fileId'] != intent['fileId']) {
        // Stop the previous approved attempt before changing its destination.
        // An in-flight write with the old ETag must fail after this fence.
        _resourceKey(entry!);
        PublicationFile? abandoned;
        try {
          abandoned = await remote.getFile(entry['fileId'] as String);
        } on PublicationFailure catch (e) {
          if (e.issue != PublicationIssue.missing) rethrow;
        }
        if (abandoned != null && !abandoned.trashed) {
          final oldConsent = entry['consent'] as Map;
          final owned = abandoned.properties['antirknUser'] == entry['owner'];
          if (owned || abandoned.etag == oldConsent['etag']) {
            await guard();
            await remote.updateProperties(abandoned, {
              if (owned) 'antirknUser': 'retired:${draft.userId}',
              'antirknStoppedBinding': entry['binding'] as String,
            });
          }
        }
      }
      await guard();
      try {
        await remote.updateFile(
          snapshot.$1,
          PublicationCoordinator._bytes({
            ...registry,
            'version': 2,
            'users': {
              ...users,
              draft.userId: {
                'fileId': intent['fileId'],
                'created': true,
                'binding': intent['id'],
                'owner': 'bound:${draft.userId}:${intent['id']}',
                'resourceKey': ?intent['resourceKey'],
                'pending': true,
                'previous': intent['previous'],
                'consent': intent,
              },
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

  Future<void> _finishBinding(
    String registryId,
    PublicationDraft draft,
    Map<String, dynamic> entry,
    Future<void> Function() guard,
  ) async {
    final intent = Map<String, dynamic>.from(entry['consent'] as Map);
    validatePublicationBinding(intent);
    final settingsSource = await repository.readPublicationDocument('settings');
    if (settingsSource == null ||
        PublicationSettings.fromJson(
              jsonDecode(settingsSource) as Map<String, dynamic>,
            ).access.name !=
            intent['access']) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }

    if (intent['accountKey'] != remote.accountKey ||
        intent['userId'] != draft.userId ||
        intent['workspaceId'] != draft.workspaceId) {
      throw const PublicationFailure(PublicationIssue.accountChanged);
    }
    Future<void> check() async {
      await guard();
      final snapshot = await _snapshot(registryId);
      final users =
          _decodeRegistry(snapshot.$2, draft.workspaceId)['users'] as Map;
      if (users[draft.userId]?['binding'] != entry['binding']) {
        throw const PublicationFailure(PublicationIssue.conflict);
      }
    }

    // Fence publishers holding the previous registry before touching new content.
    // Only metadata changes: the old bytes and access permissions are retained.
    final previous = entry['previous'] as Map?;
    if (previous != null) {
      _resourceKey(previous);
      PublicationFile? old;
      try {
        old = await remote.getFile(previous['fileId'] as String);
      } on PublicationFailure catch (e) {
        if (e.issue != PublicationIssue.missing) rethrow;
        if (previous['created'] != true) {
          await check();
          final settings = PublicationSettings.fromJson(
            jsonDecode((await repository.readPublicationDocument('settings'))!)
                as Map<String, dynamic>,
          );
          try {
            await remote.createYaml(
              fileId: previous['fileId'] as String,
              folderId: settings.folderId,
              name: '${draft.name}.yml',
              workspaceId: draft.workspaceId,
              userId: 'retired:${draft.userId}',
              headId: draft.headId,
              executorId: draft.deviceId,
              bytes: draft.bytes,
            );
          } on PublicationFailure catch (e) {
            if (e.issue != PublicationIssue.conflict) rethrow;
          }
          old = await remote.getFile(previous['fileId'] as String);
        }
      }
      if (old != null &&
          !old.trashed &&
          old.properties['antirknUser'] != 'retired:${draft.userId}') {
        if (old.properties['antirknWorkspace'] != draft.workspaceId ||
            old.properties['antirknUser'] !=
                (previous['owner'] ?? draft.userId)) {
          throw const PublicationFailure(PublicationIssue.conflict);
        }
        await check();
        await remote.updateProperties(old, {
          'antirknUser': 'retired:${draft.userId}',
        });
      }
    }
    _resourceKey(entry);
    final fileId = entry['fileId'] as String;
    var file = await remote.getFile(fileId);
    if (!file.binary ||
        !file.editable ||
        file.trashed ||
        file.properties['antirknDeleted'] != null) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    if (intent['access'] == 'private') await remote.checkPrivate(fileId);
    if (file.properties['antirknUser'] != entry['owner']) {
      if (file.etag != intent['etag'] ||
          file.properties['antirknUser'] != intent['priorOwner']) {
        throw const PublicationFailure(PublicationIssue.conflict);
      }
      await check();
      await remote.updateFile(
        file,
        draft.bytes,
        properties: {
          'antirknWorkspace': draft.workspaceId,
          'antirknUser': entry['owner'] as String,
          'antirknHead': draft.headId,
          'antirknExecutor': draft.deviceId,
          'antirknHash': draft.hash,
        },
      );
    }
    final snapshot = await _snapshot(fileId);
    file = snapshot.$1;
    final head = file.properties['antirknHead'];
    if (file.properties['antirknUser'] != entry['owner'] ||
        file.properties['antirknWorkspace'] != draft.workspaceId ||
        head != draft.headId && !draft.ancestors.contains(head)) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    if (intent['access'] == 'link') {
      await check();
      await remote.enableLink(fileId);
      file = await remote.getFile(fileId);
      if (file.downloadUrl == null) {
        throw const PublicationFailure(PublicationIssue.linkUnavailable);
      }
      await remote.verifyPublicLink(file.downloadUrl!, snapshot.$2);
    }
    await check();
    for (var attempt = 0; attempt < 6; attempt++) {
      final current = await _snapshot(registryId);
      final registry = _decodeRegistry(current.$2, draft.workspaceId);
      final users = registry['users'] as Map;
      final latest = users[draft.userId] as Map;
      if (latest['binding'] != entry['binding']) {
        throw const PublicationFailure(PublicationIssue.conflict);
      }
      if (latest['pending'] != true) return;
      await guard();
      try {
        await remote.updateFile(
          current.$1,
          PublicationCoordinator._bytes({
            ...registry,
            'users': {
              ...users,
              draft.userId: {
                'fileId': fileId,
                'created': true,
                'binding': entry['binding'],
                'owner': entry['owner'],
                'resourceKey': ?entry['resourceKey'],
              },
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
}
