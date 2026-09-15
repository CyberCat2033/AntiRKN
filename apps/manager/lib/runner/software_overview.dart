import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'component_installation_view.dart';
import 'component_updates_controller.dart';
import 'panel_installation_view.dart';
import 'panel_update_view.dart';
import 'panel_login_view.dart';
import 'runner_controller.dart';

class SoftwareOverview extends StatelessWidget {
  const SoftwareOverview({
    required this.controller,
    required this.motion,
    super.key,
  });
  final RunnerController controller;
  final MotionPreference motion;
  @override
  Widget build(BuildContext context) {
    final c = controller, l = AppLocalizations.of(context);
    final updates = ComponentUpdatesScope.of(context);
    final inventory = c.software?.call();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!c.connected) Text(l.inventoryStale),
        for (final component in VpnComponent.values) ...[
          Builder(
            builder: (context) {
              final observation = inventory?.components
                  .where((o) => o.component == component)
                  .firstOrNull;
              final presence =
                  component == VpnComponent.panel && c.panelDetected
                  ? ComponentPresence.detected
                  : c.presence(component);
              final key = releaseKey(component, '');
              final versions = <String, String>{};
              for (final installation
                  in observation?.installations ?? <ComponentInstallation>[]) {
                final version = installation.version?.value;
                if (version != null) {
                  versions[releaseKey(component, installation.identity)] =
                      version;
                }
              }
              if (c.panelAccess != null) {
                if (component == VpnComponent.panel) {
                  versions[key] = c.panelAccess!.panelVersion;
                }
                if (component == VpnComponent.xray) {
                  versions[key] = c.panelAccess!.xrayVersion;
                }
              }
              final changes = <String>[];
              if (updates != null &&
                  (updates.suggestions || updates.manualResults)) {
                for (final v in versions.entries) {
                  final latest = updates.latest[v.key];
                  if (latest != null &&
                      componentIsNewer(latest, v.value) == true) {
                    changes.add('${componentName(v.key)} $latest');
                  }
                }
              }
              final canUpdate = versions.entries.any(
                (v) =>
                    verifiedComponentVersions[v.key] != null &&
                    componentIsNewer(
                          verifiedComponentVersions[v.key]!,
                          v.value,
                        ) ==
                        true,
              );
              final coreCanUpdate =
                  component == VpnComponent.panel &&
                  c.panelAccess != null &&
                  componentIsNewer(
                        verifiedComponentVersions['xray']!,
                        c.panelAccess!.xrayVersion,
                      ) ==
                      true;
              final name = component == VpnComponent.amneziaWg
                  ? 'AmneziaWG'
                  : componentName(key);
              final status = versions.isNotEmpty
                  ? versions.entries
                        .map(
                          (v) => versions.length > 1
                              ? '${componentName(v.key)} ${v.value}'
                              : v.value,
                        )
                        .join(' · ')
                  : switch (presence) {
                      ComponentPresence.detected => l.inventoryDetected,
                      ComponentPresence.absent => l.inventoryAbsent,
                      ComponentPresence.unknown => l.inventoryUnknown,
                    };
              final installing = c.selected?.terminal == false;
              return Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: AppLayout.smallGap,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(name, style: Theme.of(context).textTheme.titleMedium),
                    Text(status),
                    if (changes.isNotEmpty)
                      Text(
                        '${l.softwareUpdateAvailable}: ${changes.join(', ')}',
                      ),
                    Wrap(
                      spacing: AppLayout.smallGap,
                      children: [
                        if (component == VpnComponent.panel &&
                            !c.panelDetected &&
                            !installing &&
                            c.panelPlan == null)
                          OutlinedButton(
                            key: const ValueKey('components-choose'),
                            onPressed: c.canPlan ? c.openPanelPlan : null,
                            child: Text(
                              presence == ComponentPresence.absent
                                  ? l.softwareInstall
                                  : l.softwareInspect,
                            ),
                          ),
                        if (component == VpnComponent.panel &&
                            c.panelDetected &&
                            c.panelUpdatePlan == null &&
                            (changes.isNotEmpty || canUpdate || coreCanUpdate))
                          OutlinedButton(
                            key: const ValueKey('panel-update'),
                            onPressed:
                                c.canPlan &&
                                    c.installed &&
                                    c.panelAccess != null &&
                                    !c.panelLoginRequired
                                ? c.preparePanelUpdate
                                : null,
                            child: Text(l.softwareUpdate),
                          ),
                        if (component == VpnComponent.trustTunnel ||
                            component == VpnComponent.amneziaWg)
                          if (presence != ComponentPresence.detected ||
                              (changes.isNotEmpty && canUpdate))
                            if (c.componentPlan?.component != key)
                              OutlinedButton(
                                key: ValueKey('component-$key'),
                                onPressed: c.canPlan
                                    ? () => c.prepareComponent(key)
                                    : null,
                                child: Text(
                                  presence == ComponentPresence.absent
                                      ? l.softwareInstall
                                      : presence == ComponentPresence.detected
                                      ? l.softwareUpdate
                                      : l.softwareInspect,
                                ),
                              ),
                        if (changes.isNotEmpty && !canUpdate)
                          TextButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text(l.softwareUpdateAvailable),
                                content: Text(
                                  component == VpnComponent.panel ||
                                          component == VpnComponent.xray
                                      ? l.panelUpdateCompatibility
                                      : l.componentUpdateUnverified,
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: Text(l.networkClose),
                                  ),
                                ],
                              ),
                            ),
                            child: Text(l.componentsDetails),
                          ),
                      ],
                    ),
                    if (component == VpnComponent.panel) ...[
                      for (final panel in c.panels)
                        if (panel['source'] == 'systemd' &&
                            (c.panelAccess?.port != panel['port'] ||
                                c.panelLoginRequired))
                          PanelLoginView(
                            controller: c,
                            port: panel['port'] as int,
                          ),
                      PanelInstallationView(controller: c, motion: motion),
                      PanelUpdateView(controller: c),
                    ],
                    if (c.componentPlan?.component == key)
                      ComponentInstallationView(controller: c),
                  ],
                ),
              );
            },
          ),
          const Divider(),
        ],
        if (updates != null) ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: updates.busy ? null : updates.check,
              icon: const Icon(Icons.refresh),
              label: Text(l.updatesCheck),
            ),
          ),
          UpdatesResult(controller: updates),
        ],
      ],
    );
  }
}

