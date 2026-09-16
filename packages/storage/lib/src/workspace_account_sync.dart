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

LocalChange _accountChange(LocalChange event, String workspace) {
  final header = event.header.toJson();
  header['workspaceId'] = workspace;
  var source = event.source;
  final kind = event.header.entityKind;
  if (source != null &&
      (kind == ChangeEntityKind.workspace ||
          kind == ChangeEntityKind.vpnWorkspace ||
          kind == ChangeEntityKind.vpnServerState ||
          kind == ChangeEntityKind.profile)) {
    final value = jsonDecode(source) as Map<String, dynamic>;
    if (kind == ChangeEntityKind.workspace ||
        kind == ChangeEntityKind.vpnWorkspace) {
      header['entityId'] = workspace;
      value['id'] = workspace;
    } else {
      final field = kind == ChangeEntityKind.profile
          ? 'publicationWorkspaceId'
          : 'resourceWorkspaceId';
      value.putIfAbsent(field, () => event.header.workspaceId);
    }
    source = canonicalJson(value);
  }
  return LocalChange(header: ChangeHeader.fromJson(header), source: source);
}

/// Google account access is the membership credential, as requested by the
/// owner. Keys live in private appDataFolder, not public profile files. This is
/// account-protected encryption, NOT end-to-end secrecy from the provider.
final class _WorkspaceAccountSync {
  _WorkspaceAccountSync(this.store, this.journal, this.remote);
  final WorkspaceDatabase store;
  final SyncTransportDatabase journal;
  final SyncRemoteStore remote;
  final _keys = <String, _SyncKey>{};
  final _versions = <String, String>{};

