part of 'workspace_database.dart';

/// The startup pull stops waiting for the network at its deadline. Once the
/// local restore has begun it always finishes: data is never half replaced.
final class _PullDeadline {
  bool _committing = false, _expired = false;
  final _expiry = Completer<bool>();
  Future<bool> get expired => _expiry.future;

  void expire() {
    if (_committing || _expired) return;
    _expired = true;
    _expiry.complete(false);
  }

  /// Called synchronously right before the restore replaces local data.
  void commit() {
    if (_expired) {
      throw const SyncTransportFailure(SyncTransportIssue.cancelled);
    }
    _committing = true;
  }
}

/// A validated cloud snapshot newer than this device's data.
typedef _ReceivedSnapshot = ({SyncRemoteFile file, _BackupSnapshot snapshot});

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
  ///
  /// With a [deadline] the result is false once it passes while the network is
  /// still in progress; the abandoned pull then never touches local data, and
  /// the next launch tries again.
  Future<bool> pullCurrentSnapshot(
    SyncAccessTokenProvider tokens, {
    SyncSnapshotStore? remote,
    Duration? deadline,
  }) async {
    final cloud = remote ?? GoogleDriveSyncStore(tokens: tokens);
    if (cloud.accountKey != tokens.accountKey) {
      throw const SyncTransportFailure(SyncTransportIssue.changed);
    }
    if (deadline == null) return _pullSnapshot(cloud, null);
    final gate = _PullDeadline();
    final pull = _pullSnapshot(cloud, gate);
    final timer = Timer(deadline, gate.expire);
    try {
      return await Future.any([pull, gate.expired]);
    } finally {
      timer.cancel();
      pull.ignore();
    }
  }

  Future<bool> _pullSnapshot(
    SyncSnapshotStore cloud,
    _PullDeadline? deadline,
  ) async {
    var localState = await _snapshotLocalState();
    if (await _absorbCacheChanges(localState)) {
      localState = await _snapshotLocalState();
    }
    if (!await _snapshotReplaceable(localState) ||
        await _unsentSnapshotPending(localState)) {
      return false;
    }
    final received = await _newerCloudSnapshot(cloud, localState);
    if (received == null) return false;
    await _applyCloudSnapshot(received, commit: deadline?.commit);
    return true;
  }

  /// The cloud snapshot when it differs from the version this device last
  /// uploaded or received, validated. [held] is reused instead of another
  /// download while it is still the cloud version. One metadata request when
  /// nothing changed.
  Future<_ReceivedSnapshot?> _newerCloudSnapshot(
    SyncSnapshotStore cloud,
    ({bool empty, int sequence, String workspaceId}) state, {
    _ReceivedSnapshot? held,
  }) async {
    final file = await cloud.findSnapshot();
    if (file == null) return null;
    if (!state.empty && !await _snapshotRemoteChanged(file)) return null;
    if (held != null &&
        held.file.id == file.id &&
        held.file.version == file.version) {
      return held;
    }
    final source = await _openCloudSnapshot(
      cloud,
      await cloud.readSnapshot(file.id),
    );
    final snapshot = await _validateCloudSnapshot(source);
    if (!state.empty && snapshot.summary.workspaceId != state.workspaceId) {
      throw const SyncTransportFailure(SyncTransportIssue.conflict);
    }
    return (file: file, snapshot: snapshot);
  }

  /// Replaces local data of a replaceable workspace with [received]. [commit]
  /// runs synchronously right before the replacement begins.
  Future<void> _applyCloudSnapshot(
    _ReceivedSnapshot received, {
    void Function()? commit,
  }) async {
    final stamp = await _snapshotStamp();
    commit?.call();
    // Any local file left here holds no unsent edits (checked by the caller).
    // It would describe the replaced state, so it must not outlive the restore.
    final local = File('$_path.current-snapshot');
    if (await local.exists()) await local.delete();
    await _restoreCloudSnapshot(received.snapshot, stamp, received.file);
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

  /// A cloud snapshot this version can read. A newer format is refused
  /// without touching local data, and remembered so that this device keeps
  /// saying why until the app is updated.
  Future<_BackupSnapshot> _validateCloudSnapshot(String source) async {
    try {
      return await _validateBackupInBackground(source, cloud: true);
    } on BackupFailure catch (error) {
      if (error.issue != BackupIssue.version) rethrow;
      await writeSetting('syncSnapshotUnsupported', '1');
      throw const SyncTransportFailure(SyncTransportIssue.unsupportedVersion);
    }
  }

  /// Observations, compiled profiles and runner answers are local cache: when
  /// only they changed since the last confirmed upload or pull, the intent
  /// still equals the cloud and this device stays clean. True if absorbed.
  Future<bool> _absorbCacheChanges(
    ({bool empty, int sequence, String workspaceId}) state, {
    void Function(_CapturedSnapshot)? captured,
  }) async {
    if (state.empty ||
        await _snapshotReplaceable(state) ||
        await _unsentSnapshotPending(state) ||
        await readSetting('syncSnapshotBound') != state.workspaceId) {
      return false;
    }
    final intent = await readSetting('syncSnapshotIntent');
    if (intent == null || intent.isEmpty) return false;
    final capture = await _captureSnapshot();
    captured?.call(capture);
    if (capture.intent != intent || capture.workspaceId != state.workspaceId) {
      return false;
    }
    await writeSetting('syncSnapshotLocalSequence', '${capture.sequence}');
    return true;
  }

  Future<bool> _snapshotRemoteChanged(SyncRemoteFile file) async =>
      await readSetting('syncSnapshotRemoteFileId') != file.id ||
      await readSetting('syncSnapshotRemoteVersion') != file.version;

  /// The cloud version this device last uploaded or received, if any.
  Future<SyncRemoteFile?> _snapshotBoundFile(String workspaceId) async {
    final id = await readSetting('syncSnapshotRemoteFileId');
    final version = await readSetting('syncSnapshotRemoteVersion');
    if (await readSetting('syncSnapshotBound') != workspaceId ||
        id == null ||
        version == null) {
      return null;
    }
    return SyncRemoteFile(
      id: id,
      name: syncSnapshotName,
      size: 0,
      version: version,
      packet: false,
      etag: await readSetting('syncSnapshotRemoteEtag') ?? '',
    );
  }

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

  String _snapshotKeyScope(String accountKey) =>
      'sync-snapshot-key:$accountKey';

  /// The account's snapshot key, sealed with the device key and bound to the
  /// account. Null when absent, from another account or unreadable.
  Future<SecretKeyData?> _cachedSnapshotKey(String accountKey) async {
    final value = await readSetting('syncSnapshotKey');
    if (value == null || value.isEmpty) return null;
    try {
      final bytes = base64Decode(
        await _decrypt(_snapshotKeyScope(accountKey), 1, base64Decode(value)),
      );
      if (bytes.length != 32) return null;
      return SecretKeyData(bytes, overwriteWhenDestroyed: true);
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheSnapshotKey(String accountKey, List<int> key) async =>
      writeSetting(
        'syncSnapshotKey',
        base64Encode(
          await _encrypt(_snapshotKeyScope(accountKey), 1, base64Encode(key)),
        ),
      );

  /// The cached key, or the key on Drive (then cached). Null if Drive has none.
  Future<SecretKeyData?> _snapshotKey(SyncSnapshotStore remote) async {
    final cached = await _cachedSnapshotKey(remote.accountKey);
    if (cached != null) return cached;
    return _driveSnapshotKey(remote);
  }

  Future<SecretKeyData?> _driveSnapshotKey(SyncSnapshotStore remote) async {
    final key = await _SnapshotAutoSync.readKey(remote);
    if (key != null) await _cacheSnapshotKey(remote.accountKey, key.bytes);
    return key;
  }

  /// A cached key that does not open the cloud snapshot is dropped, and the
  /// key is read from Drive once more.
  Future<String> _openCloudSnapshot(
    SyncSnapshotStore remote,
    Uint8List bytes,
  ) async {
    final scope = 'cloud:${remote.accountKey}';
    final cached = await _cachedSnapshotKey(remote.accountKey);
    if (cached != null) {
      try {
        return await _SnapshotAutoSync.open(bytes, cached, scope);
      } on SyncTransportFailure catch (error) {
        if (error.issue != SyncTransportIssue.invalid) rethrow;
        await writeSetting('syncSnapshotKey', '');
      } finally {
        cached.destroy();
      }
    }
    final key = await _driveSnapshotKey(remote);
    if (key == null) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    try {
      return await _SnapshotAutoSync.open(bytes, key, scope);
    } finally {
      key.destroy();
    }
  }
}

String _hexBytes(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

Future<String> _snapshotDigest(Uint8List bytes) async =>
    _hexBytes((await Sha256().hash(bytes)).bytes);

/// A local snapshot is written atomically before any network request. A failed
/// upload leaves its encrypted bytes and an unmatched receipt for a retry.
final class _SnapshotAutoSync implements AutoSyncSession {
  _SnapshotAutoSync(this.store, this.remote);
  final WorkspaceDatabase store;
  final SyncSnapshotStore remote;
  bool _closed = false, _running = false;

  /// Downloaded while an editor was open; applied without another download.
  _ReceivedSnapshot? _held;
  static const _magic = [65, 110, 116, 105, 82, 75, 78, 83, 1];
  File get _local => File('${store._path}.current-snapshot');
  String get _scope => 'cloud:${remote.accountKey}';

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
      final parts = [_magic, box.nonce, box.cipherText, box.mac.bytes];
      final sealed = Uint8List(
        parts.fold(0, (length, part) => length + part.length),
      );
      var offset = 0;
      for (final part in parts) {
        sealed.setRange(offset, offset += part.length, part);
      }
      return sealed;
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  static Future<String> open(
    Uint8List bytes,
    SecretKey key,
    String scope,
  ) async {
    if (bytes.length < 37 || bytes.length > maxWorkspaceBackupBytes) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    for (var index = 0; index < _magic.length; index++) {
      if (bytes[index] != _magic[index]) {
        throw const SyncTransportFailure(SyncTransportIssue.invalid);
      }
    }
    try {
      final plain = await AesGcm.with256bits().decrypt(
        SecretBox.fromConcatenation(
          Uint8List.sublistView(bytes, _magic.length),
          nonceLength: 12,
          macLength: 16,
          copy: false,
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

  /// The key for writing over [file]. Creating the snapshot asks Drive, not
  /// the cache: a key is created only together with the first snapshot.
  Future<SecretKeyData> _keyFor(SyncRemoteFile? file) async {
    if (file != null) {
      return await store._snapshotKey(remote) ??
          (throw const SyncTransportFailure(SyncTransportIssue.invalid));
    }
    final existing = await store._driveSnapshotKey(remote);
    if (existing != null) return existing;
    final raw = Uint8List.fromList(
      await (await AesGcm.with256bits().newSecretKey()).extractBytes(),
    );
    try {
      // Another device creating a key at the same time may win; all use it.
      final effective = await remote.createSnapshotKey(raw);
      if (effective.length != 32) {
        throw const SyncTransportFailure(SyncTransportIssue.invalid);
      }
      await store._cacheSnapshotKey(remote.accountKey, effective);
      return SecretKeyData(
        Uint8List.fromList(effective),
        overwriteWhenDestroyed: true,
      );
    } finally {
      raw.fillRange(0, raw.length, 0);
    }
  }

  Future<AutoSyncResult> _recordUpload(
    String workspaceId,
    SyncRemoteFile written,
    int capturedSequence,
    String digest,
    String intent,
  ) async {
    await store.writeSetting('syncSnapshotIntent', intent);
    await store.writeSetting('syncSnapshotUnsupported', '');
    await store.writeSetting('syncSnapshotBound', workspaceId);
    await store.writeSetting('syncSnapshotRemoteFileId', written.id);
    await store.writeSetting('syncSnapshotRemoteVersion', written.version);
    await store.writeSetting('syncSnapshotRemoteEtag', written.etag);
    await store.writeSetting('syncSnapshotLocalSequence', '$capturedSequence');
    await store.writeSetting('syncSnapshotUploaded', digest);
    return AutoSyncResult(lastSuccess: DateTime.now().toUtc());
  }

  Future<AutoSyncResult> _upload(
    String source,
    String workspaceId,
    String digest,
    int capturedSequence,
    String intent,
    SyncCancellation cancel,
  ) async {
    cancel.check();
    if (workspaceId != (await store.readWorkspaceIdentity()).workspaceId) {
      throw const SyncTransportFailure(SyncTransportIssue.changed);
    }
    final expected = await store._snapshotBoundFile(workspaceId);
    if (expected != null && expected.etag.isNotEmpty) {
      // Ordinary path: one conditional write over the version this device
      // last saw. Anything newer in the cloud rejects it unchanged.
      final key = await store._snapshotKey(remote);
      if (key != null) {
        try {
          final encrypted = await seal(source, key, _scope);
          cancel.check();
          final written = await remote.writeSnapshot(expected, encrypted);
          return _recordUpload(
            workspaceId,
            written,
            capturedSequence,
            digest,
            intent,
          );
        } on SyncTransportFailure catch (error) {
          if (error.issue != SyncTransportIssue.conflict &&
              error.issue != SyncTransportIssue.notFound) {
            rethrow;
          }
        } finally {
          key.destroy();
        }
      }
    }
    return _reconcile(
      source,
      workspaceId,
      digest,
      capturedSequence,
      intent,
      cancel,
    );
  }

  /// The cloud differs from what this device last saw, or nothing is known.
  Future<AutoSyncResult> _reconcile(
    String source,
    String workspaceId,
    String digest,
    int capturedSequence,
    String intent,
    SyncCancellation cancel,
  ) async {
    for (var attempt = 0; ; attempt++) {
      cancel.check();
      final file = await remote.findSnapshot();
      final expected = await store._snapshotBoundFile(workspaceId);
      if (file != null &&
          (expected == null ||
              expected.id != file.id ||
              expected.version != file.version)) {
        // A previous upload may have succeeded while its response was lost.
        // A different remote snapshot is never overwritten implicitly.
        final remoteSource = await store._openCloudSnapshot(
          remote,
          await remote.readSnapshot(file.id),
        );
        if (remoteSource != source) {
          // A newer format says so instead of a plain conflict.
          await store._validateCloudSnapshot(remoteSource);
          throw const SyncTransportFailure(SyncTransportIssue.conflict);
        }
        return _recordUpload(
          workspaceId,
          file,
          capturedSequence,
          digest,
          intent,
        );
      }
      final key = await _keyFor(file);
      try {
        final encrypted = await seal(source, key, _scope);
        cancel.check();
        final written = await remote.writeSnapshot(file, encrypted);
        return _recordUpload(
          workspaceId,
          written,
          capturedSequence,
          digest,
          intent,
        );
      } on SyncTransportFailure catch (error) {
        // Another device wrote in between: look at its version once more.
        if (error.issue != SyncTransportIssue.conflict || attempt > 0) {
          rethrow;
        }
      } finally {
        key.destroy();
      }
    }
  }

  @override
  Future<AutoSyncResult> exchange({
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
    bool forceRecovery = false,
    bool enter = false,
  }) async {
    if (_closed || _running) {
      throw const SyncTransportFailure(SyncTransportIssue.changed);
    }
    _running = true;
    try {
      AutoSyncResult? sent;
      if (enter && forceRecovery) {
        // A snapshot an earlier launch could not send goes first, as the same
        // bytes, so that a write whose response was lost is recognized.
        sent = await _send(cancellation, recovery: true);
      }
      // Then edits made since, including ones a killed process never saved
      // to a local snapshot.
      sent =
          await _send(cancellation, recovery: forceRecovery && !enter) ?? sent;
      if (sent != null) return sent;
      // Nothing here is missing from the cloud. A newer format in the cloud
      // is refused until the app is updated.
      if ((await store.readSetting('syncSnapshotUnsupported') ?? '')
          .isNotEmpty) {
        throw const SyncTransportFailure(SyncTransportIssue.unsupportedVersion);
      }
      final held = _held;
      if (!enter) {
        // A received snapshot waiting for an editor costs no request again.
        if (held != null) return _applyReceived(held, apply);
        if (forceRecovery || !(await store._snapshotLocalState()).empty) {
          return const AutoSyncResult();
        }
        // An empty device signed in after launch learns the cloud has data.
        cancellation.check();
        return AutoSyncResult(remoteNewer: await remote.findSnapshot() != null);
      }
      // Entering the app: a newer cloud snapshot replaces unchanged data.
      cancellation.check();
      final received = await store._newerCloudSnapshot(
        remote,
        await store._snapshotLocalState(),
        held: held,
      );
      _held = received;
      if (received == null) {
        return AutoSyncResult(lastSuccess: DateTime.now().toUtc());
      }
      cancellation.check();
      return _applyReceived(received, apply);
    } finally {
      _running = false;
    }
  }

  /// Applies [received] through the owner's gate. A refused gate keeps it
  /// for the next exchange; edits made meanwhile are never replaced.
  Future<AutoSyncResult> _applyReceived(
    _ReceivedSnapshot received,
    SyncApplyGate apply,
  ) async {
    final applied = await apply(() async {
      final state = await store._snapshotLocalState();
      if (!await store._snapshotReplaceable(state) ||
          await store._unsentSnapshotPending(state)) {
        throw const SyncTransportFailure(SyncTransportIssue.changed);
      }
      await store._applyCloudSnapshot(received);
    });
    if (!applied) return const AutoSyncResult(waitingForEditor: true);
    _held = null;
    return AutoSyncResult(received: true, lastSuccess: DateTime.now().toUtc());
  }

  /// Uploads what the cloud is missing; null when there is nothing to send.
  /// With [recovery] only an unsent local snapshot is retried.
  Future<AutoSyncResult?> _send(
    SyncCancellation cancellation, {
    required bool recovery,
  }) async {
    var state = await store._snapshotLocalState();
    _CapturedSnapshot? fresh;
    if (!recovery &&
        await store._absorbCacheChanges(state, captured: (c) => fresh = c)) {
      state = await store._snapshotLocalState();
    }
    if (await store._snapshotReplaceable(state) &&
        !await store._unsentSnapshotPending(state)) {
      // A newer cloud snapshot is received by a pull, never overwritten.
      return null;
    }
    final String source, workspaceId, intent;
    final int capturedSequence;
    final pendingSequence = await store.readSetting(
      'syncSnapshotPendingSequence',
    );
    Uint8List? unsent;
    var digest = '';
    if ((recovery || pendingSequence == '${state.sequence}') &&
        await _local.exists()) {
      final bytes = await _local.readAsBytes();
      digest = await _snapshotDigest(bytes);
      if (await store.readSetting('syncSnapshotUploaded') != digest) {
        unsent = bytes;
      }
    }
    if (unsent != null) {
      // Retry of an unconfirmed snapshot without newer edits: the same bytes,
      // so a write whose response was lost is recognized in the cloud.
      capturedSequence = int.tryParse(pendingSequence ?? '') ?? -1;
      source = await open(unsent, store._key, 'local');
      final validated = await _validateBackupInBackground(source, cloud: true);
      workspaceId = validated.summary.workspaceId;
      intent = validated.intent;
    } else {
      if (recovery) return null;
      cancellation.check();
      // The capture is validated once; its source goes straight to the cloud.
      final captured = fresh ?? await store._captureSnapshot();
      capturedSequence = captured.sequence;
      source = captured.source;
      workspaceId = captured.workspaceId;
      intent = captured.intent;
      final local = await seal(source, store._key, 'local');
      digest = await _snapshotDigest(local);
      await writeBackupFile(_local.path, local);
      await store.writeSetting(
        'syncSnapshotPendingSequence',
        '$capturedSequence',
      );
    }
    final result = await _upload(
      source,
      workspaceId,
      digest,
      capturedSequence,
      intent,
      cancellation,
    );
    // Bounding the legacy journal is housekeeping after a confirmed upload;
    // it never decides whether the snapshot reaches the cloud.
    try {
      await store._compactHistory();
    } catch (_) {}
    return result;
  }

  @override
  Future<AutoSyncResult> resolve(
    SyncDivergenceChoice choice, {
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
  }) => throw const SyncTransportFailure(SyncTransportIssue.conflict);

  @override
  Future<void> close() async {
    _closed = true;
  }
}