class AptMaintenanceView extends StatelessWidget {
  const AptMaintenanceView({required this.controller, super.key});
  final RunnerController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller, l = AppLocalizations.of(context);
    final packages = c.aptPlan?['packages'] as List?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppLayout.gap),
        Text(l.aptTitle, style: Theme.of(context).textTheme.titleMedium),
        if (!c.choosingAptUpdate && c.aptPlan == null)
          Wrap(
            spacing: AppLayout.smallGap,
            children: [
              TextButton(
                key: const ValueKey('apt-update'),
                onPressed: c.canPlan && c.installed
                    ? () => c.prepareApt(upgrade: false)
                    : null,
                child: Text(l.aptUpdate),
              ),
              TextButton(
                key: const ValueKey('apt-upgrade'),
                onPressed: c.canPlan && c.installed
                    ? () => c.prepareApt(upgrade: true)
                    : null,
                child: Text(l.aptUpgrade),
              ),
            ],
          ),
        if (c.choosingAptUpdate || packages != null) ...[
          Text(c.choosingAptUpdate ? l.aptUpdatePlan : l.aptUpgradePlan),
          if (packages != null) ...[
            Text(
              packages.isEmpty
                  ? l.aptCurrent
                  : l.aptPackageCount(packages.length),
            ),
            if (packages.isNotEmpty)
              ExpansionTile(
                key: const PageStorageKey('software-package-updates'),
                title: Text(l.componentsDetails),
                children: [
                  for (final p in packages)
                    ListTile(
                      dense: true,
                      title: Text(p['name'] as String),
                      subtitle: Text('${p['installed']} → ${p['version']}'),
                    ),
                ],
              ),
            if (c.aptPlan?['rebootRequired'] == true) Text(l.aptReboot),
          ],
          Wrap(
            spacing: AppLayout.smallGap,
            children: [
              if (c.choosingAptUpdate || packages?.isNotEmpty == true)
                FilledButton(
                  key: const ValueKey('apt-apply'),
                  onPressed: c.canStart ? c.applyApt : null,
                  child: Text(l.runnerApply),
                ),
              TextButton(
                onPressed: c.busy ? null : c.dismissApt,
                child: Text(l.runnerNotNow),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