  Future<void> prepare(SyncCancellation cancel) async {
    if (remote is! SyncAccountStore) return;
    final accountStore = remote as SyncAccountStore;
    if (remote.accountKey != journal.accountKey) {
      throw const SyncTransportFailure(SyncTransportIssue.changed);
    }
    final own = await store._serial(store._sync.readKey);
    final bytes = Uint8List.fromList(
      utf8.encode(
        canonicalJson({
          'version': 1,
          'account': remote.accountKey,
          'workspaceId': journal.workspaceId,
          'syncKey': {
            'version': 1,
            'keyVersion': own.version,
            'key': base64Encode(await own.secret.extractBytes()),
          },
        }),
      ),
    );
    try {
      final name = '$syncAccountKeyPrefix${journal.workspaceId}';
      final digest = (await Sha256().hash(
        bytes,
      )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      final receiptId = 'account-key:${journal.workspaceId}';
      var receipt = await journal.readUpload(receiptId);
      receipt ??= await journal.reserveUpload(
        SyncUploadReceipt(
          changeId: receiptId,
          fileId: await remote.generateFileId(),
          digest: digest,
          size: bytes.length,
        ),
      );
      if (receipt.digest != digest || receipt.size != bytes.length) {
        throw const SyncTransportFailure(SyncTransportIssue.conflict);
      }
      // Even a confirmed receipt is checked: app data may have been removed.
      cancel.check();
      try {
        await _verifyOwn(receipt, name);
      } on SyncTransportFailure catch (error) {
        if (error.issue != SyncTransportIssue.notFound) rethrow;
        try {
          await accountStore.createAccountKey(receipt.fileId, name, bytes);
        } on SyncTransportFailure catch (error) {
          if (error.issue != SyncTransportIssue.conflict) rethrow;
        }
        cancel.check();
        await _verifyOwn(receipt, name);
      }
      await journal.confirmUpload(receipt);
      String? page;
      final pages = <String>{};
      var count = 0;
      do {
        cancel.check();
        final result = await accountStore.listAccountKeys(pageToken: page);
        for (final file in result.files) {
          cancel.check();
          if (file.removed || !file.name.startsWith(syncAccountKeyPrefix)) {
            continue;
          }
          if (++count > 1000 || file.size > 4096) {
            throw const SyncTransportFailure(SyncTransportIssue.limit);
          }
          if (_versions[file.id] == file.version) continue;
          final payload = await remote.download(file.id);
          try {
            if (payload.length != file.size || payload.length > 4096) {
              throw const FormatException();
            }
            final value = jsonDecode(utf8.decode(payload)) as Map;
            final workspace = value['workspaceId'] as String;
            if (value.length != 4 ||
                value['version'] != 1 ||
                value['account'] != remote.accountKey ||
                !RegExp(r'^[a-f0-9]{32}$').hasMatch(workspace) ||
                file.name != '$syncAccountKeyPrefix$workspace') {
              throw const FormatException();
            }
            final key = _decodeSyncKey(value['syncKey']);
            final old = workspace == journal.workspaceId
                ? own
                : _keys[workspace];
            if (old != null &&
                (old.version != key.version ||
                    base64Encode(await old.secret.extractBytes()) !=
                        base64Encode(await key.secret.extractBytes()))) {
              key.dispose();
              throw const SyncTransportFailure(SyncTransportIssue.conflict);
            }
            _keys.remove(workspace)?.dispose();
            _keys[workspace] = key;
            _versions[file.id] = file.version;
          } on SyncTransportFailure {
            rethrow;
          } catch (_) {
            throw const SyncTransportFailure(SyncTransportIssue.invalid);
          } finally {
            payload.fillRange(0, payload.length, 0);
          }
        }
        page = result.nextPageToken;
        if (page != null && (!pages.add(page) || pages.length > 100)) {
          throw const SyncTransportFailure(SyncTransportIssue.invalid);
        }
      } while (page != null);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      own.dispose();
    }
  }

  Future<void> _verifyOwn(SyncUploadReceipt receipt, String name) async {
    final file = await remote.getFile(receipt.fileId);
    if (file.removed || file.name != name || file.size != receipt.size) {
      throw const SyncTransportFailure(SyncTransportIssue.conflict);
    }
    final bytes = await remote.download(receipt.fileId);
    try {
      if ((await Sha256().hash(
            bytes,
          )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join() !=
          receipt.digest) {
        throw const SyncTransportFailure(SyncTransportIssue.conflict);
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  /// Translate only the workspace container. Entity IDs, transaction IDs,
  /// ancestry, deletions, credentials and operation ownership stay intact.
  Future<Uint8List> localPacket(Uint8List bytes) async {
    if (bytes.length < syncHeaderBytes + syncNonceBytes + syncTagBytes ||
        bytes.length > syncMaxPacketBytes ||
        ascii.decode(bytes.sublist(0, 8), allowInvalid: true) != syncMagic) {
      throw const SyncPacketFailure(SyncPacketIssue.invalid);
    }
    if (bytes[syncVersionOffset] != syncVersion ||
        bytes[syncSuiteOffset] != syncSuite) {
      throw const SyncPacketFailure(SyncPacketIssue.version);
    }
    final workspace = bytes
        .sublist(syncWorkspaceIdOffset, syncChangeIdOffset)
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    final own = workspace == journal.workspaceId;
    final key = own
        ? await store._serial(store._sync.readKey)
        : _keys[workspace];
    if (key == null) throw const SyncPacketFailure(SyncPacketIssue.workspace);
    late final LocalChange event;
    try {
      event = await _openPacketInBackground(
        workspace,
        key.version,
        Uint8List.fromList(await key.secret.extractBytes()),
        bytes,
      );
    } finally {
      if (own) key.dispose();
    }
    _validateSyncChange(event);
    final mapped = _accountChange(event, journal.workspaceId);
    if (own && mapped.source == event.source) return bytes;
    final local = await store._serial(store._sync.readKey);
    try {
      return await _sealPacketInBackground(
        journal.workspaceId,
        local.version,
        Uint8List.fromList(await local.secret.extractBytes()),
        mapped,
      );
    } finally {
      local.dispose();
    }
  }

  void close() {
    for (final key in _keys.values) {
      key.dispose();
    }
    _keys.clear();
    _versions.clear();
  }
}
