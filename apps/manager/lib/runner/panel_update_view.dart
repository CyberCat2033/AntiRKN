import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'component_installation_view.dart';
import 'runner_controller.dart';

/// The 3x-ui update or install on the 3x-ui / Xray card, drawn like the
/// Xray transaction (see [ComponentInstallationView]).
class PanelUpdateView extends StatelessWidget {
  const PanelUpdateView({
    required this.controller,
    this.installed = const {},
    this.progressInCard = false,
    super.key,
  });
  final RunnerController controller;

  /// See [ComponentInstallationView.progressInCard].
  final bool progressInCard;

  /// Installed versions of the card, by release key.
  final Map<String, String> installed;
  @override
  Widget build(BuildContext context) {
    final c = controller,
        l = AppLocalizations.of(context),
        p = c.panelUpdatePlan,
        job = c.selected;
    final title = softwareJobTitle(
      'panel',
      installed['panel'] ?? p?.installedPanelVersion,
      p?.panelVersion ?? c.panelTarget,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!progressInCard)
          if (componentProgress(context, c, panel: true) case final progress?)
            SoftwareProgressCard(
              key: const ValueKey('software-job'),
              title: job?.kind == 'panel_install' ? '3x-ui' : title,
              progress: progress,
            ),
        if (p != null && !(p.canApply && c.busy))
          AppNotice(
            key: const ValueKey('panel-update-plan'),
            title: title,
            message: p.canApply
                ? l.protocolPrepared
                : !p.supported
                ? l.componentsPrerequisites
                : p.state == 'current'
                ? l.protocolCurrent
                : l.panelUpdateCompatibility,
            action: TextButton(
              onPressed: c.busy ? null : c.dismissPanelUpdate,
              child: Text(l.networkClose),
            ),
          ),
        if (job?.kind == 'panel_update' &&
            const {'failed', 'partially_applied'}.contains(job?.status))
          AppNotice(
            title: title,
            message: l.panelUpdateRecovery,
            error: true,
            action: TextButton(
              onPressed: c.canRequestAction ? c.retryJob : null,
              child: Text(l.runnerRetry),
            ),
          ),
      ],
    );
  }
}
