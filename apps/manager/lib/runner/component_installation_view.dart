import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'runner_controller.dart';
import 'component_updates_controller.dart';
import 'component_upgrade_checks_view.dart';
import 'runner_panel.dart' show runnerEventLabel;

/// The install or update of TrustTunnel or AmneziaWG on its software card,
/// drawn like the Xray transaction: a progress card while it runs, a short
/// notice when it cannot start or failed (UI-39).
class ComponentInstallationView extends StatelessWidget {
  const ComponentInstallationView({
    required this.controller,
    this.installed = const {},
    this.progressInCard = false,
    super.key,
  });
  final RunnerController controller;

  /// The software card draws the running state ([softwareProgress]); the
  /// view keeps only notices. Without a card it draws a progress card.
  final bool progressInCard;

  /// Installed versions of the card, by release key.
  final Map<String, String> installed;
  @override
  Widget build(BuildContext context) {
    final c = controller, l = AppLocalizations.of(context);
    final plan = c.componentPlan;
    final job = c.selected;
    final title = softwareJobTitle(
      c.activeComponent ?? plan?.component,
      installed[c.activeComponent ?? plan?.component] ?? plan?.installedVersion,
      plan?.version ?? c.componentTarget,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ComponentUpgradeChecksView(
          controller: c,
          progressInCard: progressInCard,
        ),
        if (!progressInCard && !c.upgradeChecking)
          if (componentProgress(context, c) case final progress?)
            SoftwareProgressCard(
              key: const ValueKey('software-job'),
              title: title,
              progress: progress,
            ),
        if (plan != null && !(plan.canApply && c.busy))
          AppNotice(
            key: const ValueKey('component-plan'),
            title: title,
            message: plan.canApply
                // Prepared but not started (the start was refused).
                ? l.protocolPrepared
                : !plan.supported
                ? l.protocolPrerequisites
                : switch (plan.state) {
                    'conflict' => l.protocolExisting,
                    'current' => l.protocolCurrent,
                    _ => l.runnerIncompatible,
                  },
            action: TextButton(
              onPressed: c.busy ? null : c.dismissComponent,
              child: Text(l.networkClose),
            ),
          ),
        if (job?.kind == 'component_install' &&
            const {'failed', 'partially_applied'}.contains(job?.status))
          AppNotice(
            title: title,
            message: job?.status == 'partially_applied'
                ? l.componentsPartial
                : l.softwareFailed,
            error: true,
            action: TextButton(
              key: const ValueKey('component-retry'),
              onPressed: c.canRequestAction ? c.retryJob : null,
              child: Text(l.runnerRetry),
            ),
          ),
      ],
    );
  }
}

/// "AmneziaWG Go 3.1.1 → 3.1.2": the title of a software job.
String softwareJobTitle(String? key, String? from, String? to) => [
  key == null ? '' : componentName(key),
  ?from,
  if (to != null && to != from) '→ $to',
].where((p) => p.isNotEmpty).join(' ');

/// What a software card shows while its install or update runs, in place
/// of its own actions: the step in words (and a [note]), the ring around
/// its icon and Stop, null when it cannot be stopped.
typedef SoftwareProgress = ({
  String step,
  String? note,
  double? value,
  Widget? stop,
});

/// The running state of a TrustTunnel or AmneziaWG install or update (or
/// of a 3x-ui one with [panel]): preparing, a checked upgrade or the job.
SoftwareProgress? componentProgress(
  BuildContext context,
  RunnerController c, {
  bool panel = false,
}) {
  final l = AppLocalizations.of(context);
  final canApply = panel
      ? c.panelUpdatePlan?.canApply
      : c.componentPlan?.canApply;
  // Every caller applies the plan at once: no plan text.
  if (canApply == true && c.busy) {
    return (step: l.softwarePreparing, note: null, value: null, stop: null);
  }
  if (!panel) {
    if (upgradeChecksProgress(context, c) case final checks?) return checks;
    if (c.upgradeChecking) return null;
  }
  final job = c.selected;
  final kinds = panel
      ? const {'panel_install', 'panel_update'}
      : const {'component_install', 'component_upgrade_apply'};
  if (job == null || job.terminal || !kinds.contains(job.kind)) return null;
  final code = job.events.lastOrNull?.code;
  return (
    step: job.cancelRequested
        ? l.runnerCancelRequested
        : job.kind == 'component_install'
        ? componentActiveStepLabel(l, job.checkpoint)
        : code == null || const {'planned', 'running'}.contains(code)
        ? l.upgradeChecksUpgrading
        : runnerEventLabel(l, code),
    note: null,
    value: job.count > 0 && job.checkpoint > 0
        ? job.checkpoint / job.count
        : null,
    stop: FilledButton.tonal(
      key: const ValueKey('component-cancel'),
      onPressed: !c.busy && !c.actionPending && !job.cancelRequested
          ? c.cancelJob
          : null,
      child: Text(l.softwareStop),
    ),
  );
}

/// [SoftwareProgress] on its own, where no software card hosts it (a job
/// whose component is not known after a restart).
class SoftwareProgressCard extends StatelessWidget {
  const SoftwareProgressCard({
    required this.title,
    required this.progress,
    this.icon = Icons.system_update_alt,
    super.key,
  });
  final String title;
  final SoftwareProgress progress;
  final IconData icon;
  @override
  Widget build(BuildContext context) => AppProgressCard(
    icon: icon,
    title: title.isEmpty ? AppLocalizations.of(context).softwareUpdate : title,
    status: progress.step,
    value: progress.value,
    notes: [?progress.note],
    actions: [?progress.stop],
  );
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

/// Installed components with a newer upstream release: key → latest.
///
/// The one rule for the update counter and the software cards (UI-46).
Map<String, String> availableUpdates(
  ComponentUpdatesController updates,
  Map<String, String> installed,
) => {
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
    (c.activeComponent == key && c.upgradeCheckPhase != null) ||
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

/// Release key of an installation identity. AmneziaWG has two programs:
/// the `awg` tool (amneziawg-tools) and `amneziawg-go`. The program is the
/// last part of a binary path (`/usr/bin/awg`) or of a Docker identity
/// (`<image> · <id> · awg`); an image name is never read for it.
String releaseKey(VpnComponent component, String identity) =>
    switch (component) {
      VpnComponent.panel => 'panel',
      VpnComponent.xray => 'xray',
      VpnComponent.trustTunnel => 'trusttunnel',
      VpnComponent.amneziaWg =>
        identity.split(' · ').last.split('/').last == 'awg'
            ? 'amneziawgTools'
            : 'amneziawg',
    };

/// Release key whose upstream versions apply to [installation], or null.
/// The AmneziaWG kernel module has no release the app tracks: its version
/// is not an AmneziaWG Go version.
String? installationReleaseKey(
  VpnComponent component,
  ComponentInstallation installation,
) => installation.source == InstallationSource.kernel
    ? null
    : releaseKey(component, installation.identity);

/// AmneziaWG runs only in Docker here: the app has no update path for a
/// container, so it offers no update or version choice for it.
bool awgOnlyInDocker(ComponentObservation? observation) =>
    observation?.component == VpnComponent.amneziaWg &&
    observation!.installations.any(
      (i) => i.source == InstallationSource.docker,
    ) &&
    !observation.installations.any(
      (i) => i.source == InstallationSource.binary,
    );

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
