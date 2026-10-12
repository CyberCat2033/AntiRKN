part of 'workspace_database.dart';

final class _RemoteRestorePlan implements WorkspaceRestorePlan {
  _RemoteRestorePlan(this.owner, this.id, this.summary);
  final WorkspaceDatabase owner;
  final int id;
  @override
  final BackupSummary summary;
  bool disposed = false;
  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    unawaited(
      owner._remoteCall<void>('releaseRestore', [id]).catchError((Object _) {}),
    );
  }
}

final class _RemoteServerStore implements SecretVault {
  _RemoteServerStore(this.database, this.id, this.record);
  final WorkspaceDatabase database;
  final String id;
  SavedServer? record;
  bool _unlocked = true;
  @override
  bool get isUnlocked => _unlocked;
  @override
  SshProfile? get profile => record?.profile;
  @override
  Future<VaultMode?> inspect() async => VaultMode.system;
  @override
  Future<void> create(VaultMode mode, {String? password}) async {
    _unlocked = true;
  }

  @override
  Future<void> unlock({String? password}) async {
    _unlocked = true;
  }

  @override
  Future<void> saveProfile(SshProfile? profile) async {
    if (!_unlocked) throw const VaultFailure(VaultIssue.locked);
    record = await database._remoteCall<SavedServer?>('saveServer', [
      id,
      profile,
      record?.revision ?? 0,
    ]);
  }

  @override
  void lock() => _unlocked = false;
}

/// The production database has one SQLite owner. Each request is handled in
/// order, including initialization, backup, restore, and journal operations.
final class _DbWorkerClient {
  _DbWorkerClient(
    this._isolate,
    this._commands,
    this._exit,
    this._exited,
    this._changes,
  );

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _exit, _changes;
  final Completer<void> _exited;
  bool _closed = false;

