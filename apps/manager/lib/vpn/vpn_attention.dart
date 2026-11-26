part of 'vpn_controller.dart';

/// The one thing the person can do about a server's waiting VPN work.
enum VpnAttentionAction {
  /// Connect, sign in or update on the server page.
  openServer,

  /// Hide a removal whose servers stayed unreachable (no false revocation).
  forceDelete,

  /// Take over work owned by another device or restored from a backup.
  continueHere,

  /// Nothing besides the details.
  details,
}

/// What one VPN target of a server is doing, for the details sheet.
final class VpnTargetState {
  const VpnTargetState(this.target, this.code, {this.progress});
  final String target;

  /// A [vpnMessage] code or a runner job status.
  final String code;
  final double? progress;
}

/// Waiting VPN work of one physical server, derived from the workspace only.
final class VpnServerAttention {
  const VpnServerAttention({
    required this.serverId,
    required this.removing,
    required this.targets,
    this.blocker,
    this.action = VpnAttentionAction.details,
    this.failed = false,
  });
  final String serverId;

  /// Clients whose access is still being revoked on this server.
  final List<VpnUser> removing;
  final List<VpnTargetState> targets;

  /// Why the work cannot continue without the person, or null while it runs.
  final String? blocker;
  final VpnAttentionAction action;
  final bool failed;
  bool get needsUser => blocker != null;
}

/// SSH failures the app retries by itself; anything else needs the person.
const _transientSshIssues = {
  'ssh:network',
  'ssh:timeout',
  'ssh:disconnected',
  'ssh:cancelled',
  'ssh:commandFailed',
  'ssh:outputLimit',
};

/// Codes that say why a connected or reachable server cannot be used.
bool isVpnRemoteIssue(Object? code) =>
    code == 'vpn_connection' ||
    vpnRemoteIssues.contains(code) ||
    code is String && code.startsWith('ssh:');

bool _transientIssue(Object? code) =>
    code == null ||
    code == 'vpn_connection' ||
    code == 'vpn_runner_busy' ||
    _transientSshIssues.contains(code);

const _failedJobStates = {'failed', 'partially_applied', 'needs_attention'};

extension VpnAttention on VpnController {
  /// Every physical server with waiting VPN work, those that need the person
  /// first. Empty when everything is applied.
  List<VpnServerAttention> get attention {
    final serverIds = <String>{
      for (final id in workspace.servers.keys)
        if (_targetWaits(id)) vpnServerId(id),
      for (final user in visibleDeletions)
        if (!user.revocationSettled)
          for (final e in (user.deletion!['targets'] as Map).entries)
            if (!vpnRevocationSettled(e.value)) vpnServerId(e.key as String),
    };
    final result = [for (final id in serverIds) _serverAttention(id)];
    result.sort((a, b) {
      final rank = (b.needsUser ? 2 : 0) + (b.failed ? 1 : 0);
      return rank - ((a.needsUser ? 2 : 0) + (a.failed ? 1 : 0));
    });
    return result;
  }

  /// What [id] waits for, in the same words as the summary; null when idle.
  VpnTargetState? targetState(String id) => _serverAttention(
    vpnServerId(id),
  ).targets.where((t) => t.target == id).firstOrNull;

  bool _targetWaits(String id) {
    final record = workspace.servers[id];
    if (record == null || record['forgottenLocallyAt'] != null) return false;
    final job = currentJob(id);
    return record['error'] != null ||
        record['pending'] != null ||
        observationErrors[id] != null ||
        needsRestoreReview(id) && !observesOperation(id) ||
        job != null &&
            (!job.terminal || _failedJobStates.contains(job.status)) ||
        record['paused'] != true &&
            record['authorizedPayload'] != null &&
            record['authorizedPayload'] != record['appliedPayload'];
  }

