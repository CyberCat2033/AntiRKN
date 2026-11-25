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
            '${componentName(plan.component)} · ${plan.installedVersion ?? '—'} → ${plan.version}',
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
                          await c.cancelJob();
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
    // Shown under the page titled uiUpdatesShort (UI-50).
    return AppSettingsSection(
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
          if (c.busy) const LinearProgressIndicator(),
          if (c.failed) AppNotice(message: l.updatesFailed, error: true),
          if (c.storageFailed)
            AppNotice(message: l.settingsSaveError, error: true),
        ],
      ),
    );
  }
}

/// Installed components with a newer upstream release: key → latest.
///
/// The one rule for the update counter and the software cards (UI-46).
Map<String, String> availableUpdates(
  ComponentUpdatesController updates,
  Map<String, String> installed,
) => {
  if (updates.suggestions || updates.manualResults)
    for (final v in installed.entries)
      if (updates.latest[v.key] case final latest?)
        if (componentIsNewer(latest, v.value) == true ||
            componentIsNewer(latest, v.value, allowPreview: true) == true)
          v.key: latest,
};

/// Software cards that can host [ComponentInstallationView].
const softwareComponentKeys = ['panel', 'trusttunnel', 'amneziawg'];

/// Whether the card [key] hosts [ComponentInstallationView]: the one place
/// for the step, progress and cancel of a component install (UI-39).
bool hostsComponentInstallation(RunnerController c, String key) =>
    c.componentPlan?.component == key ||
    (c.activeComponent == key &&
        const {
          'component_install',
          'component_upgrade',
          'component_upgrade_apply',
        }.contains(c.selected?.kind) &&
        (c.selected?.terminal == false ||
            const {
              'failed',
              'partially_applied',
            }.contains(c.selected?.status)));

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
/// Product name of [component] for software cards and the inventory: one
/// name table with [componentName] (UI-53).
String vpnComponentName(VpnComponent component) => switch (component) {
  VpnComponent.amneziaWg => 'AmneziaWG',
  _ => componentName(releaseKey(component, '')),
};

String componentName(String key) => switch (key) {
  'panel' => '3x-ui',
  'xray' => 'Xray',
  'trusttunnel' => 'TrustTunnel',
  'amneziawg' => 'AmneziaWG Go',
  'amneziawgTools' => 'amneziawg-tools',
  _ => key,
};
