import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

import '../network/network_controller.dart';
import 'ssh_controller.dart';

class ServerCatalogController extends ChangeNotifier {
  ServerCatalogController({
    required this.repository,
    required this.connector,
    required this.picker,
    required this.reader,
    this.agentAvailable = false,
  });
  final ServerRepository repository;
  final SshConnector connector;
  final PrivateKeyFilePicker picker;
  final NetworkInventoryReader reader;
  final bool agentAvailable;
  final _sessions = <String, SshController>{};
  List<SavedServer> servers = [];
  String? selectedId;
  bool loading = false;
  VaultIssue? error;
  bool _disposed = false;
  SshController? get selected => _sessions[selectedId];
  SshController? sessionFor(String id) => _sessions[id];
  String serverDisplayName(String id) {
    final sessionName = _sessions[id]?.displayName.trim();
    if (sessionName != null && sessionName.isNotEmpty) return sessionName;
    return servers
            .where((server) => server.id == id)
            .firstOrNull
            ?.profile
            .displayName ??
        id;
  }

  bool get needsLegacyPassword => repository.needsLegacyPassword;
  bool get hasUnsavedEdits => _sessions.values.any(
    (s) =>
        !s.saved &&
        (s.hasSavedProfile ||
            s.host.text.trim().isNotEmpty ||
            s.serverName.text.trim().isNotEmpty),
  );
  bool get hasActiveWork =>
      loading ||
      _sessions.values.any(
        (s) => s.busy || s.runner.busy || s.vaultBusy || s.picking,
      );

  bool get diagnosticsConflict =>
      hasActiveWork ||
      _sessions.values.any(
        (s) =>
            s.runner.pending != null || s.runner.jobs.any((j) => !j.terminal),
      );

  void disconnectForDiagnostics() {
    for (final session in _sessions.values) {
      session.disconnect();
    }
  }

