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
