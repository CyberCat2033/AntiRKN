import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
        Text(
          l.protocolSoftware,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Wrap(
          spacing: AppLayout.smallGap,
          children: [
            for (final entry in {
              'trusttunnel': 'TrustTunnel',
              'amneziawg': 'AmneziaWG',
            }.entries)
              OutlinedButton(
                key: ValueKey('component-${entry.key}'),
                onPressed: c.connected && !c.busy && c.pending == null
                    ? () => c.prepareComponent(entry.key)
                    : null,
                child: Text(
                  c.presence(
                            entry.key == 'trusttunnel'
                                ? VpnComponent.trustTunnel
                                : VpnComponent.amneziaWg,
                          ) ==
                          ComponentPresence.detected
                      ? '${entry.value} · ${l.componentManage}'
                      : '${entry.value} · ${l.componentsInstall}',
                ),
              ),
            if (updates != null)
              TextButton(
                onPressed: updates.busy ? null : updates.check,
                child: Text(l.updatesCheck),
              ),
          ],
        ),
        if (updates != null)
          UpdatesResult(controller: updates, showVersions: true),
        if (updates?.suggestions == true)
          for (final observation
              in c.software?.call()?.components ?? <ComponentObservation>[])
            for (final installation in observation.installations)
              if (installation.version?.value case final String installed)
                if (updates!.latest[releaseKey(
                      observation.component,
                      installation.identity,
                    )]
                    case final String latest)
                  if (componentIsNewer(latest, installed) == true)
                    Text(
                      l.updatesAvailable(
                        componentName(
                          releaseKey(
                            observation.component,
                            installation.identity,
                          ),
                        ),
                        installed,
                        latest,
                      ),
                    ),
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
            if (plan.component == 'amneziawg') Text(l.protocolGoDependency),
            Text(l.componentsRunnerSummary),
            ExpansionTile(
              key: PageStorageKey(
                'component-plan-${c.serverId}-${plan.component}',
              ),
              title: Text(l.componentsDetails),
              children: [
                SelectableText(
                  '/usr/local/lib/antirkn-components/${plan.component}/\n/usr/local/bin/\n/etc/antirkn-components/${plan.component}/\n/etc/systemd/system/\n/var/lib/antirkn-runner/',
                ),
                for (final entry in plan.archives.entries)
                  SelectableText(
                    '${entry.key} · ${((entry.value as Map)['bytes'] / 1048576).toStringAsFixed(1)} MiB\n${entry.value['url']}\nSHA-256: ${entry.value['sha256']}',
                  ),
              ],
            ),
            FilledButton(
              key: const ValueKey('component-apply'),
              onPressed: c.canApplyComponent ? c.applyComponent : null,
              child: Text(l.runnerApply),
            ),
          ],
          TextButton(
            onPressed: c.busy ? null : c.dismissComponent,
            child: Text(l.runnerNotNow),
          ),
        ],
        if (c.selected?.kind == 'component_install' &&
            c.selected?.status == 'succeeded')
          Text(l.protocolConfigurationSeparate),
        if (c.selected?.kind == 'component_install' &&
            const {
              'failed',
              'partially_applied',
            }.contains(c.selected?.status)) ...[
          if (c.selected?.status == 'partially_applied')
            Text(l.componentsPartial),
          if (c.resumePlan == null)
            TextButton(
              onPressed: c.busy ? null : c.prepareResume,
              child: Text(l.runnerRetry),
            )
          else
            FilledButton(
              onPressed: c.busy ? null : c.applyResume,
              child: Text(l.runnerApply),
            ),
        ],
      ],
    );
  }
}

class UpdatesResult extends StatelessWidget {
  const UpdatesResult({
    required this.controller,
    this.showVersions = false,
    super.key,
  });
  final ComponentUpdatesController controller;
  final bool showVersions;
  @override
  Widget build(BuildContext context) {
    final c = controller, l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.busy) const LinearProgressIndicator(),
        if (c.failed) Text(l.updatesFailed),
        if (c.storageFailed) Text(l.settingsSaveError),
        if (c.checkedAt != null)
          Text(
            l.updatesChecked(
              DateFormat.yMd(
                l.localeName,
              ).add_Hm().format(c.checkedAt!.toLocal()),
            ),
          ),
        if (showVersions) ...[
          for (final entry in c.latest.entries)
            Text(
              '${componentName(entry.key)} · ${l.updatesLatest}: ${entry.value}',
            ),
          if (c.latest.isNotEmpty) Text(l.updatesCompatibility),
        ],
      ],
    );
  }
}

class ComponentUpdateSettings extends StatelessWidget {
  const ComponentUpdateSettings({super.key});
  @override
  Widget build(BuildContext context) {
    final c = ComponentUpdatesScope.of(context),
        l = AppLocalizations.of(context);
    if (c == null) return const SizedBox.shrink();
    return SectionCard(
      title: l.protocolSoftware,
      child: Column(
        children: [
          SwitchListTile(
            title: Text(l.updatesAutomatic),
            value: c.automatic,
            onChanged: (v) => c.setPreference(automatic: v),
          ),
          SwitchListTile(
            title: Text(l.updatesSuggestions),
            value: c.suggestions,
            onChanged: (v) => c.setPreference(suggestions: v),
          ),
          TextButton(
            onPressed: c.busy ? null : c.check,
            child: Text(l.updatesCheck),
          ),
          UpdatesResult(controller: c, showVersions: true),
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
