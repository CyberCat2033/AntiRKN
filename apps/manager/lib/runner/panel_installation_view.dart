import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'runner_controller.dart';

class PanelInstallationView extends StatefulWidget {
  const PanelInstallationView({
    required this.controller,
    this.motion = MotionPreference.system,
    super.key,
  });
  final RunnerController controller;
  final MotionPreference motion;
  @override
  State<PanelInstallationView> createState() => _PanelInstallationViewState();
}

class _PanelInstallationViewState extends State<PanelInstallationView> {
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final l = AppLocalizations.of(context);
    final plan = c.panelPlan;
    final duration = AppMotion.duration(context, widget.motion);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.selected?.kind == 'panel_install' &&
            const {
              'failed',
              'partially_applied',
            }.contains(c.selected?.status)) ...[
          OutlinedButton(
            onPressed: c.connected && !c.busy ? c.prepareResume : null,
            child: Text(l.componentsResume),
          ),
          if (c.resumePlan != null) ...[
            Text(l.componentsResumePlan),
            Wrap(
              spacing: AppLayout.smallGap,
              children: [
                FilledButton(
                  onPressed: c.connected && !c.busy ? c.applyResume : null,
                  child: Text(l.runnerApply),
                ),
                TextButton(
                  onPressed: c.busy ? null : c.dismissResume,
                  child: Text(l.runnerNotNow),
                ),
              ],
            ),
          ],
        ],
        if (plan != null) ...[
          const SizedBox(height: AppLayout.gap),
          Text(
            l.componentsPlan,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text('3x-ui ${plan.panelVersion} · Xray ${plan.xrayVersion}'),
          if (plan.state == 'existing') Text(l.componentsExisting),
          if (!plan.supported) Text(l.componentsPrerequisites),
          if (!plan.portAvailable) Text(l.componentsPortBusy),
          if (!plan.canApply)
            TextButton(
              onPressed: c.busy ? null : c.dismissComponents,
              child: Text(l.runnerNotNow),
            ),
          if (plan.canApply) ...[
            Text(l.componentsPlanSummary),
            Text(l.panelAutomaticAddress),
            ExpansionTile(
              key: PageStorageKey('panel-plan-details-${c.serverId}'),
              expansionAnimationStyle: AnimationStyle(
                duration: duration,
                reverseDuration: duration,
              ),
              tilePadding: EdgeInsets.zero,
              title: Text(l.componentsDetails),
              children: [
                SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(l.panelInstallMethod),
                      Text(l.componentsPlanBody),
                      Text(l.componentsDependencies),
                      const Text(
                        '/usr/local/x-ui/\n/etc/x-ui/\n/etc/systemd/system/x-ui.service',
                      ),
                      Text(l.componentsRunnerDependency),
                      Text(l.runnerPlanRelease),
                      Text(c.bundledRelease ?? ''),
                      const Text(
                        '/usr/local/lib/antirkn-runner/v9/\n/var/lib/antirkn-runner/\n/etc/antirkn-runner/\n/etc/systemd/system/antirkn-runner.service',
                      ),
                      Text(
                        'SHA-256 · ${(plan.bytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
                      ),
                      Text(plan.sha256),
                    ],
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: AppLayout.smallGap,
              children: [
                FilledButton(
                  key: const ValueKey('components-apply'),
                  onPressed: c.canApplyPanel ? c.applyPanel : null,
                  child: Text(l.runnerApply),
                ),
                TextButton(
                  onPressed: c.busy ? null : c.dismissComponents,
                  child: Text(l.runnerNotNow),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}
