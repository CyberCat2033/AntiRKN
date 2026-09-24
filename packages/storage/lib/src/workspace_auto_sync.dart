part of 'workspace_database.dart';

extension WorkspaceAutomaticSync on WorkspaceDatabase {
  Future<AutoSyncSession> openAutoSync(
    SyncAccessTokenProvider tokens, {
    SyncRemoteStore? remote,
    DriveHttp? http,
  }) async {
    final cloud = remote ?? GoogleDriveSyncStore(tokens: tokens, http: http);
    if (cloud is! SyncSnapshotStore || cloud.accountKey != tokens.accountKey) {
      throw const SyncTransportFailure(SyncTransportIssue.changed);
    }
    return _SnapshotAutoSync(this, cloud as SyncSnapshotStore);
  }

  /// Called before controllers open. An unbound or locally edited workspace is
  /// never replaced implicitly, including on the first launch of this format.
  Future<bool> pullCurrentSnapshot(
    SyncAccessTokenProvider tokens, {
    SyncSnapshotStore? remote,
  }) async {
    final cloud = remote ?? GoogleDriveSyncStore(tokens: tokens);
    if (cloud.accountKey != tokens.accountKey) {
      throw const SyncTransportFailure(SyncTransportIssue.changed);
    }
    final localState = await _snapshotLocalState();
    final localFile = File('$_path.current-snapshot');
    if (await localFile.exists()) {
      final uploaded = await readSetting('syncSnapshotUploaded');
      final digest = (await Sha256().hash(
        await localFile.readAsBytes(),
      )).bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
      if (uploaded != digest) return false;
    }
    if (!localState.empty &&
        (await readSetting('syncSnapshotBound') != localState.workspaceId ||
            await readSetting('syncSnapshotLocalSequence') !=
                '${localState.sequence}')) {
      return false;
    }
    final file = await cloud.findSnapshot();
    if (file == null) return false;
    if (!localState.empty &&
        await readSetting('syncSnapshotRemoteFileId') == file.id &&
        await readSetting('syncSnapshotRemoteVersion') == file.version) {
      return false;
    }
    final key = await _SnapshotAutoSync.readKey(cloud);
    if (key == null) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    try {
      final bytes = await cloud.readSnapshot(file.id);
      final source = await _SnapshotAutoSync.open(
        bytes,
        key,
        'cloud:${cloud.accountKey}',
      );
      final snapshot = await _validateBackupInBackground(source);
      if (!localState.empty &&
          snapshot.summary.workspaceId != localState.workspaceId) {
        throw const SyncTransportFailure(SyncTransportIssue.conflict);
      }
      final stamp = await _snapshotStamp();
      await _restoreCloudSnapshot(snapshot, stamp, file.id, file.version);
      return true;
    } finally {
      key.destroy();
    }
  }
}

/// A local snapshot is written atomically before any network request. A failed
/// upload leaves its encrypted bytes and an unmatched receipt for next start.
final class _SnapshotAutoSync implements AutoSyncSession {
  _SnapshotAutoSync(this.store, this.remote);
  final WorkspaceDatabase store;
  final SyncSnapshotStore remote;
  bool _closed = false, _running = false;
  static const _magic = [65, 110, 116, 105, 82, 75, 78, 83, 1];
  File get _local => File('${store._path}.current-snapshot');

