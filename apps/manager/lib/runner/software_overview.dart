import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../busy_reason.dart';
import '../l10n/app_localizations.dart';
import 'component_installation_view.dart';
import 'component_updates_controller.dart';
import 'component_versions_view.dart';
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
    var installationShown = false;
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
        // Versions read from the installed binaries win over the panel
        // access record, which can lag behind an upgrade.
        versions.putIfAbsent('panel', () => c.panelAccess!.panelVersion);
        versions.putIfAbsent('xray', () => c.panelAccess!.xrayVersion);
      }
      final updatable = updates == null
          ? const <String, String>{}
          : availableUpdates(updates, versions);
      final changes = [
        for (final u in updatable.entries) '${componentName(u.key)} ${u.value}',
      ];
      // Xray is upgraded only through XrayUpgradeView, which checks the
      // connections before and after and rolls back (UI-45).
      final canUpdate = versions.entries
          .where((v) => v.key != 'xray')
          .any(
            (v) =>
                (verifiedComponentVersions[v.key] != null &&
                    componentIsNewer(
                          verifiedComponentVersions[v.key]!,
                          v.value,
                        ) ==
                        true) ||
                (updates != null &&
                    updates.latest[v.key] != null &&
                    (componentIsNewer(updates.latest[v.key]!, v.value) ==
                            true ||
                        componentIsNewer(
                              updates.latest[v.key]!,
                              v.value,
                              allowPreview: true,
                            ) ==
                            true)),
          );
      final isPanel = component == VpnComponent.panel;
      final detected = presence == ComponentPresence.detected;
      final name = isPanel ? '3x-ui / Xray' : vpnComponentName(component);
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
          (c.selected?.kind == 'component_install' ||
              c.selected?.kind == 'component_upgrade' ||
              c.selected?.kind == 'component_upgrade_apply') &&
          c.selected?.terminal == false &&
          c.activeComponent == key;
      final isPanelJob =
          isPanel &&
          c.selected?.terminal == false &&
          (c.selected?.kind == 'panel_install' ||
              c.selected?.kind == 'panel_update' ||
              c.selected?.kind == 'xray_upgrade' ||
              ((c.selected?.kind == 'component_upgrade' ||
                      c.selected?.kind == 'component_upgrade_apply') &&
                  (c.activeComponent == 'panel' ||
                      c.activeComponent == 'xray')));
      final activeOnThisComponent = installingThis || isPanelJob;
      // The job's progress bar lives in its own view; the card keeps a
      // compact step count (UI-39).
      final action = activeOnThisComponent
          ? Text(
              key: ValueKey('software-progress-$key'),
              '${c.selected!.checkpoint}/${c.selected!.count}',
              style: Theme.of(context).textTheme.labelSmall,
            )
          : hasPlan || !applyAction
          // The one update check is the page's button (UI-45).
          ? null
          : AppDisabledReason(
              reason: busyReason(l, runner: c),
              child: OutlinedButton(
                key: ValueKey(
                  isPanel
                      ? (detected ? 'panel-update' : 'components-choose')
                      : 'component-$key',
                ),
                onPressed:
                    updates?.busy == true ||
                        c.busy ||
                        c.actionPending ||
                        !c.canRequestAction
                    ? null
                    : () => c.requestAction(() async {
                        if (isPanel &&
                            detected &&
                            (!await showPanelLogin(context, c) ||
                                !context.mounted)) {
                          return;
                        }
                        if (updates != null && updates.latest.isNotEmpty) {
                          // 3x-ui first; its own Xray when the panel is
                          // current. Asset for the server's architecture.
                          String? target;
                          for (final comp
                              in isPanel ? const ['panel'] : [key]) {
                            final latest = updates.latest[comp];
                            final current = versions[comp];
                            if (latest != null &&
                                (current == null ||
                                    componentIsNewer(
                                          latest,
                                          current,
                                          allowPreview: true,
                                        ) ==
                                        true)) {
                              target = comp;
                              break;
                            }
                          }
                          if (target != null &&
                              installerComponents.contains(target)) {
                            final choice = await updates.source
                                .resolveInstallerRelease(
                                  component: target,
                                  version: updates.latest[target]!,
                                );
                            if (choice != null) {
                              await c.prepareComponent(target, choice: choice);
                              await c.applyComponent();
                              return;
                            }
                          } else if (target != null &&
                              choosableComponents.contains(target)) {
                            final plans = await c.componentVersionPlans([
                              target,
                            ]);
                            final candidate = await updates.source.resolveAsset(
                              component: target,
                              version: updates.latest[target]!,
                              architecture: plans[target]?['arch'] as String?,
                            );
                            if (candidate != null) {
                              await c.installComponentVersion(candidate);
                              return;
                            }
                            if (c.error != null) return;
                          }
                        }
                        if (isPanel) {
                          if (c.panelDetected) {
                            await c.preparePanelUpdate();
                            await c.applyPanelUpdate();
                          } else {
                            await c.openPanelPlan();
                            await c.applyPanel();
                          }
                        } else {
                          await c.prepareComponent(key);
                          await c.applyComponent();
                        }
                      }),
                child: Text(
                  detected
                      ? l.softwareUpdate
                      : presence == ComponentPresence.absent
                      ? l.softwareInstall
                      : l.softwareInspect,
                ),
              ),
            );
      final choosable = [
        for (final k in versions.keys)
          if (choosableComponents.contains(k)) k,
      ];
      final summary = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(status),
          if (detected && updates != null && choosable.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppDisabledReason(
                reason: busyReason(l, runner: c),
                child: TextButton.icon(
                  key: ValueKey('component-versions-$key'),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: c.busy || !c.canRequestAction
                      ? null
                      : () => showComponentVersions(
                          context,
                          controller: c,
                          updates: updates,
                          title: name,
                          installed: {
                            for (final k in choosable) k: versions[k]!,
                          },
                        ),
                  icon: const Icon(Icons.history, size: 18),
                  label: Text(l.versionsChoose),
                ),
              ),
            ),
          if (changes.isNotEmpty)
            Text(l.softwareUpdateAvailableList(changes.join(', '))),
          if (updatable.keys.any((k) => k != 'xray') && !canUpdate)
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
          others.add(
            const Divider(indent: AppLayout.gap, endIndent: AppLayout.gap),
          );
        }
        others.add(
          SummaryCard(
            embedded: true,
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
      if (!installationShown && hostsComponentInstallation(c, key)) {
        installationShown = true;
        content.add(ComponentInstallationView(controller: c));
      }
    }
    if (updates != null) {
      if (updates.busy) content.add(const LinearProgressIndicator());
      if (updates.failed) {
        content.add(AppNotice(message: l.updatesFailed, error: true));
      }
      if (updates.storageFailed) {
        content.add(AppNotice(message: l.settingsSaveError, error: true));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPageIntro(l.uiInstalledComponents),
        if (available.isNotEmpty) ...[
          AppSectionHeading(title: l.softwareUpdateAvailable, subheader: true),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OutlinedButton.icon(
                  // A GitHub request: no SSH or runner refresh (UI-45).
                  key: const ValueKey('updates-check'),
                  onPressed: updates.busy ? null : updates.check,
                  icon: const Icon(Icons.refresh),
                  label: Text(l.updatesCheck),
                ),
                if (updates.throttled || updates.checkedAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        key: const ValueKey('updates-checked-at'),
                        updates.throttled
                            ? l.updatesCheckedRecently
                            : l.updatesLastChecked(
                                DateFormat.yMMMd(
                                  l.localeName,
                                ).add_Hm().format(updates.checkedAt!.toLocal()),
                              ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
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
