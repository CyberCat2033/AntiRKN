import 'dart:async';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../vpn/vpn_controller.dart';
import '../vpn/connection_check_view.dart';
import 'panel_login_view.dart';
import 'runner_controller.dart';
import 'component_updates_controller.dart';
import 'xray_upgrade_controller.dart';

class XrayUpgradeView extends StatefulWidget {
  const XrayUpgradeView({
    required this.runner,
    required this.vpn,
    required this.host,
    super.key,
  });
  final RunnerController runner;
  final VpnController vpn;
  final String host;
  @override
  State<XrayUpgradeView> createState() => _XrayUpgradeViewState();
}

class _XrayUpgradeViewState extends State<XrayUpgradeView>
    with WidgetsBindingObserver {
  late final c = XrayUpgradeController(
    runner: widget.runner,
    vpn: widget.vpn,
    host: widget.host,
  );
  Timer? _poll;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(c.inspect());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted &&
          !c.busy &&
          widget.runner.connected &&
          widget.runner.panelAccess != null &&
          ((c.plan == null && c.code.isEmpty) ||
              // Another path (component upgrade, version choice) changed
              // the core: the shown "current → candidate" is stale.
              (c.plan?['current'] != null &&
                  widget.runner.panelAccess?.xrayVersion != null &&
                  c.plan!['current'] !=
                      widget.runner.panelAccess!.xrayVersion) ||
              c.operation != null &&
                  !XrayUpgradeController.terminal.contains(
                    c.operation!['phase'],
                  ))) {
        unawaited(c.inspect());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      c.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c, widget.runner, widget.vpn]),
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final updates = ComponentUpdatesScope.of(context);
      final currentXray =
          c.plan?['current'] as String? ??
          widget.runner.panelAccess?.xrayVersion;
      final dynamicXray = updates?.latest['xray'];
      final hasDynamicCandidate =
          dynamicXray != null &&
          currentXray != null &&
          (componentIsNewer(dynamicXray, currentXray) == true ||
              componentIsNewer(dynamicXray, currentXray, allowPreview: true) ==
                  true);
      final hasPlanCandidate =
          c.plan?['candidate'] != null &&
          currentXray != null &&
          (componentIsNewer(c.plan!['candidate'] as String, currentXray) ==
                  true ||
              componentIsNewer(
                    c.plan!['candidate'] as String,
                    currentXray,
                    allowPreview: true,
                  ) ==
                  true);
      final effectiveCandidate = hasPlanCandidate
          ? c.plan!['candidate'] as String
          : (hasDynamicCandidate ? dynamicXray : null);
      final isCandidateNewer = hasPlanCandidate || hasDynamicCandidate;
      final canRun =
          (c.available && c.plan?['available'] == true && hasPlanCandidate) ||
          ((hasDynamicCandidate || hasPlanCandidate) && updates != null);
      final message = switch (c.phase) {
        'baseline' => l.xrayUpgradeBaseline,
        'preparing' || 'replacing' => l.xrayUpgradePreparing,
        'comparison' || 'awaiting_checks' => l.xrayUpgradeComparison,
        'committed' => l.xrayUpgradeCommitted,
        'rolled_back' => l.xrayUpgradeRestored,
        'not_changed' => l.xrayUpgradeUnchanged,
        'recovery_required' => l.xrayUpgradeAttention,
        'recovery_pending' || 'rolling_back' => l.xrayUpgradePending,
        _ => '',
      };
      final problem = switch (c.code) {
        'xray_check_coverage' => l.xrayUpgradeCoverage,
        'xray_check_layout' => isCandidateNewer ? '' : l.xrayUpgradeLayout,
        'xray_check_changed' => l.xrayUpgradeConflict,
        'xray_check_rollback' => l.xrayUpgradeAttention,
        'vpn_pending_readback' => l.xrayUpgradeProblemAfter(
          l.vpnPendingReadback,
        ),
        'vpn_pending' => l.xrayUpgradeProblemAfter(l.vpnPending),
        'vpn_conflict' => l.xrayUpgradeProblemAfter(l.vpnConflict),
        '' ||
        'committed' ||
        'preparing' ||
        'replacing' ||
        'awaiting_checks' => '',
        _ => l.xrayUpgradeProblem,
      };
      String check(ConnectionCheck? result) => result == null
          ? l.xrayUpgradeNotTested
          : connectionCheckMessage(l, result);
      return Card.filled(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.xrayUpgradeTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(l.xrayUpgradeIntro),
              if (effectiveCandidate != null && currentXray != null)
                Text('Xray $currentXray → $effectiveCandidate'),
              if (c.plan != null && effectiveCandidate == null)
                Text(l.xrayUpgradeNoStable),
              if (c.busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                ),
              if (message.isNotEmpty) Text(message),
              if (problem.isNotEmpty)
                AppNotice(
                  message: problem,
                  error: true,
                  margin: const EdgeInsets.only(top: 8),
                ),
              for (final row in c.rows)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.name.isEmpty ? 'VLESS · ${row.id}' : row.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (!row.enabled) Text(l.xrayUpgradeDisabled),
                      if (row.enabled) ...[
                        Text('${l.xrayUpgradeBefore}: ${check(row.before)}'),
                        Text('${l.xrayUpgradeAfter}: ${check(row.after)}'),
                        if (c.phase == 'rolled_back' || row.restored != null)
                          Text(
                            '${l.xrayUpgradeRecovery}: ${check(row.restored)}',
                          ),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('xray-check-update'),
                onPressed: c.running
                    // Stopping aborts the upgrade and rolls the core back on
                    // the server: confirm in error colours (UI-55).
                    ? () async {
                        final stop = await confirmAppDanger(
                          context,
                          title: l.xrayUpgradeStopTitle,
                          message: l.xrayUpgradeStopHelp,
                          confirmLabel: l.connectionStop,
                          cancelLabel: l.runnerNotNow,
                          confirmKey: const ValueKey('xray-stop-confirm'),
                        );
                        if (stop && c.running) c.cancel();
                      }
                    : c.busy ||
                          widget.vpn.busy ||
                          !widget.runner.canRequestAction ||
                          !canRun
                    ? null
                    : () async {
                        if (!await showPanelLogin(context, widget.runner) ||
                            !context.mounted) {
                          return;
                        }
                        if (c.available &&
                            c.plan?['available'] == true &&
                            hasPlanCandidate) {
                          await c.run();
                        } else if (effectiveCandidate != null &&
                            updates != null) {
                          final candidate = await updates.source.resolveAsset(
                            component: 'xray',
                            version: effectiveCandidate,
                          );
                          if (candidate != null && context.mounted) {
                            await widget.runner.checkComponentUpgrade(
                              'xray',
                              candidate: candidate,
                            );
                            if (widget.runner.componentUpgradePlan != null) {
                              await widget.runner.applyComponentUpgrade(
                                widget.runner.componentUpgradePlan!,
                                candidate,
                              );
                            }
                          }
                        }
                      },
                icon: Icon(
                  c.running
                      ? Icons.stop_circle_outlined
                      : Icons.system_update_alt,
                ),
                label: Text(c.running ? l.connectionStop : l.xrayUpgradeAction),
              ),
              TextButton(
                onPressed: c.busy
                    ? null
                    : () async {
                        if (await showPanelLogin(context, widget.runner)) {
                          await c.inspect();
                        }
                      },
                child: Text(l.uiCheck),
              ),
            ],
          ),
        ),
      );
    },
  );
}
