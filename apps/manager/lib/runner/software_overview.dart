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
    final content = <Widget>[];
    final available = <Widget>[];
    final others = <Widget>[];
    if (!c.connected) content.add(AppNotice(message: l.inventoryStale));
    for (final component in [
      VpnComponent.panel,
      VpnComponent.trustTunnel,
      VpnComponent.amneziaWg,
    ]) {
      final key = releaseKey(component, '');
      final presence = component == VpnComponent.panel && c.panelDetected
          ? ComponentPresence.detected
          : c.presence(component);
      final versions = <String, String>{};
      for (final observation
          in inventory?.components ?? <ComponentObservation>[]) {
        if (observation.component != component &&
            !(component == VpnComponent.panel &&
                observation.component == VpnComponent.xray)) {
          continue;
        }
        for (final installation in observation.installations) {
          if (installation.version?.value case final version?) {
            versions[releaseKey(observation.component, installation.identity)] =
                version;
          }
        }
      }
      if (component == VpnComponent.panel && c.panelAccess != null) {
        versions['panel'] = c.panelAccess!.panelVersion;
        versions['xray'] = c.panelAccess!.xrayVersion;
      }
      final changes = <String>[];
      if (updates != null && (updates.suggestions || updates.manualResults)) {
        for (final v in versions.entries) {
          final latest = updates.latest[v.key];
          if (latest != null && componentIsNewer(latest, v.value) == true) {
            changes.add('${componentName(v.key)} $latest');
          }
        }
      }
      final canUpdate = versions.entries.any(
        (v) =>
            (verifiedComponentVersions[v.key] != null &&
                componentIsNewer(verifiedComponentVersions[v.key]!, v.value) ==
                    true) ||
            (updates?.latest[v.key] != null &&
                componentIsNewer(updates!.latest[v.key]!, v.value) == true),
      );
      final isPanel = component == VpnComponent.panel;
      final detected = presence == ComponentPresence.detected;
      final name = isPanel
          ? '3x-ui / Xray'
          : component == VpnComponent.amneziaWg
          ? 'AmneziaWG'
          : 'TrustTunnel';
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
      final hasPlan = isPanel
          ? c.panelPlan != null || c.panelUpdatePlan != null
          : c.componentPlan?.component == key;
      final applyAction = !detected || canUpdate;
      final installingThis =
          c.selected?.kind == 'component_install' &&
          c.selected?.terminal == false &&
          c.activeComponent == key;
      final action = installingThis
          ? SizedBox(
              width: 80,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${c.selected!.checkpoint}/${c.selected!.count}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: c.selected!.count > 0 && c.selected!.checkpoint > 0
                        ? c.selected!.checkpoint / c.selected!.count
                        : null,
                  ),
                ],
              ),
            )
          : hasPlan || c.selected?.terminal == false
          ? null
          : OutlinedButton(
              key: ValueKey(
                applyAction
                    ? isPanel
                          ? (detected ? 'panel-update' : 'components-choose')
                          : 'component-$key'
                    : 'software-check-$key',
              ),
              onPressed: !c.canRequestAction || updates?.busy == true
                  ? null
                  : applyAction
                  ? () async {
                      if (isPanel &&
                          detected &&
                          (!await showPanelLogin(context, c) ||
                              !context.mounted)) {
                        return;
                      }
                      await c.installOrUpdate(isPanel ? 'panel' : key);
                    }
                  : updates == null
                  ? null
                  : () => c.requestAction(updates.check),
              child: Text(
                applyAction
                    ? detected
                          ? l.softwareUpdate
                          : presence == ComponentPresence.absent
                          ? l.softwareInstall
                          : l.softwareInspect
                    : l.uiCheck,
              ),
            );
      final summary = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(status),
          if (changes.isNotEmpty)
            Text('${l.softwareUpdateAvailable}: ${changes.join(', ')}'),
          if (changes.isNotEmpty && !canUpdate)
            Text(
              isPanel
                  ? l.panelUpdateCompatibility
                  : l.componentUpdateUnverified,
            ),
        ],
      );
      if (changes.isNotEmpty || canUpdate) {
        available.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SummaryCard(
              leading: AppIconTile(
                icon: isPanel
                    ? Icons.inventory_2_outlined
                    : Icons.shield_outlined,
              ),
              title: name,
              subtitle: summary,
              action: action,
            ),
          ),
        );
      } else {
        if (others.isNotEmpty) {
          others.add(const Divider(indent: 17, endIndent: 17));
        }
        others.add(
          SummaryCard(
            leading: AppIconTile(
              icon: isPanel ? Icons.dns_outlined : Icons.shield_outlined,
            ),
            title: name,
            subtitle: summary,
            action: action,
          ),
        );
      }
      if (isPanel) {
        content.addAll([
          PanelInstallationView(controller: c, motion: motion),
          PanelUpdateView(controller: c),
        ]);
      }
      if (c.componentPlan?.component == key ||
          (c.activeComponent == key &&
              c.selected?.kind == 'component_install' &&
              (c.selected?.terminal == false ||
                  const {
                    'failed',
                    'partially_applied',
                  }.contains(c.selected?.status)))) {
        content.add(ComponentInstallationView(controller: c));
      }
    }
    if (updates != null) {
      if (updates.busy) content.add(const LinearProgressIndicator());
      if (updates.failed) content.add(Text(l.updatesFailed));
      if (updates.storageFailed) content.add(Text(l.settingsSaveError));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPageIntro(l.uiInstalledComponents),
        if (available.isNotEmpty) ...[
          AppSectionHeading(title: l.softwareUpdateAvailable, uppercase: true),
          ...available,
          const SizedBox(height: 16),
        ],
        if (others.isNotEmpty)
          AppSettingsSection(
            title: l.uiOtherComponents,
            child: Column(children: others),
          ),
        ...content,
        if (updates != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: OutlinedButton.icon(
              onPressed: updates.busy || !c.canRequestAction
                  ? null
                  : () => c.requestAction(updates.check),
              icon: const Icon(Icons.refresh),
              label: Text(l.updatesCheck),
            ),
          ),
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
    if (!c.choosingAptUpdate && c.aptPlan == null) {
      return AppSettingsSection(
        title: l.aptTitle,
        child: ListTile(
          key: const ValueKey('system-update'),
          leading: const AppIconTile(icon: Icons.dns_outlined),
          title: Text(l.uiSystemUpdate),
          subtitle: Text(l.uiSystemUpdateHelp),
          trailing: const Icon(Icons.chevron_right),
          onTap: c.canRequestAction
              ? () => c.requestAction(c.updateSystem)
              : null,
        ),
      );
    }
    return SectionCard(
      title: l.aptTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!c.choosingAptUpdate && c.aptPlan == null) ...[
            Text(l.uiSystemUpdateHelp),
            const SizedBox(height: AppLayout.smallGap),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonal(
                key: const ValueKey('system-update'),
                onPressed: c.canRequestAction
                    ? () => c.requestAction(c.updateSystem)
                    : null,
                child: Text(l.uiSystemUpdate),
              ),
            ),
          ],
          if (c.choosingAptUpdate || packages != null) ...[
            Text(c.choosingAptUpdate ? l.aptUpdatePlan : l.aptUpgradePlan),
            if (packages != null) ...[
              Text(
                packages.isEmpty
                    ? l.aptCurrent
                    : l.aptPackageCount(packages.length),
              ),
              if (packages.isNotEmpty)
                AppExpansionTile(
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
                    child: Text(l.softwareUpdate),
                  ),
                TextButton(
                  onPressed: c.busy ? null : c.dismissApt,
                  child: Text(l.runnerNotNow),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
