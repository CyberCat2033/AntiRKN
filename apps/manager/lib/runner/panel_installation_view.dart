import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import 'runner_controller.dart';

class PanelInstallationView extends StatefulWidget {
  const PanelInstallationView({required this.controller, super.key});
  final RunnerController controller;
  @override
  State<PanelInstallationView> createState() => _PanelInstallationViewState();
}

class _PanelInstallationViewState extends State<PanelInstallationView> {
  bool revealed = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final l = AppLocalizations.of(context);
    final plan = c.panelPlan;
    final access = c.panelAccess;
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
        OutlinedButton.icon(
          key: const ValueKey('components-choose'),
          onPressed: c.connected && !c.busy && c.pending == null
              ? c.chooseComponents
              : null,
          icon: const Icon(Icons.add_box_outlined),
          label: Text(l.componentsInstall),
        ),
        if (c.choosingPanel) ...[
          CheckboxListTile(
            key: const ValueKey('components-xray'),
            contentPadding: EdgeInsets.zero,
            title: const Text('3x-ui / Xray'),
            subtitle: Text(l.componentsSelectionHelp),
            value: c.panelSelected,
            onChanged: c.busy ? null : (v) => c.selectPanel(v ?? false),
          ),
          TextFormField(
            key: const ValueKey('components-port'),
            initialValue: '${c.panelPort ?? 2053}',
            enabled: !c.busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l.componentsPort,
              helperText: l.componentsPortHelp,
              errorText: c.panelPort == null ? l.componentsPortInvalid : null,
            ),
            onChanged: c.changePanelPort,
          ),
          const SizedBox(height: AppLayout.smallGap),
          Wrap(
            spacing: AppLayout.smallGap,
            children: [
              FilledButton.tonal(
                key: const ValueKey('components-plan'),
                onPressed:
                    c.connected &&
                        !c.busy &&
                        c.panelSelected &&
                        c.panelPort != null
                    ? c.preparePanel
                    : null,
                child: Text(l.componentsPrepare),
              ),
              TextButton(
                onPressed: c.busy ? null : c.dismissComponents,
                child: Text(l.runnerNotNow),
              ),
            ],
          ),
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
          if (plan.canApply) ...[
            Text(l.componentsPlanBody),
            Text(l.componentsDependencies),
            SelectableText(
              '127.0.0.1:${plan.port}\n/usr/local/x-ui/\n/etc/x-ui/\n/etc/systemd/system/x-ui.service',
            ),
            Text(l.componentsRunnerDependency),
            Text(l.runnerPlanRelease),
            SelectableText(c.bundledRelease ?? ''),
            SelectableText(
              '/usr/local/lib/antirkn-runner/v2/\n/var/lib/antirkn-runner/\n/etc/antirkn-runner/',
            ),
            Text(
              'SHA-256 · ${(plan.bytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
            ),
            SelectableText(plan.sha256),
            FilledButton(
              key: const ValueKey('components-apply'),
              onPressed: c.canApplyPanel ? c.applyPanel : null,
              child: Text(l.runnerApply),
            ),
          ],
        ],
        if (access != null) ...[
          const SizedBox(height: AppLayout.gap),
          Text(
            l.componentsPanelAccess,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text('3x-ui ${access.panelVersion} · Xray ${access.xrayVersion}'),
          Text('127.0.0.1:${access.port} · ${access.username}'),
          Text(l.componentsAccessHelp),
          TextFormField(
            key: ValueKey('panel-secret-${access.id}-$revealed'),
            initialValue: access.password,
            readOnly: true,
            obscureText: !revealed,
            decoration: InputDecoration(
              labelText: l.componentsPassword,
              suffixIcon: IconButton(
                tooltip: revealed
                    ? l.componentsHidePassword
                    : l.componentsShowPassword,
                onPressed: () => setState(() => revealed = !revealed),
                icon: Icon(revealed ? Icons.visibility_off : Icons.visibility),
              ),
            ),
          ),
          if (c.panelVerifiedAt != null)
            Text(
              l.componentsVerified(
                DateFormat.yMd(
                  l.localeName,
                ).add_Hm().format(c.panelVerifiedAt!.toLocal()),
              ),
            ),
        ],
        if (access != null ||
            c.selected?.kind == 'panel_install' &&
                c.selected?.status == 'succeeded')
          TextButton(
            onPressed: c.connected && !c.busy ? c.verifyPanel : null,
            child: Text(l.componentsVerifyApi),
          ),
      ],
    );
  }
}
