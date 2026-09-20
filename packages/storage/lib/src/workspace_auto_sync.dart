part of 'workspace_database.dart';

extension WorkspaceAutomaticSync on WorkspaceDatabase {
  Future<AutoSyncSession> openAutoSync(
    SyncAccessTokenProvider tokens, {
    SyncRemoteStore? remote,
    DriveHttp? http,
  }) async {
    final identity = await readWorkspaceIdentity();
    final account = tokens.accountKey;
    final binding = (await Sha256().hash(
      utf8.encode(
        jsonEncode([account, identity.workspaceId, identity.deviceId]),
      ),
    )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final journal = await SyncTransportDatabase.open(
      '$_path.drive-$binding.sqlite',
      key: SecretKeyData(
        Uint8List.fromList(await _key.extractBytes()),
        overwriteWhenDestroyed: true,
      ),
      accountKey: account,
      workspaceId: identity.workspaceId,
      deviceId: identity.deviceId,
    );
    final cycleTokens = _CycleTokens(tokens);
    return _WorkspaceAutoSync(
      this,
      journal,
      remote ?? GoogleDriveSyncStore(tokens: cycleTokens, http: http),
      cycleTokens,
    );
  }
}

/// Account onboarding shares keys automatically; causal merge and operation
/// ownership checks still apply to every imported event.
final class _WorkspaceAutoSync
    implements AutoSyncSession, SyncPacketStore, ChangeJournalStore {
  _WorkspaceAutoSync(this.store, this.journal, this.remote, this.tokens);
  final _CycleTokens tokens;
  final WorkspaceDatabase store;
  final SyncTransportDatabase journal;
  final SyncRemoteStore remote;
  late final _accountSync = _WorkspaceAccountSync(store, journal, remote);
  String? _exportStamp;
  bool _running = false;

  Future<bool> _export(SyncCancellation cancellation) async {
    final known = await journal.exportedIds();
    return store._serial(() async {
      final stamp = store._merge.stamp();
      if (stamp == _exportStamp) return false;
      final events = (await store._merge.events()).values;
      final key = await store._sync.readKey();
      var count = 0;
      try {
        for (final event in events) {
          cancellation.check();
          if (known.contains(event.header.changeId)) continue;
          if (count++ >= 40) return true;
          final bytes = await _sealPacketInBackground(
            journal.workspaceId,
            key.version,
            Uint8List.fromList(await key.secret.extractBytes()),
            _accountChange(event, journal.workspaceId),
          );
          cancellation.check();
          await journal.enqueue(event.header.changeId, bytes);
        }
        _exportStamp = stamp;
        return false;
      } finally {
        key.dispose();
      }
    });
  }

  @override
  Future<AutoSyncResult> exchange({
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
    bool forceRecovery = false,
  }) async {
    if (_running) throw const SyncTransportFailure(SyncTransportIssue.changed);
    _running = true;
    tokens.clear();
    try {
      cancellation.check();
      final state = await journal.readState();
      var rejected = state['rejected'] as int? ?? 0;
      var others = state['others'] as int? ?? 0;
      if (remote is SyncAccountStore) {
        final vpn = await store.readVpn();
        if (vpn.source != null &&
            _withAccountNamespaces(vpn.source!, vpn.source) != vpn.source) {
          if (!await apply(() async {
            cancellation.check();
            await store.writeVpn(vpn.source!, expectedRevision: vpn.revision);
          })) {
            return const AutoSyncResult(waitingForEditor: true);
          }
        }
        await _accountSync.prepare(cancellation);
        cancellation.check();
        final known = Set<String>.from(
          state['accountWorkspaces'] as List? ?? [],
        );
        final discovered = _accountSync._keys.keys.toSet();
        if (state['accountSyncVersion'] != 1 ||
            !known.containsAll(discovered)) {
          await journal.rescanAccountPackets();
          others = 0;
          state['accountSyncVersion'] = 1;
          state['accountWorkspaces'] = {...known, ...discovered}.toList()
            ..sort();
          state['others'] = 0;
          await journal.saveState(state);
        }
      }
      if (forceRecovery) {
        await journal.rescanAccountPackets();
        state['missingRecoveryActive'] = true;
        state.remove('missingRecoverySignature');
        state['missingRecoveryAttemptAt'] =
            DateTime.now().toUtc().toIso8601String();
        await journal.saveState(state);
      }
      final recoveryActive = state['missingRecoveryActive'] == true;
      final stagedBeforeTransfer = (await journal.readStagedObjects(
        limit: 1,
      )).isNotEmpty;
      final prioritizeIncoming = recoveryActive || stagedBeforeTransfer;
      final moreExports = prioritizeIncoming
          ? false
          : await _export(cancellation);
      SyncTransportResult? transfer;
      Object? transferError;
      // Do not let a full account scan grow the durable inbox faster than the
      // UI-safe receive batches can consume it. Once staged bytes exist, drain
      // them before performing any more remote packet I/O.
      if (!stagedBeforeTransfer) {
        try {
          transfer =
              await SyncTransportEngine(
                remote: remote,
                journal: journal,
                packets: this,
                changes: this,
              ).exchange(
                uploadLimit: prioritizeIncoming ? 0 : 20,
                downloadPageLimit: 1,
                cancellation: cancellation,
              );
        } catch (error) {
          transferError = error;
        }
      }
      cancellation.check();
      var waiting = false;
      // Keep each foreground lock short enough for Flutter to render and
      // accept input while a large account history is being recovered.
      final inbox = await journal.readStagedObjects(limit: 20);
      // Validate before asking for an editor lock. Own/replayed events and
      // unrelated workspaces must not interrupt editing or refresh the UI.
      final incoming = <(StagedSyncObject, LocalChange, Uint8List)>[];
      for (final object in inbox) {
        cancellation.check();
        if (object.removed) {
          await journal.consumeObject(object);
          continue;
        }
        try {
          final packet = await _accountSync.localPacket(object.bytes);
          final event = await store.verifySyncPacket(packet);
          final known = await store._serial(() async {
            final rows = store._db.select(
              'SELECT header,payload FROM sync_changes WHERE change_id=? UNION ALL SELECT header,payload FROM sync_incoming WHERE change_id=?',
              [event.header.changeId, event.header.changeId],
            );
            if (rows.isEmpty) return false;
            final row = rows.single;
            final header = ChangeHeader.fromJson(
              jsonDecode(row['header'] as String) as Map<String, dynamic>,
            );
            final value =
                jsonDecode(
                      await store._decrypt(
                        _LocalChangeJournal._scope(header),
                        1,
                        row['payload'] as Uint8List,
                      ),
                    )
                    as Map;
            if (canonicalJson(header.toJson()) !=
                    canonicalJson(event.header.toJson()) ||
                _accountChange(
                      LocalChange(
                        header: header,
                        source: value['source'] as String?,
                      ),
                      journal.workspaceId,
                    ).source !=
                    event.source) {
              throw const SyncMergeFailure(SyncMergeIssue.invalid);
            }
            return true;
          });
          if (known) {
            await journal.enqueue(
              event.header.changeId,
              object.bytes,
              delivered: true,
            );
            await journal.consumeObject(object);
          } else {
            incoming.add((object, event, packet));
          }
        } on SyncPacketFailure catch (error) {
          if (error.issue == SyncPacketIssue.storage) rethrow;
          if (error.issue == SyncPacketIssue.workspace) {
            others++;
          } else {
            rejected++;
          }
          await journal.consumeObject(object);
        } on SyncMergeFailure catch (error) {
          if (error.issue != SyncMergeIssue.invalid) rethrow;
          rejected++;
          await journal.consumeObject(object);
        }
      }
      if (incoming.isNotEmpty) {
        waiting = !await apply(() async {
          cancellation.check();
          try {
            await store.receiveSyncPackets([
              for (final entry in incoming) entry.$3,
            ]);
            for (final (object, event, _) in incoming) {
              cancellation.check();
              await journal.enqueue(
                event.header.changeId,
                object.bytes,
                delivered: true,
              );
              await journal.consumeObject(object);
            }
          } on SyncMergeFailure catch (error) {
            if (error.issue != SyncMergeIssue.invalid) rethrow;
            // Preserve the old quarantine behavior for a malformed member,
            // while keeping the normal valid path to one graph projection.
            for (final (object, event, packet) in incoming) {
              cancellation.check();
              try {
                await store.receiveSyncPackets([packet]);
                await journal.enqueue(
                  event.header.changeId,
                  object.bytes,
                  delivered: true,
                );
                await journal.consumeObject(object);
              } on SyncMergeFailure catch (error) {
                if (error.issue != SyncMergeIssue.invalid) rethrow;
                rejected++;
                await journal.consumeObject(object);
              }
            }
          }
        });
      }
      var merge = await store.readSyncMergeStatus();
      if (!waiting && merge.conflicts.isNotEmpty) {
        waiting = !await apply(() async {
          final attempted = <String>{};
          while (merge.conflicts.isNotEmpty) {
            cancellation.check();
            final conflict = merge.conflicts.first;
            final conflictKey = '${conflict.kind.name}:${conflict.entityId}';
            if (!attempted.add(conflictKey)) break;
            final candidates =
                conflict.kind == ChangeEntityKind.vpnUser &&
                    conflict.variants.any((event) => event.header.deleted)
                ? conflict.variants
                      .where((event) => event.header.deleted)
                      .toList()
                : conflict.variants.toList();
            candidates.sort((a, b) {
              final revision = b.header.revision.compareTo(a.header.revision);
              return revision != 0
                  ? revision
                  : b.header.changeId.compareTo(a.header.changeId);
            });
            try {
              await store.resolveSyncConflict(
                conflict,
                candidates.first.header.changeId,
              );
            } on SyncMergeFailure catch (e) {
              if (e.issue != SyncMergeIssue.changed) rethrow;
            }
            merge = await store.readSyncMergeStatus();
          }
        });
      }
      var recoveryRequested = forceRecovery;
      final missingSignature = merge.missingChangeIds.isEmpty
          ? null
          : (await Sha256().hash(
              utf8.encode(canonicalJson(merge.missingChangeIds)),
            )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      if (missingSignature == null) {
        state.remove('missingRecoveryActive');
        state.remove('missingRecoverySignature');
        state.remove('missingRecoveryAttemptAt');
      } else if (recoveryActive) {
        if (transfer?.downloadCaughtUp == true) {
          state['missingRecoveryActive'] = false;
          state['missingRecoverySignature'] = missingSignature;
          state['missingRecoveryAttemptAt'] =
              DateTime.now().toUtc().toIso8601String();
        }
      } else {
        final lastAttemptStr = state['missingRecoveryAttemptAt'] as String?;
        final lastAttempt =
            lastAttemptStr != null ? DateTime.tryParse(lastAttemptStr) : null;
        final backoffPassed = lastAttempt == null ||
            DateTime.now().toUtc().difference(lastAttempt) >
                const Duration(seconds: 45);
        final shouldRescan =
            state['missingRecoverySignature'] != missingSignature ||
            backoffPassed;

        if (shouldRescan) {
          await journal.rescanAccountPackets();
          state['missingRecoveryActive'] = true;
          state['missingRecoveryAttemptAt'] =
              DateTime.now().toUtc().toIso8601String();
          recoveryRequested = true;
        }
      }
      final more =
          moreExports ||
          (stagedBeforeTransfer && !waiting) ||
          recoveryRequested ||
          (transfer != null && !transfer.downloadCaughtUp) ||
          (await journal.pendingExports(limit: 1)).isNotEmpty ||
          (!waiting && (await journal.readStagedObjects(limit: 1)).isNotEmpty);
      final last = !more && !waiting && transferError == null
          ? DateTime.now().toUtc()
          : (state['last'] == null
                ? null
                : DateTime.parse(state['last'] as String));
      await journal.saveState({
        ...state,
        'last': last?.toIso8601String(),
        'rejected': rejected,
        'others': others,
      });
      if (transferError != null) throw transferError;
      return AutoSyncResult(
        more: more,
        waitingForEditor: waiting,
        conflicts: merge.conflicts.length,
        waitingGroups: merge.waitingGroups + merge.blockedGroups,
        rejected: rejected + merge.rejectedGroups,
        otherWorkspaces: others,
        lastSuccess: last,
      );
    } finally {
      _running = false;
      tokens.clear();
    }
  }

  @override
  Future<List<EncryptedChangePacket>> preparePendingPackets({
    int afterSequence = 0,
    int limit = 100,
  }) => journal.pendingExports(afterSequence: afterSequence, limit: limit);
  @override
  Future<LocalChange> verifySyncPacket(Uint8List bytes) =>
      store.verifySyncPacket(bytes);
  @override
  Future<WorkspaceIdentity> readWorkspaceIdentity() =>
      store.readWorkspaceIdentity();
  @override
  Future<List<LocalChange>> readChanges({
    int afterSequence = 0,
    int limit = 100,
  }) => store.readChanges(afterSequence: afterSequence, limit: limit);
  @override
  Future<List<LocalChange>> readPendingChanges({
    int afterSequence = 0,
    int limit = 100,
  }) => store.readPendingChanges(afterSequence: afterSequence, limit: limit);
  @override
  Future<void> acknowledgeChanges(List<String> changeIds) async {
    await store._serial(
      () => store._transaction(() {
        for (final id in changeIds) {
          store._db.execute('DELETE FROM sync_outbox WHERE change_id=?', [id]);
        }
      }),
    );
    await journal.deliveredExports(changeIds);
  }

  @override
  Future<void> close() async {
    _accountSync.close();
    await journal.close();
  }
}

// One identity-checked token per bounded cycle, never persisted. Checking the
// source binding on every request still fences account changes immediately.
final class _CycleTokens
    implements SyncAccessTokenProvider, RefreshableSyncAccessTokenProvider {
  _CycleTokens(this.source) : accountKey = source.accountKey;
  final SyncAccessTokenProvider source;
  @override
  final String accountKey;
  String? _token;
  void clear() => _token = null;
  @override
  Future<void> invalidateAccessToken(String rejected) async {
    if (_token == rejected) clear();
    if (source case final RefreshableSyncAccessTokenProvider refreshable) {
      await refreshable.invalidateAccessToken(rejected);
    }
  }

  @override
  Future<String> accessToken() async {
    if (source.accountKey != accountKey) {
      throw const SyncTransportFailure(SyncTransportIssue.changed);
    }
    final value = _token ??= await source.accessToken();
    if (source.accountKey != accountKey) {
      throw const SyncTransportFailure(SyncTransportIssue.changed);
    }
    return value;
  }
}