  static Future<Uint8List> seal(
    String source,
    SecretKey key,
    String scope,
  ) async {
    final plain = utf8.encode(source);
    try {
      if (plain.length > maxWorkspaceBackupBytes - 37) {
        throw const SyncTransportFailure(SyncTransportIssue.limit);
      }
      final box = await AesGcm.with256bits().encrypt(
        plain,
        secretKey: key,
        aad: utf8.encode('antirkn:single-snapshot:1:$scope'),
      );
      return Uint8List.fromList([..._magic, ...box.concatenation()]);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  static Future<String> open(
    Uint8List bytes,
    SecretKey key,
    String scope,
  ) async {
    if (bytes.length < 37 ||
        bytes.length > maxWorkspaceBackupBytes ||
        !List.generate(
          _magic.length,
          (i) => bytes[i] == _magic[i],
        ).every((value) => value)) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    try {
      final plain = await AesGcm.with256bits().decrypt(
        SecretBox.fromConcatenation(
          bytes.sublist(_magic.length),
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: key,
        aad: utf8.encode('antirkn:single-snapshot:1:$scope'),
      );
      try {
        return utf8.decode(plain);
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
    } catch (_) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
  }

  static Future<SecretKeyData?> readKey(SyncSnapshotStore remote) async {
    final bytes = await remote.readSnapshotKey();
    if (bytes == null) return null;
    if (bytes.length != 32) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    return SecretKeyData(
      Uint8List.fromList(bytes),
      overwriteWhenDestroyed: true,
    );
  }

  Future<SecretKeyData> _key(SyncRemoteFile? file) async {
    final existing = await readKey(remote);
    if (existing != null) return existing;
    if (file != null) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    final raw = Uint8List.fromList(
      await (await AesGcm.with256bits().newSecretKey()).extractBytes(),
    );
    try {
      await remote.createSnapshotKey(raw);
    } on SyncTransportFailure catch (error) {
      if (error.issue != SyncTransportIssue.conflict) rethrow;
      final raced = await readKey(remote);
      if (raced == null) rethrow;
      raw.fillRange(0, raw.length, 0);
      return raced;
    }
    return SecretKeyData(raw, overwriteWhenDestroyed: true);
  }

  Future<String> _digest(Uint8List bytes) async => (await Sha256().hash(
    bytes,
  )).bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  Future<AutoSyncResult> _recordUpload(
    _BackupSnapshot snapshot,
    SyncRemoteFile written,
    int capturedSequence,
    String digest,
  ) async {
    await store.writeSetting('syncSnapshotBound', snapshot.summary.workspaceId);
    await store.writeSetting('syncSnapshotRemoteFileId', written.id);
    await store.writeSetting('syncSnapshotRemoteVersion', written.version);
    await store.writeSetting('syncSnapshotLocalSequence', '$capturedSequence');
    await store.writeSetting('syncSnapshotUploaded', digest);
    return AutoSyncResult(lastSuccess: DateTime.now().toUtc());
  }

  Future<AutoSyncResult> _upload(
    Uint8List local,
    SyncCancellation cancel,
    int capturedSequence,
  ) async {
    cancel.check();
    final digest = await _digest(local);
    final source = await open(local, store._key, 'local');
    final snapshot = await _validateBackupInBackground(source);
    if (snapshot.summary.workspaceId !=
        (await store.readWorkspaceIdentity()).workspaceId) {
      throw const SyncTransportFailure(SyncTransportIssue.changed);
    }
    final file = await remote.findSnapshot();
    final bound = await store.readSetting('syncSnapshotBound');
    if (file != null &&
        (bound != snapshot.summary.workspaceId ||
            await store.readSetting('syncSnapshotRemoteFileId') != file.id ||
            await store.readSetting('syncSnapshotRemoteVersion') !=
                file.version)) {
      // A previous upload may have succeeded while its response was lost.
      // A different remote snapshot is never overwritten implicitly.
      final existingKey = await readKey(remote);
      if (existingKey == null) {
        throw const SyncTransportFailure(SyncTransportIssue.invalid);
      }
      try {
        final remoteSource = await open(
          await remote.readSnapshot(file.id),
          existingKey,
          'cloud:${remote.accountKey}',
        );
        if (remoteSource != source) {
          throw const SyncTransportFailure(SyncTransportIssue.conflict);
        }
        return _recordUpload(snapshot, file, capturedSequence, digest);
      } finally {
        existingKey.destroy();
      }
    }
    final key = await _key(file);
    try {
      final encrypted = await seal(source, key, 'cloud:${remote.accountKey}');
      cancel.check();
      await remote.writeSnapshot(file?.id, encrypted);
      final written = await remote.findSnapshot();
      if (written == null) {
        throw const SyncTransportFailure(SyncTransportIssue.notFound);
      }
      return _recordUpload(snapshot, written, capturedSequence, digest);
    } finally {
      key.destroy();
    }
  }

  @override
  Future<AutoSyncResult> exchange({
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
    bool forceRecovery = false,
  }) async {
    if (_closed || _running) {
      throw const SyncTransportFailure(SyncTransportIssue.changed);
    }
    _running = true;
    try {
      Uint8List local;
      int capturedSequence;
      if (forceRecovery) {
        if (!await _local.exists()) return const AutoSyncResult();
        local = await _local.readAsBytes();
        if (await store.readSetting('syncSnapshotUploaded') ==
            await _digest(local)) {
          return const AutoSyncResult();
        }
        capturedSequence =
            int.tryParse(
              await store.readSetting('syncSnapshotPendingSequence') ?? '',
            ) ??
            -1;
      } else {
        cancellation.check();
        final captured = await store._captureSnapshot();
        capturedSequence = captured.sequence;
        local = await seal(captured.source, store._key, 'local');
        await writeBackupFile(_local.path, local);
        await store.writeSetting(
          'syncSnapshotPendingSequence',
          '$capturedSequence',
        );
        await store._compactHistory();
      }
      return await _upload(local, cancellation, capturedSequence);
    } finally {
      _running = false;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}