  VpnServerAttention _serverAttention(String serverId) {
    final removing = [
      for (final user in visibleDeletions)
        if (!user.revocationSettled &&
            (user.deletion!['targets'] as Map).entries.any(
              (e) =>
                  vpnServerId(e.key as String) == serverId &&
                  !vpnRevocationSettled(e.value),
            ))
          user,
    ];
    final targets = <VpnTargetState>[];
    String? blocker;
    var action = VpnAttentionAction.details, failed = false;
    void need(String code, VpnAttentionAction next, {bool error = false}) {
      if (blocker != null) return;
      blocker = code;
      action = next;
      failed = error;
    }

    // A removal holds every target of its server, so it speaks first.
    for (final user in removing) {
      for (final e in (user.deletion!['targets'] as Map).entries) {
        final target = e.key as String;
        if (vpnServerId(target) != serverId || vpnRevocationSettled(e.value)) {
          continue;
        }
        final record = e.value as Map;
        final error = record['error'] as String?;
        if (!ownsDeletion(user)) {
          need('vpn_deletion_other_device', VpnAttentionAction.continueHere);
        } else if (needsRestoreReview(target)) {
          need('vpn_restore_review', VpnAttentionAction.continueHere);
        } else if (!_transientIssue(error)) {
          need(
            error!,
            isVpnRemoteIssue(error) || error == 'vpn_identity'
                ? VpnAttentionAction.openServer
                : VpnAttentionAction.details,
            error: !isVpnRemoteIssue(error),
          );
        } else if (canForceDelete(user)) {
          need(error ?? 'vpn_connection', VpnAttentionAction.forceDelete);
        }
        targets.add(VpnTargetState(target, error ?? 'vpn_revocation_pending'));
      }
    }
    final held = removing.isNotEmpty || hasPendingRevocation(serverId);
    for (final id in workspace.servers.keys) {
      if (vpnServerId(id) != serverId || !_targetWaits(id)) continue;
      if (targets.any((t) => t.target == id)) continue;
      final record = workspace.servers[id]!;
      final job = currentJob(id);
      if (held) {
        targets.add(VpnTargetState(id, 'vpn_waiting_removal'));
        continue;
      }
      if (observesOperation(id)) {
        targets.add(
          VpnTargetState(id, observationErrors[id] ?? 'vpn_observing'),
        );
        continue;
      }
      if (needsRestoreReview(id)) {
        need('vpn_restore_review', VpnAttentionAction.continueHere);
        targets.add(VpnTargetState(id, 'vpn_restore_review'));
        continue;
      }
      if (record['error'] case final String error) {
        if (!_transientIssue(error)) {
          need(
            error,
            isVpnRemoteIssue(error) || error == 'vpn_identity'
                ? VpnAttentionAction.openServer
                : VpnAttentionAction.details,
            error: !isVpnRemoteIssue(error),
          );
        }
        targets.add(VpnTargetState(id, error));
        continue;
      }
      if (job != null && _failedJobStates.contains(job.status)) {
        need(job.status, VpnAttentionAction.details, error: true);
        targets.add(VpnTargetState(id, job.status));
        continue;
      }
      if (job != null && !job.terminal) {
        targets.add(
          VpnTargetState(
            id,
            job.status,
            progress: job.count > 0 ? job.checkpoint / job.count : null,
          ),
        );
        continue;
      }
      // Approved work that waits for a server the app cannot reach.
      final issue = remote(id) == null ? remoteIssue?.call(id) : null;
      if (issue != null && issue != 'vpn_runner_busy') {
        need(
          issue == 'vpn_connection' ? 'vpn_not_connected' : issue,
          VpnAttentionAction.openServer,
        );
        targets.add(
          VpnTargetState(
            id,
            issue == 'vpn_connection' ? 'vpn_not_connected' : issue,
          ),
        );
        continue;
      }
      targets.add(VpnTargetState(id, 'vpn_applying'));
    }
    return VpnServerAttention(
      serverId: serverId,
      removing: removing,
      targets: targets,
      blocker: blocker,
      action: action,
      failed: failed,
    );
  }
}
