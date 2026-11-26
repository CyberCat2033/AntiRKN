import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'connection_checks.dart';
import 'vpn_controller.dart';
import 'vpn_strings.dart';

String connectionCheckMessage(AppLocalizations l, ConnectionCheck check) {
  if (check.status == ConnectionCheckStatus.working) return l.connectionWorking;
  if (check.status == ConnectionCheckStatus.failed) {
    return check.code == 'endpoint_unreachable'
        ? l.connectionEndpointUnreachable
        : l.connectionFailed;
  }
  if (check.status == ConnectionCheckStatus.cancelled) {
    return l.connectionCancelled;
  }
  return switch (check.code) {
    'busy' || 'probe_busy' => l.connectionBusy,
    'timeout' => l.connectionTimeout,
    'vpn_active' => l.connectionVpnActive,
    'network_changed' => l.connectionNetworkChanged,
    'control_failed' || 'target_unavailable' => l.connectionNetworkProblem,
    'unsupported_route' => l.connectionRouteUnsupported,
    'diagnostic_access' || 'server_unavailable' => l.connectionAccessRequired,
    'cleanup_pending' => l.connectionCleanupPending,
    'changed' => l.connectionChanged,
    'runtime_unavailable' || 'core_failure' => l.connectionCoreUnavailable,
    'input_limit' ||
    'invalid_proxy' ||
    'unsupported' ||
    'udp_unsupported' => l.connectionUnsupported,
    _ => l.connectionNotTested,
  };
}

class ConnectionCheckView extends StatelessWidget {
  const ConnectionCheckView({
    required this.controller,
    required this.target,
    required this.onEdit,
    super.key,
  });
  final VpnController controller;
  final ConnectionTarget target;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), c = controller.connections;
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: Listenable.merge([controller, c]),
        builder: (context, _) {
          final state = c.viewState(target);
          final running = state.running, result = state.result;
          final available = state.available, reasonCode = state.reasonCode;
          final reasonText = switch (reasonCode) {
            'vpn_disabled' => l.vpnDisabled,
            'vpn_pending' => l.vpnApplying,
            'vpn_pending_readback' => l.vpnPendingReadback,
            'vpn_missing' => l.vpnMissingOnServer,
            'vpn_conflict' ||
            'vless_conflict' ||
            'awg_conflict' => l.vpnConflict,
            'vpn_user_deleted' => l.vpnUserDeleted,
            'target_unavailable' => l.connectionNetworkProblem,
            null => null,
            final code => vpnMessage(l, code),
          };
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (running) Text(l.connectionChecking),
                if (!running && result != null)
                  Text(connectionCheckMessage(l, result)),
                if (!running && result == null && reasonText != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      reasonText,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            reasonCode == 'vpn_conflict' ||
                                reasonCode == 'vless_conflict' ||
                                reasonCode == 'awg_conflict' ||
                                (reasonCode?.contains('conflict') ?? false) ||
                                (reasonCode?.contains('failed') ?? false)
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      key: ValueKey(
                        'connection-check-${target.target}-${target.resource}',
                      ),
                      onPressed: running
                          ? c.cancel
                          : c.busy ||
                                controller.busy ||
                                c.queueRunning ||
                                !available
                          ? null
                          : () => c.check(target),
                      icon: Icon(
                        running
                            ? Icons.stop_circle_outlined
                            : Icons.network_check,
                      ),
                      label: Text(
                        running ? l.connectionStop : l.connectionCheck,
                      ),
                    ),
                    if (!running &&
                        result?.status == ConnectionCheckStatus.failed)
                      TextButton.icon(
                        onPressed: controller.busy ? null : onEdit,
                        icon: const Icon(Icons.tune),
                        label: Text(l.connectionReconfigure),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The action row of a protocol page: its own actions ([actions], e.g.
/// "Add") and "Check all", sized to their labels and wrapping on narrow
/// screens, with the check progress under them. One row for every protocol.
class ConnectionCheckAll extends StatefulWidget {
  const ConnectionCheckAll({
    required this.controller,
    required this.targets,
    this.readOthers,
    this.actions = const [],
    super.key,
  });
  final VpnController controller;
  final List<ConnectionTarget> targets;
  final Future<List<ConnectionTarget>> Function()? readOthers;
  final List<Widget> actions;
  @override
  State<ConnectionCheckAll> createState() => _ConnectionCheckAllState();
}

class _ConnectionCheckAllState extends State<ConnectionCheckAll> {
  bool reading = false, ran = false, readFailed = false;

  Future<void> _run(ConnectionChecks c) async {
    setState(() {
      reading = true;
      ran = true;
      readFailed = false;
    });
    var others = <ConnectionTarget>[];
    try {
      others = await widget.readOthers?.call() ?? <ConnectionTarget>[];
    } catch (e) {
      // A malformed panel row must not leave the button "checking" forever.
      debugPrint('connection_targets_failed type=${e.runtimeType}');
      if (mounted) setState(() => readFailed = true);
      return;
    } finally {
      if (mounted) setState(() => reading = false);
    }
    if (!mounted) return;
    await c.checkAll({...widget.targets, ...others});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Check progress is not forwarded through the VPN controller.
    listenable: Listenable.merge([
      widget.controller,
      widget.controller.connections,
    ]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final l = AppLocalizations.of(context), c = widget.controller.connections;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppLayout.smallGap,
          runSpacing: AppLayout.smallGap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [...widget.actions, _checkAll(l, c)],
        ),
        if (readFailed)
          Padding(
            padding: const EdgeInsets.only(top: AppLayout.smallGap),
            child: Semantics(
              liveRegion: true,
              child: AppNotice(
                key: const ValueKey('connection-check-all-failed'),
                message: l.connectionTargetsFailed,
                error: true,
                margin: EdgeInsets.zero,
              ),
            ),
          )
        else if (ran && !reading && c.total > 0)
          Padding(
            padding: const EdgeInsets.only(top: AppLayout.smallGap),
            child: Text(
              l.connectionProgress(c.completed, c.total, c.skipped.length),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _checkAll(AppLocalizations l, ConnectionChecks c) =>
      OutlinedButton.icon(
        onPressed: c.queueRunning
            ? c.cancel
            : reading ||
                  widget.controller.busy ||
                  widget.targets.isEmpty && widget.readOthers == null
            ? null
            : () => _run(c),
        icon: Icon(
          c.queueRunning ? Icons.stop_circle_outlined : Icons.network_check,
        ),
        label: Text(
          c.queueRunning
              ? l.connectionStop
              : reading
              ? l.connectionChecking
              : l.connectionCheckAll,
        ),
      );
}
