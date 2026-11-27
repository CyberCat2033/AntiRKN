import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../busy_reason.dart';
import '../l10n/app_localizations.dart';
import '../protocol_icon.dart';
import 'component_installation_view.dart';
import 'component_updates_controller.dart';
import 'component_versions_view.dart';
import 'panel_installation_view.dart';
import 'panel_update_view.dart';
import 'panel_login_view.dart';
import 'runner_controller.dart';
import 'runner_panel.dart' show runnerEventLabel, runnerStateLabel;
import 'xray_upgrade_view.dart' show xrayProgress;

class SoftwareOverview extends StatelessWidget {
  const SoftwareOverview({
    required this.controller,
    required this.motion,
    this.coreUpgrade,
    super.key,
  });
  final RunnerController controller;
  final MotionPreference motion;

  /// The checked Xray core transaction ([XrayUpgradeView]): under the
  /// 3x-ui / Xray row, and mounted even without one, since it owns the
  /// runner's Xray version choice.
  final Widget? coreUpgrade;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // The Xray transaction lives in its view; its progress is drawn here.
    listenable: controller.xrayRevision,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final c = controller, l = AppLocalizations.of(context);
    final updates = ComponentUpdatesScope.of(context);
    final inventory = c.software?.call();
    final content = <Widget>[];
    final core = coreUpgrade == null
        ? null
        : KeyedSubtree(
            key: const ValueKey('software-xray-upgrade'),
            child: coreUpgrade!,
          );
    final available = <Widget>[];
    final others = <Widget>[];
    var installationShown = false, coreShown = false;
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
      var inDocker = false;
      for (final observation
          in inventory?.components ?? <ComponentObservation>[]) {
        if (observation.component != component &&
            !(component == VpnComponent.panel &&
                observation.component == VpnComponent.xray)) {
          continue;
        }
        inDocker = inDocker || awgOnlyInDocker(observation);
        for (final installation in observation.installations) {
          if (installation.version?.value case final version?) {
            if (installationReleaseKey(observation.component, installation)
                case final key?) {
              versions[key] = version;
            }
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
      // Xray is upgraded only through the checked transaction of
      // XrayUpgradeView, which compares the connections before and after
      // and rolls back (UI-45).
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
      // Only the core is behind: Update runs the checked Xray transaction.
      final xray = isPanel && detected && !canUpdate
          ? c.xrayVersionChoice
          : null;
      final xrayUpdate = xray != null && updatable.containsKey('xray');
      final name = isPanel ? '3x-ui / Xray' : vpnComponentName(component);
      // One line: each installed version and, when newer, its update
      // ("3x-ui 3.7.0 → 3.11.0 · Xray 26.7.28 → 26.11.9").
      final status = versions.isNotEmpty
          ? versions.entries
                .map(
                  (v) => [
                    if (versions.length > 1) componentName(v.key),
                    v.value,
                    if (updatable[v.key] case final target?) '→ $target',
                  ].join(' '),
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
      // No update path for an AmneziaWG container: no Update, no version
      // choice, a note instead.
      final applyAction = !detected || (canUpdate && !inDocker) || xrayUpdate;
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
      final hostsInstallation =
          !installationShown && hostsComponentInstallation(c, key);
      if (hostsInstallation) installationShown = true;
      // Variant B: the running install or update lives in the card itself,
      // a ring around its icon, the step under the versions, Stop in place
      // of Update and Versions.
      final progress =
          (isPanel ? componentProgress(context, c, panel: true) : null) ??
          (hostsInstallation ? componentProgress(context, c) : null) ??
          (isPanel ? xrayProgress(context, c.xrayVersionChoice) : null);
      // The job's progress lives in the card body, like the Xray one.
      final action = progress != null
          ? progress.stop
          : activeOnThisComponent
          ? null
          : hasPlan || !applyAction
          // The one update check is the page's button (UI-45).
          ? null
          : AppDisabledReason(
              reason: busyReason(l, runner: c),
              child: FilledButton.tonal(
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
                    : xrayUpdate
                    ? () async {
                        if (xray.ready()) {
                          await xray.update(updatable['xray']!);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l.versionsXrayUnavailable)),
                          );
                        }
                      }
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
        if (!inDocker)
          for (final k in versions.keys)
            if (choosableComponents.contains(k)) k,
      ];
      final versionsAction =
          progress == null &&
              detected &&
              updates != null &&
              choosable.isNotEmpty
          ? AppDisabledReason(
              reason: busyReason(l, runner: c),
              child: TextButton.icon(
                key: ValueKey('component-versions-$key'),
                onPressed: c.busy || !c.canRequestAction
                    ? null
                    : () => showComponentVersions(
                        context,
                        controller: c,
                        updates: updates,
                        title: name,
                        installed: {for (final k in choosable) k: versions[k]!},
                      ),
                icon: const Icon(Icons.history),
                label: Text(l.versionsChoose),
              ),
            )
          : null;
      // Versions and the main action share one row: beside the summary on
      // wide cards, below it on narrow ones.
      final actions = versionsAction == null && action == null
          ? null
          : Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppLayout.smallGap,
              runSpacing: AppLayout.smallGap,
              children: [?versionsAction, ?action],
            );
      final summary = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(status),
          if (progress != null) ...[
            Text(
              key: ValueKey('software-step-$key'),
              progress.step,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            if (progress.note case final note?) Text(note),
          ],
          if (inDocker && detected && (updatable.isNotEmpty || canUpdate))
            Text(
              key: ValueKey('software-docker-$key'),
              l.softwareAwgDockerUpdate,
            )
          else if (updatable.keys.any((k) => k != 'xray') && !canUpdate)
            Text(
              isPanel
                  ? l.panelUpdateCompatibility
                  : l.componentUpdateUnverified,
            ),
          // Installs and updates belong to their card, like the Xray move.
          if (isPanel)
            PanelUpdateView(
              controller: c,
              installed: versions,
              progressInCard: true,
            ),
          if (hostsInstallation)
            ComponentInstallationView(
              controller: c,
              installed: versions,
              progressInCard: true,
            ),
          if (isPanel && core != null) ...[
            const SizedBox(height: AppLayout.smallGap),
            core,
          ],
        ],
      );
      if (isPanel && core != null) coreShown = true;
      if (updatable.isNotEmpty || canUpdate) {
        available.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SummaryCard(
              leading: AppIconTile(
                icon: protocolIcon(key),
                busy: progress != null,
                value: progress?.value,
              ),
              leadingAtTop: true,
              title: name,
              subtitle: summary,
              action: actions,
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
              icon: protocolIcon(key),
              busy: progress != null,
              value: progress?.value,
            ),
            leadingAtTop: true,
            title: name,
            subtitle: summary,
            action: actions,
          ),
        );
      }
      if (isPanel) {
        content.add(PanelInstallationView(controller: c, motion: motion));
      }
    }
    if (core != null && !coreShown) content.add(core);
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

