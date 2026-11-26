import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../vpn/connection_check_view.dart';
import 'component_installation_view.dart';
import 'runner_controller.dart';
import 'runner_panel.dart';

/// A 3x-ui, TrustTunnel or AmneziaWG upgrade checked from this device
/// ([RunnerController.upgradeChecks]): its stage while it runs, then the
/// outcome; the before/after of each connection is in the details sheet.
class ComponentUpgradeChecksView extends StatelessWidget {
  const ComponentUpgradeChecksView({required this.controller, super.key});
  final RunnerController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller, l = AppLocalizations.of(context);
    final phase = c.upgradeCheckPhase;
    if (phase == null) return const SizedBox.shrink();
    final title = componentName(c.activeComponent ?? '');
    final status = switch (phase) {
      'baseline' => l.upgradeChecksBaseline,
      'upgrading' => l.upgradeChecksUpgrading,
      'comparison' => l.upgradeChecksComparison,
      'rolling_back' => l.upgradeChecksRollingBack,
      'committed' => l.upgradeChecksCommitted,
      'rolled_back' => l.upgradeChecksRolledBack,
      _ => l.upgradeChecksFailed,
    };
    final code = c.upgradeCheckCode;
    final problem = switch (code) {
      '' || 'committed' => '',
      'cancelled' => l.runnerCancelled,
      'upgrade_checks_unavailable' => l.upgradeChecksUnavailable,
      final String v when v.startsWith('upgrade_') => runnerCodeLabel(l, v),
      _ => l.upgradeChecksProblem,
    };
    String check(ConnectionCheck? result) => result == null
        ? l.xrayUpgradeNotTested
        : connectionCheckMessage(l, result);
    final details = [
      if (code.isNotEmpty && code != 'committed')
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SelectableText(l.technicalCode(code)),
        ),
      for (final row in c.upgradeChecks)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.name.isEmpty ? '${row.id}' : row.name,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text('${l.xrayUpgradeBefore}: ${check(row.before)}'),
              Text('${l.xrayUpgradeAfter}: ${check(row.after)}'),
              if (phase == 'rolled_back' || row.restored != null)
                Text('${l.xrayUpgradeRecovery}: ${check(row.restored)}'),
            ],
          ),
        ),
    ];
    if (c.upgradeChecking) {
      return AppProgressCard(
        key: const ValueKey('upgrade-checks'),
        icon: Icons.network_check,
        title: title,
        status: status,
        notes: [if (problem.isNotEmpty) problem],
        actions: [
          if (phase != 'rolling_back')
            // After the switch stopping rolls the server back: confirm in
            // error colours, as for Xray (UI-55).
            TextButton(
              key: const ValueKey('upgrade-checks-stop'),
              onPressed: () async {
                final stop = await confirmAppDanger(
                  context,
                  title: l.upgradeChecksStopTitle,
                  message: l.upgradeChecksStopHelp,
                  confirmLabel: l.connectionStop,
                  cancelLabel: l.runnerNotNow,
                  confirmKey: const ValueKey('upgrade-checks-stop-confirm'),
                );
                if (stop) c.cancelUpgradeChecks();
              },
              child: Text(l.connectionStop),
            ),
        ],
      );
    }
    return AppNotice(
      key: const ValueKey('upgrade-checks'),
      title: title,
      message: [status, if (problem.isNotEmpty) problem].join('\n'),
      error: phase != 'committed',
      icon: phase == 'committed'
          ? Icons.check_circle_outline
          : Icons.info_outline,
      liveRegion: true,
      action: Wrap(
        spacing: 8,
        children: [
          if (details.isNotEmpty)
            TextButton(
              key: const ValueKey('upgrade-checks-details'),
              onPressed: () =>
                  showAppDetails(context, title: title, children: details),
              child: Text(l.componentsDetails),
            ),
          TextButton(
            key: const ValueKey('upgrade-checks-close'),
            onPressed: c.dismissUpgradeChecks,
            child: Text(l.networkClose),
          ),
        ],
      ),
    );
  }
}
