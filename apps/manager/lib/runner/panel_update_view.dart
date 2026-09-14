import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'runner_controller.dart';

class PanelUpdateView extends StatelessWidget {
  const PanelUpdateView({required this.controller, super.key});
  final RunnerController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller,
        l = AppLocalizations.of(context),
        p = c.panelUpdatePlan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (p != null) ...[
          Text('3x-ui ${p.installedPanelVersion ?? '—'} → ${p.panelVersion}'),
          Text('Xray ${p.installedXrayVersion ?? '—'} → ${p.xrayVersion}'),
          if (!p.supported) Text(l.componentsPrerequisites),
          if (p.state == 'incompatible') Text(l.panelUpdateCompatibility),
          if (p.state == 'current') Text(l.protocolCurrent),
          if (p.canApply) ...[
            Text(l.panelUpdateSummary),
            Text(l.panelUpdateCoreCompatibility),
            ExpansionTile(
              key: PageStorageKey('panel-update-details-${c.serverId}'),
              title: Text(l.componentsDetails),
              children: [
                SelectableText(
                  '${p.url}\nSHA-256: ${p.sha256}\n${p.coreUrl}\nSHA-256: ${p.coreSha256}\n${(p.bytes / 1048576).toStringAsFixed(1)} MiB\n${p.paths.join('\n')}\n${p.backupRoot}/panel-update-<id>/backup/',
                ),
                Text(l.panelUpdateRecovery),
              ],
            ),
            FilledButton(
              key: const ValueKey('panel-update-apply'),
              onPressed: c.canStart ? c.applyPanelUpdate : null,
              child: Text(l.runnerApply),
            ),
          ],
          TextButton(
            onPressed: c.busy ? null : c.dismissPanelUpdate,
            child: Text(l.runnerNotNow),
          ),
        ],
        if (c.selected?.kind == 'panel_update' &&
            const {
              'failed',
              'partially_applied',
            }.contains(c.selected?.status)) ...[
          Text(l.panelUpdateRecovery),
          if (c.resumePlan == null)
            TextButton(
              onPressed: c.canPlan ? c.prepareResume : null,
              child: Text(l.runnerRetry),
            )
          else ...[
            Text(l.componentsResumePlan),
            FilledButton(
              onPressed: c.canPlan ? c.applyResume : null,
              child: Text(l.runnerApply),
            ),
            TextButton(
              onPressed: c.busy ? null : c.dismissResume,
              child: Text(l.runnerNotNow),
            ),
          ],
        ],
      ],
    );
  }
}
