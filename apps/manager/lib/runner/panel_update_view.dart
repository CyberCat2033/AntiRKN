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
          TextButton(
            onPressed: c.canRequestAction ? c.retryJob : null,
            child: Text(l.runnerRetry),
          ),
        ],
      ],
    );
  }
}
