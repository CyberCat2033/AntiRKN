import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:flutter/foundation.dart';

import '../sync/auto_sync_controller.dart';
import '../vpn/vpn_controller.dart';

class PublicationBatchResult {
  final int uploaded;
  final int upToDate;
  final int failed;

  const PublicationBatchResult({
    this.uploaded = 0,
    this.upToDate = 0,
    this.failed = 0,
  });

  int get total => uploaded + upToDate + failed;
}

class PublicationController extends ChangeNotifier {
  PublicationController({
    required this.repository,
    required this.account,
    required this.remote,
    required this.vpn,
    this.sync,
    this.picker,
    this.canPublish,
  }) {
    vpn.addListener(_vpnChanged);
    _seenSyncResult = sync?.result;
    _seenSyncAccount = sync?.account;
    sync?.addListener(_syncChanged);
    ready = reload();
  }
  final PublicationRepository repository;
  final GoogleSyncAccountService account;
  final PublicationRemoteStore Function() remote;
  final VpnController vpn;
  final AutoSyncController? sync;
  final PublicationFilePicker? picker;
  final bool Function()? canPublish;
  late final Future<void> ready;
  PublicationSettings? settings;
  String? settingsSource;
  final queues = <String, Map<String, dynamic>>{};
  final bindings = <String, Map<String, dynamic>>{};
  final results = <String, Map<String, dynamic>>{};
  PublicationIssue? error;
  GoogleAccountIssue? accountError;

  /// Account, folder or settings change in progress: blocks every client.
  bool settingsEditing = false;

  /// Client whose file binding is being inspected or stored. Only that
  /// client's actions wait for it; requests for others are queued.
  String? bindingUserId;
  SyncCancellation? _bindingCancel;
  Completer<void>? _bindingAbort;
  bool get editing => settingsEditing || bindingUserId != null;
  bool _disposed = false, _suspended = false, _foreground = true;
  Future<PublicationBatchResult>? _running;
  SyncCancellation? _cancel;
  Timer? _timer;
  bool _pendingAll = false, _pendingForce = false, _pendingForceUpload = false;
  final Set<String> _pendingUserIds = {};
  final Set<String> _inFlightUserIds = {};

  /// Clients asked for by [publishUser]: shown as in flight while waiting for
  /// an interrupted batch, untouched by batch progress resets.
  final Set<String> _requestedUserIds = {};

  /// Targets of the running batch; null while it covers every client.
  Set<String>? _runningTargetIds;
  final Set<String> _completedUserIds = {};
  final Set<String> _failedUserIds = {};
  int _activeSyncTotal = 0;
  DateTime? _rateLimitedUntil;
  List<Object?>? _profileStamp;
  Map<String, String> _readyProfileHashes = {};
  bool _readyBaselineSet = false;
  final Set<String> _newlyReadyUsers = {};
  int _reloadGeneration = 0;
  bool isUserBusy(String userId) =>
      settingsEditing || bindingUserId == userId || isUserInFlight(userId);
  bool isUserInFlight(String userId) =>
      _inFlightUserIds.contains(userId) || _requestedUserIds.contains(userId);
  bool isUserCompleted(String userId) => _completedUserIds.contains(userId);
  bool isUserFailed(String userId) => _failedUserIds.contains(userId);
  Set<String> get inFlightUserIds =>
      Set.unmodifiable({..._inFlightUserIds, ..._requestedUserIds});
  Set<String> get completedUserIds => Set.unmodifiable(_completedUserIds);

  Set<String> get failedUserIds => Set.unmodifiable(_failedUserIds);
  int get activeSyncTotal => _activeSyncTotal;
  int get activeSyncCompleted =>
      _completedUserIds.length + _failedUserIds.length;
  bool get isPublishing => _running != null;
  bool get hasActiveSync =>
      isPublishing ||
      _activeSyncTotal > 0 ||
      _inFlightUserIds.isNotEmpty ||
      _requestedUserIds.isNotEmpty ||
      _completedUserIds.isNotEmpty ||
      _failedUserIds.isNotEmpty;

  void _resetSyncProgress({bool notify = true}) {
    _inFlightUserIds.clear();
    _completedUserIds.clear();
    _failedUserIds.clear();
    _activeSyncTotal = 0;
    if (notify) _notify();
  }

  @visibleForTesting
  void resetSyncProgress() => _resetSyncProgress(notify: true);

  @visibleForTesting
  void simulateUserProgress({
    Set<String>? inFlight,
    Set<String>? completed,
    Set<String>? failed,
    int? total,
  }) {
    if (inFlight != null) {
      _inFlightUserIds
        ..clear()
        ..addAll(inFlight);
      _completedUserIds.removeAll(inFlight);
      _failedUserIds.removeAll(inFlight);
    }
    if (completed != null) {
      _completedUserIds
        ..clear()
        ..addAll(completed);
      _inFlightUserIds.removeAll(completed);
      _failedUserIds.removeAll(completed);
    }
    if (failed != null) {
      _failedUserIds
        ..clear()
        ..addAll(failed);
      _inFlightUserIds.removeAll(failed);
      _completedUserIds.removeAll(failed);
    }
    if (total != null) {
      _activeSyncTotal = total;
    }
    _notify();
  }

