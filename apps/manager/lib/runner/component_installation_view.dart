import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'runner_controller.dart';
import 'component_updates_controller.dart';

class ComponentInstallationView extends StatelessWidget {
  const ComponentInstallationView({required this.controller, super.key});
  final RunnerController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller, l = AppLocalizations.of(context);
    final updates = ComponentUpdatesScope.of(context);
    final plan = c.componentPlan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (plan != null) ...[
          Text(
            '${plan.component == 'trusttunnel' ? 'TrustTunnel' : 'AmneziaWG'} · ${plan.installedVersion ?? '—'} → ${plan.version}',
          ),
          if (plan.toolsVersion != null)
            Text('amneziawg-tools · ${plan.toolsVersion}'),
          if (!plan.supported) Text(l.protocolPrerequisites),
          if (plan.state == 'conflict') Text(l.protocolExisting),
          if (plan.state == 'incompatible') Text(l.runnerIncompatible),
          if (plan.state == 'current') Text(l.protocolCurrent),
          if (updates?.latest[plan.component] case final String latest)
            if (componentIsNewer(latest, plan.version) == true)
              Text(l.updatesCompatibility),
          if (plan.canApply) ...[
            Text(
              plan.state == 'update'
                  ? l.protocolUpdatePlan
                  : l.protocolInstallPlan,
            ),
            Text(l.protocolConfigurationSeparate),
            if (plan.activeUnits.isNotEmpty)
              Text(l.protocolRestart(plan.activeUnits.join(', '))),
          ],
          TextButton(
            onPressed: c.busy ? null : c.dismissComponent,
            child: Text(l.runnerNotNow),
          ),
        ],
        if (c.selected?.kind == 'component_install' &&
            c.selected?.terminal == false) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              componentStepProgressText(
                l,
                c.selected!.checkpoint,
                c.selected!.count,
              ),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: c.selected!.count > 0 && c.selected!.checkpoint > 0
                ? c.selected!.checkpoint / c.selected!.count
                : null,
          ),
          if (c.selected!.cancelRequested) ...[
            const SizedBox(height: 4),
            Text(l.runnerCancelRequested),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('component-cancel'),
              onPressed:
                  !c.busy && !c.actionPending && !c.selected!.cancelRequested
                      ? () async {
                          if (await c.ensureReady()) await c.cancelJob();
                        }
                      : null,
              child: Text(l.runnerCancel),
            ),
          ),
        ],
        if (c.selected?.kind == 'component_install' &&
            const {
              'failed',
              'partially_applied',
            }.contains(c.selected?.status)) ...[
          const SizedBox(height: 8),
          if (c.selected?.status == 'partially_applied')
            Text(l.componentsPartial),
          TextButton(
            key: const ValueKey('component-retry'),
            onPressed: c.canRequestAction ? c.retryJob : null,
            child: Text(l.runnerRetry),
          ),
        ],
      ],
    );
  }
}

String componentActiveStepLabel(AppLocalizations l, int checkpoint) =>
    switch (checkpoint) {
      0 => l.protocolPrepared,
      1 => l.componentsDownloading,
      2 => l.componentsBuilding,
      3 => l.componentsExtracting,
      4 => l.protocolSwitched,
      5 => l.componentsChecking,
      _ => l.uiOperationPending,
    };

String componentStepProgressText(
  AppLocalizations l,
  int checkpoint,
  int total,
) {
  final current = (checkpoint + 1).clamp(1, total > 0 ? total : 1);
  final stepLabel = componentActiveStepLabel(l, checkpoint);
  return l.componentStepProgress(current, total > 0 ? total : 6, stepLabel);
}

class ComponentUpdateSettings extends StatelessWidget {
  const ComponentUpdateSettings({super.key});
  @override
  Widget build(BuildContext context) {
    final c = ComponentUpdatesScope.of(context),
        l = AppLocalizations.of(context);
    if (c == null) return const SizedBox.shrink();
    return AppSettingsSection(
      title: l.uiUpdatesShort,
      child: Column(
        children: [
          SwitchListTile(
            title: Text(l.updatesAutomatic),
            subtitle: Text(l.uiUpdatesAutomaticHelp),
            value: c.automatic,
            onChanged: (v) {
              c.setPreference(automatic: v);
            },
          ),
          SwitchListTile(
            title: Text(l.updatesSuggestions),
            subtitle: Text(l.uiUpdatesSuggestionsHelp),
            value: c.suggestions,
            onChanged: (v) {
              c.setPreference(suggestions: v);
            },
          ),
          const Divider(indent: 17, endIndent: 17),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: Text(l.updatesCheck),
            trailing: const Icon(Icons.chevron_right),
            onTap: c.busy ? null : c.check,
          ),
          if (c.busy) const LinearProgressIndicator(),
          if (c.failed) Text(l.updatesFailed),
          if (c.storageFailed) Text(l.settingsSaveError),
        ],
      ),
    );
  }
}

String releaseKey(VpnComponent component, String identity) =>
    switch (component) {
      VpnComponent.panel => 'panel',
      VpnComponent.xray => 'xray',
      VpnComponent.trustTunnel => 'trusttunnel',
      VpnComponent.amneziaWg =>
        identity.contains('tools') || identity.endsWith('/awg')
            ? 'amneziawgTools'
            : 'amneziawg',
    };
String componentName(String key) => switch (key) {
  'panel' => '3x-ui',
  'xray' => 'Xray',
  'trusttunnel' => 'TrustTunnel',
  'amneziawg' => 'AmneziaWG Go',
  'amneziawgTools' => 'amneziawg-tools',
  _ => key,
};