/// Ubuntu packages as one software card, like the components (variant A):
/// Check refreshes the package lists and shows what can be upgraded,
/// Update installs it; while a job runs, a ring around the icon, its step
/// and Stop. The server restart ([reboot]) lives here too.
class AptMaintenanceView extends StatelessWidget {
  const AptMaintenanceView({required this.controller, this.reboot, super.key});
  final RunnerController controller;

  /// Restarts the server and tracks its reconnect; kept in one place of the
  /// card so its state survives the card's changes.
  final Widget? reboot;
  @override
  Widget build(BuildContext context) {
    final c = controller, l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final packages = c.aptPlan?['packages'] as List?;
    final job = switch (c.selected) {
      final j?
          when aptCardJobs.contains(j.kind) &&
              (!j.terminal || !c.isDismissed(j)) =>
        j,
      _ => null,
    };
    final running = job != null && !job.terminal;
    final preparing =
        !running && c.choosingAptUpdate && (c.busy || c.actionPending);
    final failed =
        job != null &&
        job.terminal &&
        const {'failed', 'partially_applied', 'cancelled'}.contains(job.status);
    final event = job?.events.lastOrNull;
    final restart =
        job?.kind == 'server_reboot' ||
        job?.kind == 'apt_upgrade' &&
            job!.status == 'succeeded' &&
            job.events.any((e) => e.code == 'apt_reboot_required');
    final String? step = running
        ? job.cancelRequested
              ? l.runnerCancelRequested
              : switch (job.kind) {
                  'apt_update' => l.aptUpdating,
                  'apt_upgrade' => l.aptUpgrading,
                  _ =>
                    event != null
                        ? runnerEventLabel(l, event.code)
                        : runnerStateLabel(l, job.status),
                }
        : preparing
        ? l.softwarePreparing
        : null;
    final status = failed
        ? null
        : packages != null
        ? (packages.isEmpty
              ? l.aptUpToDate
              : l.aptPackageCount(packages.length))
        : job?.kind == 'apt_upgrade' && job!.status == 'succeeded'
        ? [l.aptUpToDate, if (restart) l.aptRestartRequired].join(' · ')
        : step == null
        ? l.aptNotChecked
        : null;
    final idle = c.busy || c.actionPending || !c.canRequestAction;
    final Widget? action = running
        ? FilledButton.tonal(
            key: const ValueKey('apt-cancel'),
            onPressed: !c.busy && !c.actionPending && !job.cancelRequested
                ? c.cancelJob
                : null,
            child: Text(l.softwareStop),
          )
        : preparing
        ? null
        : Wrap(
            alignment: WrapAlignment.end,
            spacing: AppLayout.smallGap,
            runSpacing: AppLayout.smallGap,
            children: [
              if (failed)
                TextButton(
                  key: const ValueKey('apt-close'),
                  onPressed: c.busy ? null : c.dismissJob,
                  child: Text(l.networkClose),
                ),
              if (packages?.isNotEmpty == true) ...[
                TextButton(
                  key: const ValueKey('apt-packages'),
                  onPressed: () => showAppDetails(
                    context,
                    title: l.aptPackageCount(packages!.length),
                    children: [
                      for (final p in packages)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(p['name'] as String),
                          subtitle: Text('${p['installed']} → ${p['version']}'),
                        ),
                    ],
                  ),
                  child: Text(l.aptPackages),
                ),
                FilledButton.tonal(
                  key: const ValueKey('apt-apply'),
                  onPressed: c.canStart && !idle ? c.applyApt : null,
                  child: Text(l.softwareUpdate),
                ),
              ] else
                AppDisabledReason(
                  reason: busyReason(l, runner: c),
                  child: FilledButton.tonal(
                    key: const ValueKey('system-update'),
                    onPressed: idle
                        ? null
                        : () => c.requestAction(
                            () => c.updateSystem(upgrade: false),
                          ),
                    child: Text(l.uiCheck),
                  ),
                ),
            ],
          );
    return AppSettingsSection(
      title: l.aptTitle,
      child: SummaryCard(
        embedded: true,
        leadingAtTop: true,
        leading: AppIconTile(
          icon: Icons.dns_outlined,
          busy: running || preparing,
          value: running && job.count > 0 && job.checkpoint > 0
              ? job.checkpoint / job.count
              : null,
        ),
        title: 'Ubuntu',
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (status != null) Text(key: const ValueKey('apt-status'), status),
            if (step != null)
              Text(
                key: const ValueKey('apt-step'),
                step,
                style: TextStyle(color: colors.primary),
              ),
            if (failed)
              Text(
                key: const ValueKey('apt-failed'),
                event != null && event.code != 'failed'
                    ? runnerEventLabel(l, event.code)
                    : runnerStateLabel(l, job.status),
                style: TextStyle(color: colors.error),
              ),
            if (reboot case final restartAction? when restart)
              Padding(
                key: const ValueKey('apt-reboot'),
                padding: const EdgeInsets.only(top: AppLayout.smallGap),
                child: restartAction,
              ),
          ],
        ),
        action: action,
      ),
    );
  }
}

/// Jobs the Ubuntu card draws instead of the runner panel.
const aptCardJobs = {'apt_update', 'apt_upgrade', 'server_reboot'};
