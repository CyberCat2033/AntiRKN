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
    super.key,
  });
  final RunnerController controller;

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
        if (p != null)
          p.canApply && c.busy
              ? AppProgressCard(
                  key: const ValueKey('panel-update-plan'),
                  icon: Icons.system_update_alt,
                  title: title,
                  status: l.softwarePreparing,
                )
              : AppNotice(
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
        SoftwareJobCard(
          controller: c,
          title: job?.kind == 'panel_install' ? '3x-ui' : title,
          kinds: const {'panel_install', 'panel_update'},
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
