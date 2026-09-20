import 'dart:async';
import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:flutter/foundation.dart';

import '../sync/auto_sync_controller.dart';
import '../vpn/vpn_controller.dart';

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
  Future<void>? _running;
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
      accountError == GoogleAccountIssue.reauthorize ||
      queues.values.any(
        (q) => ['unauthorized', 'forbidden'].contains(q['issue']),
      );
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
    request();
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

  void request({bool force = false}) {
    if (_disposed || _suspended || !_foreground || editing) return;
    _timer?.cancel();
    _timer = Timer(
      force ? Duration.zero : const Duration(seconds: 1),
      () => _start(force),
    );
  }

  void _start(bool force) {
    if (_disposed ||
        _suspended ||
        !_foreground ||
        editing ||
        _running != null) {
      return;
    }
    _running = _run(force).whenComplete(() {
      _running = null;
      _notify();
      if (!_disposed && !_suspended && _foreground) {
        _timer = Timer(const Duration(seconds: 30), () => _start(false));
      }
    });
    _notify();
  }

  Future<void> _run(bool force) async {
    if (!authorized || settings?.enabled != true || !vpn.loaded) return;
    if (vpn.busy || canPublish?.call() == false) return;
    _cancel = SyncCancellation();
    error = null;
    accountError = null;
    try {
      final coordinator = PublicationCoordinator(
        repository: repository,
        remote: remote(),
        eligible: (draft) async =>
            !_suspended && _foreground && _draftEligible(draft),
      );
      final activeUsers = vpn.workspace.users
          .where((u) => u.enabled && !u.deleted)
          .toList();

      // Sequential execution: avoids concurrent writes to the shared
      // antirknRegistry file on Google Drive which caused 412/403/429 errors.
      for (final user in activeUsers) {
        if (_disposed || _suspended || !_foreground) break;
        _cancel?.check();
        try {
          final queue = await coordinator.publish(
            user.id,
            force: force,
            cancellation: _cancel,
          );
          if (queue != null) queues[user.id] = queue;
          final result = await repository.readPublicationDocument(
            'result/${user.id}',
          );
          if (result != null) {
            results[user.id] = jsonDecode(result) as Map<String, dynamic>;
          }
        } on PublicationFailure catch (e) {
          // Per-user error: record it in the queue but continue with others.
          queues[user.id] = {'issue': e.issue.name, 'userId': user.id};
        } on SyncTransportFailure catch (e) {
          if (e.issue == SyncTransportIssue.cancelled) rethrow;
          queues[user.id] = {
            'issue': PublicationIssue.network.name,
            'userId': user.id,
          };
        } on SyncMergeFailure {
          queues[user.id] = {
            'issue': PublicationIssue.conflict.name,
            'userId': user.id,
          };
        }
        _notify();
      }
    } on GoogleAccountFailure catch (e) {
      accountError = e.issue;
    } on SyncTransportFailure catch (e) {
      if (e.issue != SyncTransportIssue.cancelled) {
        error = PublicationIssue.network;
      }
    } catch (_) {
      error = PublicationIssue.invalid;
    } finally {
      _cancel = null;
    }
  }

  Future<void> suspend() async {
    _suspended = true;
    _timer?.cancel();
    _cancel?.cancel();
    await _running;
  }

  void resume() {
    _suspended = false;
    request();
    _notify();
  }

  Future<void> forcePublishAll() async {
    if (_disposed || _suspended || editing) return;
    _timer?.cancel();
    if (_running != null) {
      _cancel?.cancel();
      try {
        await _running;
      } catch (_) {}
    }
    _start(true);
    await _running;
  }

  void foreground(bool value) {
    _foreground = value;
    if (value) {
      request();
    } else {
      _timer?.cancel();
      _cancel?.cancel();
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
        vpn.busy ||
        canPublish?.call() == false ||
        savedProfileHashFor(draft.userId) != draft.hash) {
      return false;
    }
    // A failed current compilation deliberately retains the last generated
    // profile. Its draft remains publishable. Core validation only applies
    // when it checked the exact draft that is about to be published.
    if (vpn.results[draft.userId]?.sha256Hash == draft.hash &&
        (vpn.coreValidationBusy ||
            vpn.coreCheckFor(draft.userId)?.status ==
                CoreConfigStatus.invalid)) {
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
    await reload();
    request(force: true);
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
    super.dispose();
  }
}