  bool get busy => editing || _running != null;

  Map<String, dynamic>? deletionFileFor(String userId) {
    final result = results[userId], destination = settings;
    if (destination == null ||
        result?['fileId'] is! String ||
        result?['registryId'] is! String) {
      return null;
    }
    return {
      'fileId': result!['fileId'],
      'registryId': result['registryId'],
      'accountKey': destination.accountKey,
      'folderId': destination.folderId,
      'owner': ?result['owner'],
      'resourceKey': ?result['resourceKey'],
    };
  }

  Future<void> deleteClientFile(
    VpnUser user,
    Future<void> Function() guard,
  ) async {
    final target = user.deletion?['file'] as Map?;
    if (target == null || !user.deleted) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    if (!authorized) {
      throw const PublicationFailure(PublicationIssue.unauthorized);
    }
    final store = remote();
    Future<void> check() async {
      await guard();
      if (store.accountKey != target['accountKey'] ||
          account.accountKey != target['accountKey']) {
        throw const PublicationFailure(PublicationIssue.accountChanged);
      }
      final result = await repository.readPublicationDocument(
        'result/${user.id}',
      );
      if (result == null ||
          (jsonDecode(result) as Map)['fileId'] != target['fileId']) {
        throw const PublicationFailure(PublicationIssue.conflict);
      }
    }

    await check();
    if (store case final PublicationResourceKeys keys) {
      keys.useResourceKey(
        PublicationTarget(
          target['fileId'] as String,
          resourceKey: target['resourceKey'] as String?,
        ),
      );
    }
    final file = await store.getFile(target['fileId'] as String);
    if (!file.binary ||
        file.properties['antirknWorkspace'] != vpn.workspace.id ||
        (file.properties['antirknUser'] != (target['owner'] ?? user.id) &&
            file.properties['antirknUser'] != 'retired:${user.id}')) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    if (file.trashed) return;
    await check();
    await store.trashFile(file, user.deletion!['id'] as String);
    final verified = await store.getFile(file.id);
    if (!verified.trashed ||
        verified.properties['antirknDeleted'] != user.deletion!['id']) {
      throw const PublicationFailure(PublicationIssue.readback);
    }
  }

  /// Results are written by the coordinator only after public readback succeeds.
  /// A failed update may retain the previous verified URL, but a revoked or
  /// conflicting destination must never be presented as a working subscription.
  String? verifiedLinkFor(String userId) {
    final user = vpn.workspace.users.where((u) => u.id == userId).firstOrNull;
    final result = results[userId], issue = queues[userId]?['issue'];
    // Issues that invalidate a specific client's link.
    const invalidLinkIssues = {
      'missing',
      'conflict',
      'invalid',
      'readback',
      'linkUnavailable',
      'accountChanged',
    };
    // Global errors that affect ALL clients and must block every link.
    const globalInvalidIssues = {'accountChanged', 'unauthorized', 'forbidden'};
    if (user?.enabled != true ||
        settings?.access != PublicationAccess.link ||
        result?['access'] != 'link' ||
        result?['fileId'] is! String ||
        _suspended ||
        globalInvalidIssues.contains(error?.name) ||
        (!bindingPending(userId) && invalidLinkIssues.contains(issue))) {
      return null;
    }
    try {
      if (settings!.accountKey != account.accountKey) return null;
    } catch (_) {
      return null;
    }
    final url = result?['url'];
    final parsed = url is String ? Uri.tryParse(url) : null;
    return parsed?.scheme == 'https' && parsed!.host.isNotEmpty
        ? url as String
        : null;
  }

