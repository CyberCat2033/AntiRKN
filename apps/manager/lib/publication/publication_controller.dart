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
  bool editing = false,
      _disposed = false,
      _suspended = false,
      _foreground = true;
  Future<PublicationBatchResult>? _running;
  SyncCancellation? _cancel;
  Timer? _timer;
  String? _profileStamp;
  int _reloadGeneration = 0;
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
    const globalInvalidIssues = {
      'accountChanged',
      'unauthorized',
      'forbidden',
    };
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
      for (final user in vpn.workspace.users) {
        final q = await repository.readPublicationQueue(user.id),
            r = await repository.readPublicationDocument('result/${user.id}');
        final b = await repository.readPublicationDocument(
          'binding/${user.id}',
        );
        if (b != null) {
          nextBindings[user.id] = jsonDecode(b) as Map<String, dynamic>;
        }
        if (q != null) {
          nextQueues[user.id] = jsonDecode(q) as Map<String, dynamic>;
        }
        if (r != null) {
          nextResults[user.id] = jsonDecode(r) as Map<String, dynamic>;
        }
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
    } catch (_) {
      error = PublicationIssue.invalid;
    }
    _notify();

    // Automatically fulfill any pending bindings
    if (!_disposed && !_suspended && !editing && authorized) {
      final hasPending = vpn.workspace.users
          .any((u) => u.enabled && !u.deleted && bindingPending(u.id));
      if (hasPending) {
        request(force: false);
      }
    }
  }

  void _vpnChanged() {
    final stamp = jsonEncode([
      vpn.loaded,
      for (final user in vpn.workspace.users)
        [
          user.id,
          user.enabled,
          vpn.workspace.profiles[user.id]?['hash'],
          vpn.results[user.id]?.hasBlockingErrors,
          vpn.coreCheckFor(user.id)?.status == CoreConfigStatus.invalid,
        ],
    ]);
    if (stamp == _profileStamp) return;
    _profileStamp = stamp;
    unawaited(reload());
  }

  void request({bool force = false, String? targetUserId}) {
    if (_disposed || _suspended || !_foreground || editing) return;
    _timer?.cancel();
    _timer = Timer(
      force ? Duration.zero : const Duration(milliseconds: 300),
      () => _start(force, targetUserId: targetUserId),
    );
  }

  Future<PublicationBatchResult>? _start(
    bool force, {
    String? targetUserId,
    bool ignoreForeground = false,
  }) {
    if (_disposed ||
        _suspended ||
        (!_foreground && !ignoreForeground) ||
        editing ||
        _running != null) {
      return _running;
    }
    final future = _run(force, targetUserId: targetUserId);
    _running = future;
    future.whenComplete(() {
      if (_running == future) _running = null;
      _notify();
    });
    _notify();
    return future;
  }

  Future<void> publishUser(String userId, {bool force = false}) async {
    if (_disposed || _suspended || editing) return;
    if (!authorized || needsAuthorization) {
      accountError = GoogleAccountIssue.reauthorize;
      error = PublicationIssue.unauthorized;
      _notify();
      return;
    }
    _timer?.cancel();
    if (_running != null) {
      _cancel?.cancel();
      try {
        await _running;
      } catch (_) {}
    }
    final future = _start(force, targetUserId: userId, ignoreForeground: true);
    await future;
  }

  Future<PublicationBatchResult> _run(bool force, {String? targetUserId}) async {
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
          .where((u) => targetUserId == null || u.id == targetUserId)
          .toList();

      var nextIndex = 0;
      final concurrency = activeUsers.isEmpty ? 1 : min(4, activeUsers.length);

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
          final user = activeUsers[nextIndex++];

          // Fast-path: skip user if profile is already published and unchanged
          final isUpToDate = !force && isUserUpToDate(user.id);
          if (isUpToDate) {
            upToDateCount++;
            continue;
          }

          var success = false;
          Map<String, dynamic>? publishQueue;
          for (var attempt = 0; attempt < 3; attempt++) {
            if (_disposed || _suspended) break;
            try {
              publishQueue = await coordinator.publish(
                user.id,
                force: true,
                forceUpload: force,
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
                success = publishQueue?['issue'] == null &&
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
              final isRetryable = e.issue == PublicationIssue.network ||
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
          if (success) {
            uploadedCount++;
          } else {
            failedCount++;
          }
          if (publishQueue != null) queues[user.id] = publishQueue;
          final resultDoc = await repository.readPublicationDocument(
            'result/${user.id}',
          );
          if (resultDoc != null) {
            results[user.id] = jsonDecode(resultDoc) as Map<String, dynamic>;
          }
          final bindingDoc = await repository.readPublicationDocument(
            'binding/${user.id}',
          );
          if (bindingDoc != null) {
            bindings[user.id] = jsonDecode(bindingDoc) as Map<String, dynamic>;
          }
          _notify();
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
    } catch (_) {
      error = PublicationIssue.invalid;
    } finally {
      _cancel = null;
    }
    return PublicationBatchResult(
      uploaded: uploadedCount,
      upToDate: upToDateCount,
      failed: max(
        failedCount,
        (error != null || accountError != null) ? 1 : 0,
      ),
    );
  }

  Future<void> suspend() async {
    _suspended = true;
    _timer?.cancel();
    _cancel?.cancel();
    await _running;
  }

  void resume() {
    _suspended = false;
    _notify();
  }

  Future<PublicationBatchResult> forcePublishAll({bool force = true}) async {
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
    final future = _start(force, ignoreForeground: true);
    return (await future) ?? const PublicationBatchResult();
  }

  void foreground(bool value) {
    _foreground = value;
    if (!value) {
      _timer?.cancel();
      if (_running == null) {
        _cancel?.cancel();
      }
    }
  }

  Future<void> authorize() async {
    if (editing) return;
    await suspend();
    editing = true;
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
      editing = false;
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
    return savedHash != null &&
        result?['hash'] == savedHash &&
        result?['fileId'] is String &&
        result?['url'] is String &&
        !bindingPending(userId) &&
        queue?['status'] == 'published' &&
        queue?['issue'] == null;
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
        user?.enabled != true ||
        savedProfileHashFor(draft.userId) != draft.hash) {
      return false;
    }
    // A failed current compilation deliberately retains the last generated
    // profile. Its draft remains publishable. Core validation only applies
    // when it checked the exact draft that is about to be published.
    if (vpn.results[draft.userId]?.sha256Hash == draft.hash &&
        vpn.coreCheckFor(draft.userId)?.status == CoreConfigStatus.invalid) {
      return false;
    }
    return true;
  }

  bool _bindingEligible(PublicationDraft draft) => _draftEligible(draft);

  Future<T> _bindingEdit<T>(Future<T> Function() action) async {
    if (editing || _disposed) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    editing = true;
    _notify();
    try {
      await suspend();
      return await action();
    } finally {
      editing = false;
      resume();
    }
  }

  Future<void> configurePicker(String apiKey, String appId) =>
      _bindingEdit(() async {
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

  Future<PublicationTarget?> pickFile() => _bindingEdit(() async {
    if (!authorized || !pickerReady) {
      throw const PublicationFailure(PublicationIssue.unauthorized);
    }
    return picker!.pick(apiKey: pickerApiKey, appId: pickerAppId);
  });

  Future<PublicationBindingPreview> inspectFile(
    String userId,
    PublicationTarget target,
  ) => _bindingEdit(() async {
    if (!authorized) {
      throw const PublicationFailure(PublicationIssue.unauthorized);
    }
    return PublicationCoordinator(
      repository: repository,
      remote: remote(),
      eligible: (d) async => _bindingEligible(d),
      workspaceId: vpn.workspace.id,
    ).inspectBinding(userId, target);
  });

  Future<void> bindFile(
    PublicationBindingPreview preview,
  ) => _bindingEdit(() async {
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
    if (targetId != null && preview.draft != null) {
      final queue = await coordinator.publish(targetId, force: true);
      if (queue != null) queues[targetId] = queue;
      final result = await repository.readPublicationDocument(
        'result/$targetId',
      );
      if (result != null) {
        results[targetId] = jsonDecode(result) as Map<String, dynamic>;
      }
    }
    await reload();
  });

  Future<List<PublicationFile>> folders() => remote().listFolders();

  Future<void> configure(
    PublicationAccess access, {
    PublicationFile? folder,
    String name = 'AntiRKN profiles',
  }) async {
    if (settings != null || editing) return;
    await suspend();
    editing = true;
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
      editing = false;
      resume();
    }
  }

  Future<void> completeSetup() async {
    final current = settings;
    if (current == null || editing) return;
    await suspend();
    editing = true;
    error = null;
    _notify();
    try {
      await _completeFolder(remote(), current);
    } on PublicationFailure catch (e) {
      error = e.issue;
    } catch (_) {
      error = PublicationIssue.invalid;
    } finally {
      editing = false;
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

  Future<void> setEnabled(bool value) async {
    if (settings == null || editing) return;
    await suspend();
    try {
      await _saveSettings(settings!.copy(enabled: value));
    } catch (_) {
      error = PublicationIssue.invalid;
    } finally {
      resume();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    picker?.cancel();
    _timer?.cancel();
    _cancel?.cancel();
    vpn.removeListener(_vpnChanged);
    sync?.removeListener(_syncChanged);
    super.dispose();
  }

  void _syncChanged() {
    unawaited(reload());
  }
}
