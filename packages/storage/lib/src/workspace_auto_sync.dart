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
    if (!await _snapshotReplaceable(localState) ||
        await _unsentSnapshotPending(localState)) {
      return false;
    }
    final file = await cloud.findSnapshot();
    if (file == null) return false;
    if (!localState.empty && !await _snapshotRemoteChanged(file)) {
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
      // Any local file left here holds no unsent edits (checked above). It
      // would describe the replaced state, so it must not outlive the restore.
      final local = File('$_path.current-snapshot');
      if (await local.exists()) await local.delete();
      await _restoreCloudSnapshot(snapshot, stamp, file.id, file.version);
      return true;
    } finally {
      key.destroy();
    }
  }

  /// Empty, or bound to the cloud and unchanged since the last confirmed
  /// upload or pull: the cloud snapshot may replace it without losing edits.
  Future<bool> _snapshotReplaceable(
    ({bool empty, int sequence, String workspaceId}) state,
  ) async =>
      state.empty ||
      (await readSetting('syncSnapshotBound') == state.workspaceId &&
          await readSetting('syncSnapshotLocalSequence') ==
              '${state.sequence}');

  Future<bool> _snapshotRemoteChanged(SyncRemoteFile file) async =>
      await readSetting('syncSnapshotRemoteFileId') != file.id ||
      await readSetting('syncSnapshotRemoteVersion') != file.version;

  /// True while an unconfirmed local snapshot may hold edits absent from the
  /// cloud. An unconfirmed snapshot captured at the current sequence of a
  /// replaceable workspace holds none; it is discarded so it cannot block.
  Future<bool> _unsentSnapshotPending(
    ({bool empty, int sequence, String workspaceId}) state,
  ) async {
    final local = File('$_path.current-snapshot');
    if (!await local.exists()) return false;
    if (await readSetting('syncSnapshotUploaded') ==
        await _snapshotDigest(await local.readAsBytes())) {
      return false;
    }
    if (await readSetting('syncSnapshotPendingSequence') !=
            '${state.sequence}' ||
        !await _snapshotReplaceable(state)) {
      return true;
    }
    await local.delete();
    return false;
  }
}

Future<String> _snapshotDigest(Uint8List bytes) async => (await Sha256().hash(
  bytes,
)).bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

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
    final digest = await _snapshotDigest(local);
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
      final state = await store._snapshotLocalState();
      if (await store._snapshotReplaceable(state) &&
          !await store._unsentSnapshotPending(state)) {
        // Nothing here is missing from the cloud. Recovery has nothing to send;
        // a newer cloud snapshot is received by a pull, never overwritten.
        if (forceRecovery) return const AutoSyncResult();
        cancellation.check();
        final file = await remote.findSnapshot();
        if (file != null &&
            (state.empty || await store._snapshotRemoteChanged(file))) {
          return const AutoSyncResult(remoteNewer: true);
        }
        if (state.empty) return const AutoSyncResult();
      }
      Uint8List local;
      int capturedSequence;
      if (forceRecovery) {
        if (!await _local.exists()) return const AutoSyncResult();
        local = await _local.readAsBytes();
        if (await store.readSetting('syncSnapshotUploaded') ==
            await _snapshotDigest(local)) {
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
      }
      final result = await _upload(local, cancellation, capturedSequence);
      // Bounding the legacy journal is housekeeping after a confirmed upload;
      // it never decides whether the snapshot reaches the cloud.
      try {
        await store._compactHistory();
      } catch (_) {}
      return result;
    } finally {
      _running = false;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}
