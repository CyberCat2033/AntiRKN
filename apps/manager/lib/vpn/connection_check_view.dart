import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'connection_checks.dart';
import 'vpn_controller.dart';

String connectionCheckMessage(AppLocalizations l, ConnectionCheck check) {
  if (check.status == ConnectionCheckStatus.working) return l.connectionWorking;
  if (check.status == ConnectionCheckStatus.failed) return l.connectionFailed;
  if (check.status == ConnectionCheckStatus.cancelled) {
    return l.connectionCancelled;
  }
  return switch (check.code) {
    'vpn_active' => l.connectionVpnActive,
    'network_changed' => l.connectionNetworkChanged,
    'control_failed' || 'target_unavailable' => l.connectionNetworkProblem,
    'unsupported_route' => l.connectionRouteUnsupported,
    'diagnostic_access' || 'server_unavailable' => l.connectionAccessRequired,
    'cleanup_pending' => l.connectionCleanupPending,
    'changed' => l.connectionChanged,
    'runtime_unavailable' || 'core_failure' => l.connectionCoreUnavailable,
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
    final running = c.current == target, result = c.result(target);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (running) Text(l.connectionChecking),
          if (!running && result != null)
            Text(connectionCheckMessage(l, result)),
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
                    : controller.busy ||
                          controller.coreValidationBusy ||
                          c.queueRunning ||
                          !c.available(target)
                    ? null
                    : () => c.check(target),
                icon: Icon(
                  running ? Icons.stop_circle_outlined : Icons.network_check,
                ),
                label: Text(running ? l.connectionStop : l.connectionCheck),
              ),
              if (!running && result?.status == ConnectionCheckStatus.failed)
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
  }
}

class ConnectionCheckAll extends StatefulWidget {
  const ConnectionCheckAll({
    required this.controller,
    required this.targets,
    this.readOthers,
    super.key,
  });
  final VpnController controller;
  final List<ConnectionTarget> targets;
  final Future<List<ConnectionTarget>> Function()? readOthers;
  @override
  State<ConnectionCheckAll> createState() => _ConnectionCheckAllState();
}

class _ConnectionCheckAllState extends State<ConnectionCheckAll> {
  bool reading = false, ran = false;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), c = widget.controller.connections;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: c.queueRunning
              ? c.cancel
              : reading ||
                    widget.controller.busy ||
                    widget.controller.coreValidationBusy ||
                    widget.targets.isEmpty && widget.readOthers == null
              ? null
              : () async {
                  setState(() {
                    reading = true;
                    ran = true;
                  });
                  final others =
                      await widget.readOthers?.call() ?? <ConnectionTarget>[];
                  if (!mounted) return;
                  setState(() => reading = false);
                  await c.checkAll({...widget.targets, ...others});
                },
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
        ),
        if (ran && !reading && c.total > 0)
          Text(l.connectionProgress(c.completed, c.total, c.skipped.length)),
      ],
    );
  }
}