  static Future<_DbWorkerClient> start(
    String path,
    SecretKeyData key,
    void Function() onChange,
  ) async {
    final bytes = Uint8List.fromList(await key.extractBytes());
    final ready = ReceivePort();
    final exit = ReceivePort();
    final changes = ReceivePort();
    final exited = Completer<void>();
    exit.listen((_) {
      if (!exited.isCompleted) exited.complete();
    });
    changes.listen((_) => onChange());
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _databaseWorkerMain,
        (path, bytes, ready.sendPort, changes.sendPort),
        onExit: exit.sendPort,
        onError: exit.sendPort,
      );
      final answer = await Future.any<dynamic>([
        ready.first,
        exited.future.then<dynamic>(
          (_) => throw const VaultFailure(VaultIssue.unavailable),
        ),
      ]);
      if (answer is! SendPort) {
        if (answer is VaultFailure) throw answer;
        throw const VaultFailure(VaultIssue.unavailable);
      }
      return _DbWorkerClient(isolate, answer, exit, exited, changes);
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      exit.close();
      changes.close();
      rethrow;
    } finally {
      ready.close();
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<T> request<T>(String action, [List<Object?> args = const []]) async {
    if (_closed || _exited.isCompleted) {
      throw const VaultFailure(VaultIssue.unavailable);
    }
    final response = ReceivePort();
    try {
      _commands.send((action, args, response.sendPort));
      final result = await Future.any<dynamic>([
        response.first,
        _exited.future.then<dynamic>(
          (_) => throw const VaultFailure(VaultIssue.unavailable),
        ),
      ]);
      if (result case (true, final Object? value)) return value as T;
      if (result case (false, final Object error)) throw error;
      throw const VaultFailure(VaultIssue.unavailable);
    } finally {
      response.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    try {
      await request<void>('close');
    } finally {
      _closed = true;
      try {
        await _exited.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        _isolate.kill(priority: Isolate.immediate);
      }
      _exit.close();
      _changes.close();
    }
  }
}

Future<void> _databaseWorkerMain(
  (String, Uint8List, SendPort, SendPort) start,
) async {
  final commands = ReceivePort();
  WorkspaceDatabase? db;
  StreamSubscription<void>? changes;
  final plans = <int, WorkspaceRestorePlan>{};
  var nextPlan = 0;
  var announced = false;
  try {
    db = WorkspaceDatabase.open(
      start.$1,
      key: SecretKeyData(start.$2, overwriteWhenDestroyed: true),
    );
    await db.readWorkspaceIdentity();
    changes = db.localChanges.listen((_) => start.$4.send(null));
    start.$3.send(commands.sendPort);
    announced = true;
    await for (final message in commands) {
      final (action, args, reply) =
          message as (String, List<Object?>, SendPort);
      if (action == 'close') {
        reply.send((true, null));
        break;
      }
      try {
        final Object? value;
        if (action == 'prepareRestore') {
          final plan = await db.prepareRestore(
            args[0] as Uint8List,
            args[1] as String,
          );
          final id = ++nextPlan;
          plans[id] = plan;
          value = (id, plan.summary);
        } else if (action == 'restoreBackup') {
          final plan = plans.remove(args[0] as int);
          if (plan == null) throw const BackupFailure(BackupIssue.changed);
          await db.restoreBackup(plan);
          value = null;
        } else if (action == 'releaseRestore') {
          plans.remove(args[0] as int)?.dispose();
          value = null;
        } else {
          value = await _dispatchDatabase(db, action, args);
        }
        reply.send((true, value));
      } on VaultFailure catch (error) {
        reply.send((false, error));
      } on BackupFailure catch (error) {
        reply.send((false, error));
      } on SyncPacketFailure catch (error) {
        reply.send((false, error));
      } on SyncMergeFailure catch (error) {
        reply.send((false, error));
      } on SyncTransportFailure catch (error) {
        reply.send((false, error));
      } on PublicationFailure catch (error) {
        reply.send((false, error));
      } on FormatException catch (error) {
        reply.send((false, error));
      } catch (_) {
        reply.send((false, const VaultFailure(VaultIssue.writeFailed)));
      }
    }
  } catch (error) {
    if (!announced) {
      start.$3.send(
        error is VaultFailure
            ? error
            : const VaultFailure(VaultIssue.unavailable),
      );
    }
  } finally {
    for (final plan in plans.values) {
      plan.dispose();
    }
    await changes?.cancel();
    commands.close();
    await db?.close();
  }
}

Future<Null> _unit(Future<void> task) async {
  await task;
  return null;
}

Future<Object?> _dispatchDatabase(
  WorkspaceDatabase db,
  String action,
  List<Object?> args,
) async => switch (action) {
  'listServers' => await db.listServers(),
  'openServer' =>
    (await db.openServer(args[0] as String) as _ServerStore).record,
  'saveServer' => await db._save(
    args[0] as String,
    args[1] as SshProfile?,
    args[2] as int,
  ),
  'deleteServers' => await _unit(
    db.deleteServers(
      args[0] as List<SavedServer>,
      detachJumpReferences: args[1] as bool,
    ),
  ),
  'readSetting' => await db.readSetting(args[0] as String),
  'writeSetting' => await _unit(
    db.writeSetting(args[0] as String, args[1] as String),
  ),
  'readLanguage' => await db.readLanguage(),
  'writeLanguage' => await _unit(db.writeLanguage(args[0] as AppLanguage)),
  'readPublicationDocument' => await db.readPublicationDocument(
    args[0] as String,
  ),
  'writePublicationDocument' => await _unit(
    db.writePublicationDocument(
      args[0] as String,
      args[1] as String,
      expectedSource: args[2] as String?,
    ),
  ),
  'readPublicationQueue' => await db.readPublicationQueue(args[0] as String),
  'readPublicationStateBatch' => await db.readPublicationStateBatch(
    args[0] as List<String>,
  ),
  'writePublicationQueue' => await _unit(
    db.writePublicationQueue(
      args[0] as String,
      args[1] as String,
      expectedSource: args[2] as String?,
    ),
  ),
  'readPublicationDraft' => await db.readPublicationDraft(args[0] as String),
  'checkPublicationDraft' => await _unit(
    db.checkPublicationDraft(args[0] as PublicationDraft),
  ),
  'readDraft' => await db.readDraft(),
  'writeDraft' => await _unit(db.writeDraft(args[0] as String)),
  'readVpn' => await db.readVpn(),
  'writeVpn' => await db.writeVpn(
    args[0] as String,
    expectedRevision: args[1] as int,
  ),
  'writeVpnWorkspace' => await db.writeVpnWorkspace(
    args[0] as VpnWorkspace,
    expectedRevision: args[1] as int,
  ),
  'upsertVpnUser' => await db.upsertVpnUser(
    args[0] as VpnUser,
    expectedRevision: args[1] as int,
  ),
  'upsertVpnProfile' => await db.upsertVpnProfile(
    args[0] as String,
    args[1] as Map<String, dynamic>,
    expectedRevision: args[2] as int,
  ),
  'readRunnerJournal' => await db.readRunnerJournal(args[0] as String),
  'writeRunnerJournal' => await _unit(
    db.writeRunnerJournal(args[0] as String, args[1] as String),
  ),
  'writeRunnerJournalIfUnchanged' => await _unit(
    db.writeRunnerJournalIfUnchanged(
      args[0] as String,
      args[1] as String,
      expectedSource: args[2] as String?,
    ),
  ),
  'receiveSyncPackets' => await db.receiveSyncPackets(
    args[0] as List<Uint8List>,
  ),
  'readSyncMergeStatus' => await db.readSyncMergeStatus(),
  'retrySyncMerge' => await db.retrySyncMerge(),
  'resolveSyncConflict' => await _unit(
    db.resolveSyncConflict(args[0] as SyncConflict, args[1] as String),
  ),
  'checkSyncEffects' => await _unit(db.checkSyncEffects()),
  'readWorkspaceIdentity' => await db.readWorkspaceIdentity(),
  'preparePendingPackets' => await db.preparePendingPackets(
    afterSequence: args[0] as int,
    limit: args[1] as int,
  ),
  'verifySyncPacket' => await db.verifySyncPacket(args[0] as Uint8List),
  'readChanges' => await db.readChanges(
    afterSequence: args[0] as int,
    limit: args[1] as int,
  ),
  'readPendingChanges' => await db.readPendingChanges(
    afterSequence: args[0] as int,
    limit: args[1] as int,
  ),
  'acknowledgeChanges' => await _unit(
    db.acknowledgeChanges(args[0] as List<String>),
  ),
  'createBackup' => await db.createBackup(args[0] as String),
  'readRestoredTargets' => await db.readRestoredTargets(),
  'approveRestoredTargets' => await _unit(
    db.approveRestoredTargets(args[0] as List<String>),
  ),
  'legacyMigrated' => await db._serial(
    () => db._db
        .select("SELECT 1 FROM migrations WHERE id='legacy-vault-v1'")
        .isNotEmpty,
  ),
  'importLegacyProfile' => await _unit(
    db._serial(() => db._importLegacyProfile(args[0] as SshProfile?)),
  ),
  'captureSnapshot' => await _currentSnapshot(db),
  'compactHistory' => await _unit(_compactCurrentHistory(db)),
  'snapshotState' => await db._serial(
    () => (
      empty:
          db._db.select('SELECT 1 FROM servers LIMIT 1').isEmpty &&
          db._db.select('SELECT 1 FROM documents LIMIT 1').isEmpty,
      sequence:
          db._db
                  .select(
                    'SELECT sequence FROM sync_identity WHERE singleton=1',
                  )
                  .single['sequence']
              as int,
      workspaceId: db._journal.identity.workspaceId,
    ),
  ),
  'snapshotStamp' => await db._serial(() => _backupStamp(db)),
  'restoreCloudSnapshot' => await _unit(
    _restoreCloudSnapshotInWorker(
      db,
      args[0] as _BackupSnapshot,
      args[1] as String,
      args[2] as String,
      args[3] as String,
    ),
  ),
  _ => throw const VaultFailure(VaultIssue.unavailable),
};

Future<void> _restoreCloudSnapshotInWorker(
  WorkspaceDatabase db,
  _BackupSnapshot snapshot,
  String stamp,
  String fileId,
  String version,
) async {
  final plan = _RestorePlan(db, stamp, snapshot)
    ..cloudBound = true
    ..remoteFileId = fileId
    ..remoteVersion = version;
  await db.restoreBackup(plan);
}