  Future<void> load({String? password}) async {
    if (loading || _disposed) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      if (!needsLegacyPassword || password != null) {
        try {
          await repository.migrateLegacy(password: password);
        } on VaultFailure catch (e) {
          error = e.issue;
        } catch (_) {
          error = VaultIssue.unavailable;
        }
      }
      final next = await repository.listServers();
      if (!_disposed) {
        servers = next;
        for (final session in _sessions.values) {
          session.updateJumpCandidates(next);
        }
      }
    } on VaultFailure catch (e) {
      error = e.issue;
    } catch (_) {
      error = VaultIssue.unavailable;
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  void add() => select(repository.newServerId());

  Future<void> refresh() async {
    await load();
    for (final session in _sessions.values.toList()) {
      if (_disposed) return;
      if (session.stage != SshStage.connected) continue;
      await session.refresh();
      await session.runner.refresh();
    }
  }

  /// Open saved sessions for revocation without moving away from the catalogue.
  Future<bool?> connectForDeletion(String id) async {
    if (_disposed || loading) return null;
    if (!servers.any((s) => s.id == id)) return false;
    var session = _sessions[id];
    if (session == null) {
      session = SshController(
        repository: repository,
        serverId: id,
        openVault: () => repository.openServer(id),
        connector: connector,
        picker: picker,
        agentAvailable: agentAvailable,
        network: NetworkController(reader: reader),
      );
      _sessions[id] = session;
      session.addListener(_sessionChanged);
      await session.initialise();
    }
    if (_disposed) return null;
    return session.connectForDeletion();
  }

  Future<bool> connectForAction(String id) async {
    if (_sessions[id] == null) await connectForDeletion(id);
    return await _sessions[id]?.runner.ensureReady() == true;
  }

  Future<void> deleteServers(
    List<SavedServer> expected, {
    required bool Function(String) canDelete,
  }) async {
    if (loading || _disposed) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      for (final server in expected) {
        final s = _sessions[server.id];
        if (!canDelete(server.id) ||
            s != null &&
                (s.stage != SshStage.idle ||
                    s.runner.busy ||
                    s.vaultBusy ||
                    s.picking ||
                    !s.saved)) {
          throw const VaultFailure(VaultIssue.busy);
        }
      }
      await repository.deleteServers(expected);
      for (final server in expected) {
        final s = _sessions.remove(server.id);
        s?.removeListener(_sessionChanged);
        s?.dispose();
        s?.network.dispose();
      }
      servers = await repository.listServers();
    } on VaultFailure catch (e) {
      error = e.issue;
    } catch (_) {
      error = VaultIssue.writeFailed;
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Deletes refreshed saved records after local VPN state has deliberately
  /// abandoned them. This path never opens an SSH connection.
  Future<void> forgetServersLocally(
    Set<String> ids, {
    required Future<bool> Function() abandonVpnState,
  }) async {
    if (loading || _disposed || ids.isEmpty) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final current = await repository.listServers();
      final affected = {
        ...ids,
        for (final server in current)
          if (ids.contains(server.profile.jumpServerId)) server.id,
      };
      if (!await abandonVpnState()) {
        throw const VaultFailure(VaultIssue.writeFailed);
      }
      final selected = current
          .where((server) => ids.contains(server.id))
          .toList();
      if (selected.isNotEmpty) {
        await repository.deleteServers(selected, detachJumpReferences: true);
      }
      for (final id in affected) {
        final session = _sessions.remove(id);
        session?.removeListener(_sessionChanged);
        session?.dispose();
        session?.network.dispose();
      }
      if (affected.contains(selectedId)) selectedId = null;
      servers = await repository.listServers();
      for (final session in _sessions.values) {
        session.updateJumpCandidates(servers);
      }
    } on VaultFailure catch (e) {
      error = e.issue;
    } catch (_) {
      error = VaultIssue.writeFailed;
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  void select(String id) {
    if (_disposed || loading) return;
    selectedId = id;
    final previous = _sessions[id];
    if (previous != null &&
        previous.stage == SshStage.idle &&
        !previous.vaultBusy &&
        !previous.picking) {
      _sessions.remove(id);
      previous.removeListener(_sessionChanged);
      previous.dispose();
      previous.network.dispose();
    }
    if (!_sessions.containsKey(id)) {
      final c = SshController(
        repository: repository,
        serverId: id,
        openVault: () => repository.openServer(id),
        connector: connector,
        picker: picker,
        agentAvailable: agentAvailable,
        network: NetworkController(reader: reader),
      );
      _sessions[id] = c;
      c.addListener(_sessionChanged);
      c.initialise();
    }
    notifyListeners();
  }

  void _sessionChanged() {
    if (!_disposed) notifyListeners();
  }

  Future<void> showList() async {
    selected?.closeSettings();
    selectedId = null;
    notifyListeners();
    await load();
    if (_disposed) return;
    // Active connections remain attached to their own server while browsing.
    for (final id in _sessions.keys.toList()) {
      final session = _sessions[id]!;
      if (!servers.any((s) => s.id == id) &&
          !session.busy &&
          !session.hasSavedProfile) {
        _sessions.remove(id);
        session.removeListener(_sessionChanged);
        session.dispose();
        session.network.dispose();
      }
    }
  }

  Future<void> reloadAfterSync() async {
    if (selectedId != null || hasActiveWork || hasUnsavedEdits) return;
    for (final session in _sessions.values) {
      session.removeListener(_sessionChanged);
      session.dispose();
      session.network.dispose();
    }
    _sessions.clear();
    await load();
  }

  SshStage stageFor(String id) => _sessions[id]?.stage ?? SshStage.idle;
  String? osFor(String id) =>
      _sessions[id]?.os ??
      servers.where((s) => s.id == id).firstOrNull?.profile.lastInfo?.os;

  @override
  void dispose() {
    _disposed = true;
    for (final c in _sessions.values) {
      c.removeListener(_sessionChanged);
      c.dispose();
      c.network.dispose();
    }
    super.dispose();
  }
}
