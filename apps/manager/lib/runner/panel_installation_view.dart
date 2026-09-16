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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.selected?.kind == 'panel_install' &&
            const {
              'failed',
              'partially_applied',
            }.contains(c.selected?.status)) ...[
          OutlinedButton(
            onPressed: c.canRequestAction ? c.retryJob : null,
            child: Text(l.componentsResume),
          ),
        ],
        if (plan != null && !plan.canApply) ...[
          Text(
            !plan.supported
                ? l.componentsPrerequisites
                : !plan.portAvailable
                ? l.componentsPortBusy
                : l.componentsExisting,
          ),
        ],
      ],
    );
  }
}