  bool get authorized =>
      account is GooglePublicationAuthorization &&
      (account as GooglePublicationAuthorization).publicationAuthorized;
  bool get needsAuthorization =>
      !authorized ||
      error == PublicationIssue.forbidden ||
      error == PublicationIssue.unauthorized ||
      accountError == GoogleAccountIssue.reauthorize;
  void accountAuthorizationChanged() {
    if (!authorized) return;
    error = null;
    accountError = null;
    _notify();
    request(force: true);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  final _progress = ValueNotifier<int>(0);
  bool _progressScheduled = false;

  /// Ticks when a client of a running batch starts or finishes. A batch
  /// notifies the controller itself only when it starts and ends, so the
  /// whole users page does not rebuild twice per client.
  ValueListenable<int> get progress => _progress;

  /// Controller state and batch progress, for per-client views.
  late final Listenable changes = Listenable.merge([this, _progress]);

  /// Coalesces the progress of every client handled in one event-loop turn.
  void _progressChanged() {
    if (_progressScheduled || _disposed) return;
    _progressScheduled = true;
    scheduleMicrotask(() {
      _progressScheduled = false;
      if (!_disposed) _progress.value++;
    });
  }

  static void _decodeInto(
    Map<String, Map<String, dynamic>> target,
    String id,
    String? source,
    String kind,
  ) {
    if (source == null) return;
    try {
      target[id] = jsonDecode(source) as Map<String, dynamic>;
    } catch (e) {
      debugPrint(
        'publication_document_invalid kind=$kind type=${e.runtimeType}',
      );
    }
  }

  Future<void> reload() async {
    final generation = ++_reloadGeneration;
    try {
      final source = await repository.readPublicationDocument('settings');
      final nextSettings = source == null
          ? null
          : PublicationSettings.fromJson(
              jsonDecode(source) as Map<String, dynamic>,
            );
      final nextQueues = <String, Map<String, dynamic>>{},
          nextResults = <String, Map<String, dynamic>>{},
          nextBindings = <String, Map<String, dynamic>>{};
      final userIds = [for (final user in vpn.workspace.users) user.id];
      final batch = repository is PublicationStateBatchReader
          ? await (repository as PublicationStateBatchReader)
                .readPublicationStateBatch(userIds)
          : null;
      for (final id in userIds) {
        final q = batch == null
            ? await repository.readPublicationQueue(id)
            : batch[id]?['queue'];
        final r = batch == null
            ? await repository.readPublicationDocument('result/$id')
            : batch[id]?['result'];
        final b = batch == null
            ? await repository.readPublicationDocument('binding/$id')
            : batch[id]?['binding'];
        // One unreadable document affects only its client: it is skipped
        // (that client looks unpublished and is published again) instead of
        // failing the whole publication state.
        _decodeInto(nextBindings, id, b, 'binding');
        _decodeInto(nextQueues, id, q, 'queue');
        _decodeInto(nextResults, id, r, 'result');
      }
      if (_disposed || generation != _reloadGeneration) return;
      settingsSource = source;
      settings = nextSettings;
      queues
        ..clear()
        ..addAll(nextQueues);
      bindings
        ..clear()
        ..addAll(nextBindings);
      results
        ..clear()
        ..addAll(nextResults);
    } catch (e) {
      debugPrint('publication_reload_failed type=${e.runtimeType}');
      error = PublicationIssue.invalid;
    }
    _notify();

    // A server may confirm a newly created client after its first publication
    // attempt failed. Retry that profile once when it becomes publishable.
    if (!_disposed && !_suspended && _foreground && !editing && authorized) {
      for (final id in _newlyReadyUsers.toList()) {
        if (settings?.enabled != true) break;
        if (_readyProfileHashes.containsKey(id) && !isUserUpToDate(id)) {
          request(force: true, targetUserId: id);
        }
        _newlyReadyUsers.remove(id);
      }
      final hasPending = vpn.workspace.users.any(
        (u) => u.enabled && !u.deleted && bindingPending(u.id),
      );
      if (hasPending) {
        request(force: false);
      }
    }
  }

  void _vpnChanged() {
    final readyProfiles = <String, String>{..._readyProfileHashes};
    if (vpn.loaded && !vpn.workspaceBusy) {
      readyProfiles.clear();
    }
    if (vpn.loaded && !vpn.workspaceBusy && vpn.hasCurrentVerifiedProfiles) {
      for (final user in vpn.workspace.users) {
        final hash = savedProfileHashFor(user.id);
        final result = vpn.results[user.id];
        if (user.enabled &&
            !user.deleted &&
            hash != null &&
            result?.sha256Hash == hash &&
            result?.hasBlockingErrors == false &&
            vpn.coreCheckFor(user.id)?.status != CoreConfigStatus.invalid) {
          readyProfiles[user.id] = hash;
        }
      }
    }
    final newlyReadyUsers = _readyBaselineSet
        ? {
            for (final entry in readyProfiles.entries)
              if (_readyProfileHashes[entry.key] != entry.value) entry.key,
          }
        : <String>{};
    if (vpn.loaded && !vpn.workspaceBusy) _readyBaselineSet = true;
    if (!vpn.workspaceBusy) _readyProfileHashes = readyProfiles;
    // Compared element by element: no JSON encoding of every client on each
    // VPN notification.
    final stamp = <Object?>[
      vpn.loaded,
      vpn.workspaceBusy,
      vpn.serverSyncIssue,
      for (final user in vpn.workspace.users) ...[
        user.id,
        user.enabled,
        vpn.workspace.profiles[user.id]?['hash'],
        vpn.results[user.id]?.hasBlockingErrors,
        vpn.coreCheckFor(user.id)?.status == CoreConfigStatus.invalid,
      ],
    ];
    if (listEquals(stamp, _profileStamp)) return;
    _profileStamp = stamp;
    _newlyReadyUsers.addAll(newlyReadyUsers);
    unawaited(reload());
  }

  void request({
    bool force = false,
    bool forceUpload = false,
    String? targetUserId,
  }) {
    if (_disposed || !_foreground || settingsEditing) return;
    // A binding edit suspends publishing briefly; keep the request and run it
    // when the edit ends instead of dropping it.
    if (_suspended && bindingUserId == null) return;
    _pendingForce |= force || forceUpload;
    _pendingForceUpload |= forceUpload;
    if (targetUserId == null) {
      _pendingAll = true;
      _pendingUserIds.clear();
    } else if (!_pendingAll) {
      _pendingUserIds.add(targetUserId);
    }
    _schedulePending();
  }

  void _schedulePending() {
    if (_disposed ||
        _suspended ||
        !_foreground ||
        editing ||
        _running != null ||
        !_pendingAll && _pendingUserIds.isEmpty) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(
      (_pendingForce || _pendingForceUpload)
          ? Duration.zero
          : const Duration(milliseconds: 300),
      _drainPending,
    );
  }

  void _drainPending() {
    _timer = null;
    if (_disposed ||
        _suspended ||
        !_foreground ||
        editing ||
        _running != null) {
      return;
    }
    final force = _pendingForce;
    final forceUpload = _pendingForceUpload;
    final targets = _pendingAll ? null : Set<String>.of(_pendingUserIds);
    _pendingAll = false;
    _pendingForce = false;
    _pendingForceUpload = false;
    _pendingUserIds.clear();
    _start(force, targetUserIds: targets, forceUpload: forceUpload);
  }

  Future<PublicationBatchResult>? _start(
    bool force, {
    String? targetUserId,
    Set<String>? targetUserIds,
    bool ignoreForeground = false,
    bool forceUpload = false,
  }) {
    if (_disposed ||
        _suspended ||
        (!_foreground && !ignoreForeground) ||
        editing ||
        _running != null) {
      return _running;
    }
    final targets =
        targetUserIds ?? (targetUserId == null ? null : {targetUserId});
    final future = _run(
      force,
      targetUserIds: targets,
      forceUpload: forceUpload,
    );
    _running = future;
    _runningTargetIds = targets;
    future.whenComplete(() {
      final wasRunning = _running == future;
      if (wasRunning) {
        _running = null;
        _runningTargetIds = null;
      }
      _schedulePending();
      if (_running == null) {
        // The batch result carries the outcome: progress clears at once,
        // without an artificial pause (UI-74).
        if (!_disposed && !_suspended && hasActiveSync) {
          _resetSyncProgress(notify: false);
        }
        _notify();
      }
    });
    _notify();
    return future;
  }

  Future<void> publishUser(
    String userId, {
    bool force = false,
    bool forceUpload = false,
  }) async {
    if (_disposed) return;
    // Another client's binding edit only pauses publishing: queue this one
    // (with its force flags) to run when the edit ends.
    if (!settingsEditing && bindingUserId != null && bindingUserId != userId) {
      request(force: force, forceUpload: forceUpload, targetUserId: userId);
      return;
    }
    if (_suspended || editing) return;
    if (!authorized || needsAuthorization) {
      accountError = GoogleAccountIssue.reauthorize;
      error = PublicationIssue.unauthorized;
      _notify();
      return;
    }
    _timer?.cancel();
    _requestedUserIds.add(userId);
    _notify();
    try {
      if (_running case final running?) {
        // Put back what the interrupted batch has not finished: it runs again
        // after this client (unchanged profiles are skipped quickly).
        final interrupted = _runningTargetIds;
        if (interrupted == null) {
          _pendingAll = true;
          _pendingUserIds.clear();
        } else if (!_pendingAll) {
          _pendingUserIds.addAll(interrupted.where((id) => id != userId));
        }
        _cancel?.cancel();
        try {
          await running;
        } catch (e) {
          debugPrint('publication_interrupted_failed type=${e.runtimeType}');
        }
      }
      // Another requested client may have started meanwhile: wait for it
      // instead of being dropped by [_start].
      for (var other = _running; other != null; other = _running) {
        try {
          await other;
        } catch (_) {}
      }
      if (_disposed || _suspended || editing) return;
      final future = _start(
        force || forceUpload,
        targetUserId: userId,
        ignoreForeground: true,
        forceUpload: forceUpload,
      );
      await future;
    } finally {
      _requestedUserIds.remove(userId);
      _notify();
    }
  }

  Future<void> forceOverwrite(String userId) =>
      publishUser(userId, force: true, forceUpload: true);

  Future<PublicationBatchResult> _run(
    bool force, {
    Set<String>? targetUserIds,
    bool forceUpload = false,
  }) async {
    _resetSyncProgress(notify: false);
    if (!authorized ||
        needsAuthorization ||
        settings?.enabled != true ||
        !vpn.loaded) {
      if (!authorized || needsAuthorization) {
        accountError = GoogleAccountIssue.reauthorize;
        error = PublicationIssue.unauthorized;
        _notify();
      }
      return const PublicationBatchResult();
    }
    if (vpn.serverSyncIssue != null) {
      return const PublicationBatchResult(failed: 1);
    }
    if (vpn.workspaceBusy || canPublish?.call() == false) {
      return const PublicationBatchResult();
    }
    _cancel = SyncCancellation();
    error = null;
    accountError = null;
    var uploadedCount = 0;
    var upToDateCount = 0;
    var failedCount = 0;
    try {
      final coordinator = PublicationCoordinator(
        repository: repository,
        remote: remote(),
        eligible: (draft) async =>
            !_disposed && !_suspended && _draftEligible(draft),
      );
      final activeUsers = vpn.workspace.users
          .where((u) => u.enabled && !u.deleted)
          .where((u) => targetUserIds == null || targetUserIds.contains(u.id))
          .toList();

      var nextIndex = 0;
      final concurrency = activeUsers.isEmpty ? 1 : min(4, activeUsers.length);
      _inFlightUserIds.clear();
      _completedUserIds.clear();
      _failedUserIds.clear();
      _activeSyncTotal = activeUsers.length;
      _notify();

      Future<void> worker() async {
        while (!_disposed && !_suspended) {
          if (error != null) return;
          try {
            _cancel?.check();
          } on SyncTransportFailure catch (e) {
            if (e.issue == SyncTransportIssue.cancelled) return;
            rethrow;
          }
          if (nextIndex >= activeUsers.length) return;
          if (_rateLimitedUntil != null) {
            final wait = _rateLimitedUntil!.difference(DateTime.now());
            if (wait > Duration.zero) {
              await Future<void>.delayed(wait);
            }
          }
          final userIndex = nextIndex++;
          final user = activeUsers[userIndex];
          _inFlightUserIds.add(user.id);
          _completedUserIds.remove(user.id);
          _failedUserIds.remove(user.id);
          _progressChanged();
          var success = false;
          try {
            // Fast-path: skip user if profile is already published and unchanged
            final wasUpToDate = isUserUpToDate(user.id);
            if (!force && !forceUpload && wasUpToDate) {
              upToDateCount++;
              success = true;
              continue;
            }
            final previousResult = results[user.id] == null
                ? null
                : canonicalJson(results[user.id]);

            success = false;
            Map<String, dynamic>? publishQueue;
            for (var attempt = 0; attempt < 3; attempt++) {
              if (_disposed || _suspended) break;
              try {
                publishQueue = await coordinator.publish(
                  user.id,
                  force: true,
                  forceUpload: forceUpload,
                  cancellation: _cancel,
                );
                if (publishQueue?['issue'] == 'unauthorized') {
                  error = PublicationIssue.unauthorized;
                  accountError = GoogleAccountIssue.reauthorize;
                  _cancel?.cancel();
                  success = false;
                  break;
                }
                if (publishQueue?['issue'] != 'changed' || attempt == 2) {
                  success =
                      publishQueue?['issue'] == null &&
                      publishQueue?['status'] == 'published';
                  break;
                }
                await Future<void>.delayed(const Duration(milliseconds: 300));
              } on PublicationFailure catch (e) {
                if (e.issue == PublicationIssue.unauthorized) {
                  error = PublicationIssue.unauthorized;
                  accountError = GoogleAccountIssue.reauthorize;
                  queues[user.id] = {'issue': e.issue.name, 'userId': user.id};
                  _cancel?.cancel();
                  break;
                }
                if (e.issue == PublicationIssue.rateLimited) {
                  _rateLimitedUntil = DateTime.now().add(
                    const Duration(seconds: 2),
                  );
                }
                final isRetryable =
                    e.issue == PublicationIssue.network ||
                    e.issue == PublicationIssue.rateLimited ||
                    e.issue == PublicationIssue.unavailable;
                if (isRetryable && attempt < 2) {
                  final delayMs = 500 * (1 << attempt) + Random().nextInt(300);
                  await Future<void>.delayed(Duration(milliseconds: delayMs));
                  continue;
                }
                // Per-user error: record it in the queue but continue with others.
                queues[user.id] = {'issue': e.issue.name, 'userId': user.id};
                break;
              } on GoogleAccountFailure catch (e) {
                accountError = e.issue;
                if (e.issue == GoogleAccountIssue.reauthorize ||
                    e.issue == GoogleAccountIssue.denied) {
                  error = PublicationIssue.unauthorized;
                  queues[user.id] = {
                    'issue': PublicationIssue.unauthorized.name,
                    'userId': user.id,
                  };
                  _cancel?.cancel();
                  break;
                }
                if (attempt < 2) {
                  await Future<void>.delayed(
                    Duration(milliseconds: 500 * (1 << attempt)),
                  );
                  continue;
                }
                queues[user.id] = {
                  'issue': PublicationIssue.unauthorized.name,
                  'userId': user.id,
                };
                break;
              } on SyncTransportFailure catch (e) {
                if (e.issue == SyncTransportIssue.cancelled) return;
                if (e.issue == SyncTransportIssue.unauthorized) {
                  error = PublicationIssue.unauthorized;
                  accountError = GoogleAccountIssue.reauthorize;
                  queues[user.id] = {
                    'issue': PublicationIssue.unauthorized.name,
                    'userId': user.id,
                  };
                  _cancel?.cancel();
                  break;
                }
                if (attempt < 2) {
                  final delayMs = 500 * (1 << attempt) + Random().nextInt(300);
                  await Future<void>.delayed(Duration(milliseconds: delayMs));
                  continue;
                }
                queues[user.id] = {
                  'issue': PublicationIssue.network.name,
                  'userId': user.id,
                };
                break;
              } on SyncMergeFailure {
                if (attempt == 2) {
                  queues[user.id] = {
                    'issue': PublicationIssue.conflict.name,
                    'userId': user.id,
                  };
                } else {
                  await Future<void>.delayed(const Duration(milliseconds: 300));
                }
              }
            }
            if (publishQueue != null) queues[user.id] = publishQueue;
            final resultDoc = await repository.readPublicationDocument(
              'result/${user.id}',
            );
            _decodeInto(results, user.id, resultDoc, 'result');
            final bindingDoc = await repository.readPublicationDocument(
              'binding/${user.id}',
            );
            _decodeInto(bindings, user.id, bindingDoc, 'binding');
            if (success) {
              if (!forceUpload &&
                  wasUpToDate &&
                  previousResult == canonicalJson(results[user.id])) {
                upToDateCount++;
              } else {
                uploadedCount++;
              }
            } else {
              failedCount++;
            }
          } finally {
            _inFlightUserIds.remove(user.id);
            if (success) {
              _completedUserIds.add(user.id);
              _failedUserIds.remove(user.id);
            } else if (!_disposed && !_suspended) {
              _failedUserIds.add(user.id);
              _completedUserIds.remove(user.id);
            }
            _progressChanged();
          }
          await Future<void>.delayed(Duration.zero);
        }
      }

      await Future.wait(List.generate(concurrency, (_) => worker()));
    } on GoogleAccountFailure catch (e) {
      accountError = e.issue;
      if (e.issue == GoogleAccountIssue.reauthorize ||
          e.issue == GoogleAccountIssue.denied) {
        error = PublicationIssue.unauthorized;
      }
    } on SyncTransportFailure catch (e) {
      if (e.issue != SyncTransportIssue.cancelled) {
        error = e.issue == SyncTransportIssue.unauthorized
            ? PublicationIssue.unauthorized
            : PublicationIssue.network;
      }
    } catch (e) {
      debugPrint('publication_batch_failed type=${e.runtimeType}');
      error = PublicationIssue.invalid;
    } finally {
      _cancel = null;
      _inFlightUserIds.clear();
      _notify();
    }
    return PublicationBatchResult(
      uploaded: uploadedCount,
      upToDate: upToDateCount,
      failed: max(failedCount, (error != null || accountError != null) ? 1 : 0),
    );
  }

  Future<void> suspend() async {
    _suspended = true;
    _timer?.cancel();
    _pendingAll = false;
    _pendingForce = false;
    _pendingUserIds.clear();
    _cancel?.cancel();
    await _running;
    _resetSyncProgress();
  }

  void resume() {
    _suspended = false;
    _notify();
    if (_foreground && _newlyReadyUsers.isNotEmpty) unawaited(reload());
  }

  /// [force] checks the remote copy even when the local profile is unchanged.
  /// [forceUpload] is reserved for an explicit repair action.
  Future<PublicationBatchResult> forcePublishAll({
    bool force = true,
    bool forceUpload = false,
  }) async {
    if (_disposed || editing) return const PublicationBatchResult();
    for (var i = 0; i < 20 && _suspended; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (_disposed || editing) return const PublicationBatchResult();
    }
    if (_suspended) return const PublicationBatchResult();
    if (!authorized || needsAuthorization) {
      accountError = GoogleAccountIssue.reauthorize;
      error = PublicationIssue.unauthorized;
      _notify();
      return const PublicationBatchResult(failed: 1);
    }
    _timer?.cancel();
    if (_running != null) {
      _cancel?.cancel();
      try {
        await _running;
      } catch (_) {}
    }
    final future = _start(
      force || forceUpload,
      ignoreForeground: true,
      forceUpload: forceUpload,
    );
    return (await future) ?? const PublicationBatchResult();
  }

  void foreground(bool value) {
    _foreground = value;
    if (value && _newlyReadyUsers.isNotEmpty) unawaited(reload());
    if (!value) {
      _timer?.cancel();
      _pendingAll = false;
      _pendingForce = false;
      _pendingUserIds.clear();
      if (_running == null) {
        _cancel?.cancel();
      }
    }
  }

  Future<void> authorize() async {
    if (editing) return;
    await suspend();
    settingsEditing = true;
    error = null;
    accountError = null;
    _notify();
    GoogleDriveAccount? current = sync?.account;
    try {
      await sync?.suspendAccount();
      current =
          await (account as GooglePublicationAuthorization)
              .authorizePublications() ??
          current;
    } on GoogleAccountFailure catch (e) {
      accountError = e.issue;
    } catch (_) {
      accountError = GoogleAccountIssue.unavailable;
    } finally {
      await sync?.accountChanged(current);
      settingsEditing = false;
      resume();
    }
  }

  String get pickerApiKey =>
      settings?.pickerApiKey ??
      const String.fromEnvironment('ANTIRKN_GOOGLE_PICKER_API_KEY');
  String get pickerAppId =>
      settings?.pickerAppId ??
      const String.fromEnvironment('ANTIRKN_GOOGLE_PICKER_APP_ID');
  bool get pickerReady =>
      picker != null && pickerApiKey.isNotEmpty && pickerAppId.isNotEmpty;
  bool bindingPending(String userId) =>
      bindings[userId] != null &&
      bindings[userId]?['id'] != results[userId]?['binding'];

  bool isUserUpToDate(String userId) {
    final savedHash = savedProfileHashFor(userId);
    final result = results[userId];
    final queue = queues[userId];
    final access = settings?.access;
    final accessReady = switch (access) {
      PublicationAccess.private => result?['permissionId'] == null,
      PublicationAccess.link =>
        result?['url'] is String && result?['permissionId'] is String,
      _ => false,
    };
    return savedHash != null &&
        result?['hash'] == savedHash &&
        result?['fileId'] is String &&
        result?['registryId'] is String &&
        result?['access'] == access?.name &&
        accessReady &&
        !bindingPending(userId) &&
        queue?['status'] == 'published' &&
        queue?['issue'] == null &&
        queue?['head'] == result?['head'] &&
        queue?['hash'] == savedHash;
  }

  String? savedProfileHashFor(String userId) {
    final hash = vpn.workspace.profiles[userId]?['hash'];
    return hash is String && hash.isNotEmpty ? hash : null;
  }

  bool _draftEligible(PublicationDraft draft) {
    final user = vpn.workspace.users
        .where((candidate) => candidate.id == draft.userId)
        .firstOrNull;
    if (_disposed ||
        vpn.serverSyncIssue != null ||
        user?.enabled != true ||
        savedProfileHashFor(draft.userId) != draft.hash ||
        vpn.results[draft.userId]?.hasBlockingErrors == true) {
      return false;
    }
    // A retained profile from a failed current compilation is not evidence
    // that the current desired accesses were verified on the servers.
    if (vpn.results[draft.userId]?.sha256Hash == draft.hash &&
        vpn.coreCheckFor(draft.userId)?.status == CoreConfigStatus.invalid) {
      return false;
    }
    return true;
  }

  bool _bindingEligible(PublicationDraft draft) => _draftEligible(draft);

  /// Runs a binding edit for [userId], or a settings edit when it is null.
  Future<T> _bindingEdit<T>(
    Future<T> Function(SyncCancellation cancel) action, {
    String? userId,
  }) async {
    if (editing || _disposed) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    final cancel = SyncCancellation();
    if (userId == null) {
      settingsEditing = true;
    } else {
      bindingUserId = userId;
      _bindingCancel = cancel;
      _bindingAbort = Completer<void>();
    }
    _notify();
    try {
      // Waiting for the running batch can take a while; closing the binding
      // dialog stops waiting (the batch is already cancelled).
      await _abandonable(suspend());
      cancel.check();
      return await action(cancel);
    } finally {
      if (userId == null) {
        settingsEditing = false;
      } else {
        bindingUserId = null;
        _bindingCancel = null;
        _bindingAbort = null;
      }
      resume();
      _schedulePending();
    }
  }

  /// Stops waiting for a binding inspection and skips the publication that
  /// follows a stored binding. A consent that is already being stored still
  /// completes; the client then shows the binding as pending.
  void cancelBinding() {
    _bindingCancel?.cancel();
    if (_bindingAbort case final abort? when !abort.isCompleted) {
      abort.complete();
    }
  }

  /// Completes with `cancelled` as soon as [cancelBinding] is called,
  /// without waiting for [work]. Only for read-only work whose late result
  /// can be dropped.
  Future<T> _abandonable<T>(Future<T> work) {
    final abort = _bindingAbort;
    if (abort == null) return work;
    return Future.any([
      work,
      abort.future.then<T>(
        (_) => throw const SyncTransportFailure(SyncTransportIssue.cancelled),
      ),
    ]);
  }

  Future<void> configurePicker(String apiKey, String appId) =>
      _bindingEdit((_) async {
        if (settings == null) {
          throw const PublicationFailure(PublicationIssue.invalid);
        }
        final next = settings!.copy(
          pickerApiKey: apiKey.trim(),
          pickerAppId: appId.trim(),
        );
        PublicationSettings.fromJson(next.toJson());
        await _saveSettings(next);
      });

  /// Choosing a file writes nothing, so it neither suspends publishing nor
  /// blocks other clients while the picker is open.
  Future<PublicationTarget?> pickFile() async {
    if (_disposed) throw const PublicationFailure(PublicationIssue.conflict);
    if (!authorized || !pickerReady) {
      throw const PublicationFailure(PublicationIssue.unauthorized);
    }
    return picker!.pick(apiKey: pickerApiKey, appId: pickerAppId);
  }

  Future<PublicationBindingPreview> inspectFile(
    String userId,
    PublicationTarget target,
  ) => _bindingEdit((cancel) async {
    if (!authorized) {
      throw const PublicationFailure(PublicationIssue.unauthorized);
    }
    return _abandonable(
      PublicationCoordinator(
        repository: repository,
        remote: remote(),
        eligible: (d) async => _bindingEligible(d),
        workspaceId: vpn.workspace.id,
      ).inspectBinding(userId, target),
    );
  }, userId: userId);

  Future<void> bindFile(PublicationBindingPreview preview) =>
      _bindingEdit((cancel) async {
        if (!authorized) {
          throw const PublicationFailure(PublicationIssue.unauthorized);
        }
        final coordinator = PublicationCoordinator(
          repository: repository,
          remote: remote(),
          eligible: (d) async => _bindingEligible(d),
        );
        await coordinator.acceptBinding(preview);
        final targetId = preview.userId ?? preview.draft?.userId;
        try {
          if (targetId != null && preview.draft != null) {
            cancel.check();
            final queue = await coordinator.publish(
              targetId,
              force: true,
              cancellation: cancel,
            );
            if (queue != null) queues[targetId] = queue;
            final result = await repository.readPublicationDocument(
              'result/$targetId',
            );
            _decodeInto(results, targetId, result, 'result');
          }
        } on SyncTransportFailure catch (e) {
          if (e.issue != SyncTransportIssue.cancelled) rethrow;
          // The binding is stored: queue its upload for when the edit ends.
          if (targetId != null) request(force: true, targetUserId: targetId);
        }
        await reload();
      }, userId: preview.userId ?? preview.draft?.userId);

  Future<List<PublicationFile>> folders() => remote().listFolders();

  Future<void> configure(
    PublicationAccess access, {
    PublicationFile? folder,
    String name = 'AntiRKN profiles',
  }) async {
    if (settings != null || editing) return;
    await suspend();
    settingsEditing = true;
    error = null;
    _notify();
    try {
      final target = remote();
      final id = folder?.id ?? await target.generateFileId();
      final next = PublicationSettings(
        accountKey: target.accountKey,
        folderId: id,
        folderName: folder?.name ?? name,
        access: access,
        enabled: false,
        folderReady: folder != null,
      );
      await _saveSettings(next);
      await _completeFolder(target, next);
    } on PublicationFailure catch (e) {
      error = e.issue;
    } catch (_) {
      error = PublicationIssue.invalid;
    } finally {
      settingsEditing = false;
      resume();
    }
  }

  Future<void> completeSetup() async {
    final current = settings;
    if (current == null || editing) return;
    await suspend();
    settingsEditing = true;
    error = null;
    _notify();
    try {
      await _completeFolder(remote(), current);
    } on PublicationFailure catch (e) {
      error = e.issue;
    } catch (_) {
      error = PublicationIssue.invalid;
    } finally {
      settingsEditing = false;
      resume();
    }
  }

  Future<void> _completeFolder(
    PublicationRemoteStore target,
    PublicationSettings current,
  ) async {
    if (target.accountKey != current.accountKey) {
      throw const PublicationFailure(PublicationIssue.accountChanged);
    }
    PublicationFile? folder;
    try {
      folder = await target.getFile(current.folderId);
    } on PublicationFailure catch (e) {
      if (e.issue != PublicationIssue.missing || current.folderReady) rethrow;
      try {
        await target.createFolder(current.folderId, current.folderName);
      } on PublicationFailure catch (e) {
        if (e.issue != PublicationIssue.conflict) rethrow;
      }
      folder = await target.getFile(current.folderId);
    }
    if (!folder.folder || !folder.editable || folder.trashed || folder.shared) {
      throw const PublicationFailure(PublicationIssue.invalid);
    }
    await _saveSettings(current.copy(folderReady: true, enabled: true));
  }

  Future<void> _saveSettings(PublicationSettings next) async {
    ++_reloadGeneration;
    final source = canonicalJson(next.toJson());
    await repository.writePublicationDocument(
      'settings',
      source,
      expectedSource: settingsSource,
    );
    settingsSource = source;
    settings = next;
    _notify();
  }

  /// The value [setEnabled] is storing; the switch shows it meanwhile.
  bool? enabling;

  Future<void> setEnabled(bool value) async {
    if (settings == null || editing) return;
    // Mark the edit before waiting for the running batch to stop, which can
    // take minutes: the switch shows the requested value and a second tap
    // cannot start a conflicting write.
    settingsEditing = true;
    enabling = value;
    _notify();
    try {
      await suspend();
      await _saveSettings(settings!.copy(enabled: value));
    } on PublicationFailure catch (e) {
      error = e.issue;
    } catch (e) {
      debugPrint('publication_enable_failed type=${e.runtimeType}');
      error = PublicationIssue.invalid;
    } finally {
      settingsEditing = false;
      enabling = null;
      resume();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    picker?.cancel();
    _timer?.cancel();
    _pendingUserIds.clear();
    _cancel?.cancel();
    _resetSyncProgress(notify: false);
    vpn.removeListener(_vpnChanged);
    sync?.removeListener(_syncChanged);
    _progress.dispose();
    super.dispose();
  }

  AutoSyncResult? _seenSyncResult;
  GoogleDriveAccount? _seenSyncAccount;
  bool _seenSyncApplying = false;

  /// Publication documents change only through received data (an apply that
  /// finished, a new exchange result) or another account. Phase and progress
  /// notifications of a sync (several per run) re-read nothing.
  void _syncChanged() {
    final current = sync!;
    final applied = _seenSyncApplying && !current.applying;
    final changed =
        !identical(current.result, _seenSyncResult) ||
        current.account != _seenSyncAccount;
    _seenSyncApplying = current.applying;
    _seenSyncResult = current.result;
    _seenSyncAccount = current.account;
    if (applied || changed) unawaited(reload());
  }
}
