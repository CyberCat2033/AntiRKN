import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import 'runner_controller.dart';
import 'panel_installation_view.dart';
import 'component_installation_view.dart';

class RunnerPanel extends StatelessWidget {
  const RunnerPanel({
    required this.controller,
    required this.motion,
    super.key,
  });
  final RunnerController controller;
  final MotionPreference motion;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      final l = AppLocalizations.of(context);
      final job = c.selected;
      final installing =
          const {'panel_install', 'component_install'}.contains(job?.kind) &&
          !job!.terminal;
      final panelFlow = c.choosingPanel || installing;
      final duration = AppMotion.duration(context, motion);
      final animation = AnimationStyle(
        duration: duration,
        reverseDuration: duration,
      );
      final stateLabel = job == null ? null : runnerStateLabel(l, job.status);
      final eventLabel = job?.events.isNotEmpty == true
          ? runnerEventLabel(l, job!.events.last.code)
          : null;
      return SectionCard(
        title: l.runnerTitle,
        child: AppAnimatedSize(
          motion: motion,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.busy && !installing) const LinearProgressIndicator(),
              if (c.error case final issue?)
                Semantics(
                  liveRegion: true,
                  child: Text(runnerIssueLabel(l, issue)),
                ),
              if (c.responseCode != null && c.responseCode != 'ok')
                Text(runnerCodeLabel(l, c.responseCode!)),
              if (c.connectionLost ||
                  !c.connected && job != null && !job.terminal)
                Text(l.runnerConnectionLost),
              const SizedBox(height: AppLayout.gap),
              PanelInstallationView(controller: c, motion: motion),
              ComponentInstallationView(controller: c),
              const SizedBox(height: AppLayout.gap),
              Wrap(
                spacing: AppLayout.smallGap,
                runSpacing: AppLayout.smallGap,
                children: [
                  OutlinedButton(
                    key: const ValueKey('runner-refresh'),
                    onPressed: c.connected && !c.busy ? c.refresh : null,
                    child: Text(l.sshRefresh),
                  ),
                  if (!panelFlow &&
                      (!c.installed || c.installation?.active == false))
                    FilledButton.tonal(
                      key: const ValueKey('runner-prepare'),
                      onPressed: c.connected && !c.busy
                          ? c.prepareInstall
                          : null,
                      child: Text(l.runnerPrepare),
                    ),
                  if (c.installed && !panelFlow)
                    FilledButton(
                      key: const ValueKey('runner-start'),
                      onPressed: c.canStart ? c.startDiagnostic : null,
                      child: Text(l.runnerStart),
                    ),
                ],
              ),
              if (c.installPlan != null) ...[
                const SizedBox(height: AppLayout.gap),
                Text(
                  l.runnerPlanTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(l.runnerPlanBody),
                const SizedBox(height: AppLayout.smallGap),
                const SelectableText(
                  '/usr/local/lib/antirkn-runner/v4/\n/etc/systemd/system/antirkn-runner.service\n/var/lib/antirkn-runner/',
                ),
                Text(l.runnerPlanRelease),
                SelectableText(c.bundledRelease ?? ''),
                Wrap(
                  spacing: AppLayout.smallGap,
                  children: [
                    FilledButton(
                      key: const ValueKey('runner-apply'),
                      onPressed: c.connected && !c.busy ? c.applyInstall : null,
                      child: Text(l.runnerApply),
                    ),
                    TextButton(
                      onPressed: c.busy ? null : c.dismissPlan,
                      child: Text(l.runnerNotNow),
                    ),
                  ],
                ),
              ],
              if (c.pending != null) ...[
                Text(l.runnerPending),
                OutlinedButton(
                  key: const ValueKey('runner-retry'),
                  onPressed: c.connected && !c.busy ? c.retryPending : null,
                  child: Text(l.runnerRetry),
                ),
              ],
              if (c.installed && !c.alive) Text(l.runnerNotRunning),
              if (job != null) ...[
                const SizedBox(height: AppLayout.gap),
                if (job.kind == 'panel_install') Text(l.componentsJob),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    '${installing ? eventLabel ?? stateLabel : stateLabel} · ${job.checkpoint}/${job.count}',
                  ),
                ),
                if (const {
                      'panel_install',
                      'component_install',
                    }.contains(job.kind) &&
                    job.terminal &&
                    eventLabel != null &&
                    eventLabel != stateLabel)
                  Text(eventLabel),
                LinearProgressIndicator(value: job.checkpoint / job.count),
                if (job.cancelRequested && !job.terminal)
                  Text(l.runnerCancelRequested),
                if (!job.terminal)
                  TextButton(
                    key: const ValueKey('runner-cancel'),
                    onPressed: c.connected && !c.busy && !job.cancelRequested
                        ? c.cancelJob
                        : null,
                    child: Text(l.runnerCancel),
                  ),
                if (c.eventsTruncated) Text(l.runnerEventsTruncated),
                ExpansionTile(
                  key: PageStorageKey('runner-journal-${c.serverId}-${job.id}'),
                  expansionAnimationStyle: animation,
                  title: Text(l.runnerJournal),
                  children: [
                    for (final event in job.events)
                      ListTile(
                        dense: true,
                        title: Text(runnerEventLabel(l, event.code)),
                        subtitle: Text(
                          '${DateFormat.Hms(l.localeName).format(event.timestamp.toLocal())} · ${event.progress}/${event.total}',
                        ),
                      ),
                  ],
                ),
              ],
              if (c.jobs.length > 1)
                ExpansionTile(
                  key: PageStorageKey('runner-history-${c.serverId}'),
                  expansionAnimationStyle: animation,
                  title: Text(l.runnerHistory),
                  children: [
                    for (final previous in c.jobs)
                      ListTile(
                        title: Text(runnerStateLabel(l, previous.status)),
                        subtitle: Text(
                          '${previous.checkpoint}/${previous.count} · ${previous.id.substring(0, 8)}',
                        ),
                        selected: previous.id == job?.id,
                        onTap: c.connected && !c.busy && c.pending == null
                            ? () => c.selectJob(previous.id)
                            : null,
                      ),
                  ],
                ),
            ],
          ),
        ),
      );
    },
  );
}

String runnerIssueLabel(AppLocalizations l, RunnerIssue issue) =>
    switch (issue) {
      RunnerIssue.prerequisites => l.runnerPrerequisites,
      RunnerIssue.conflict => l.runnerConflict,
      RunnerIssue.incompatible => l.runnerIncompatible,
      RunnerIssue.installFailed => l.runnerInstallFailed,
      RunnerIssue.invalidResponse => l.runnerInvalidResponse,
      RunnerIssue.unavailable => l.runnerUnavailable,
      RunnerIssue.storage => l.runnerStorage,
    };
String runnerCodeLabel(AppLocalizations l, String code) => switch (code) {
  'busy' => l.runnerBusy,
  'conflict' => l.runnerConflict,
  'missing' => l.runnerMissing,
  'incompatible' => l.runnerIncompatible,
  'capacity' => l.runnerCapacity,
  _ => l.runnerInvalidResponse,
};
String runnerStateLabel(AppLocalizations l, String state) => switch (state) {
  'planned' => l.runnerPlanned,
  'running' => l.runnerRunning,
  'succeeded' => l.runnerSucceeded,
  'cancelled' => l.runnerCancelled,
  'failed' => l.runnerFailed,
  'partially_applied' => l.runnerPartial,
  _ => l.runnerAttention,
};
String runnerEventLabel(AppLocalizations l, String code) => switch (code) {
  'component_prepared' => l.protocolPrepared,
  'component_downloaded' => l.componentsDownloaded,
  'component_built' => l.protocolBuilt,
  'component_staged' => l.protocolStaged,
  'component_switched' => l.protocolSwitched,
  'component_checked' => l.componentsChecked,
  'component_conflict' => l.runnerConflict,
  'component_incompatible' => l.runnerIncompatible,
  'component_download_failed' => l.componentsDownloadFailed,
  'component_checksum_failed' => l.componentsChecksumFailed,
  'component_build_failed' => l.protocolBuildFailed,
  'component_check_failed' => l.protocolCheckFailed,
  'component_prerequisites' => l.protocolPrerequisites,
  'component_partial' => l.componentsPartial,
  'vless_preparing' => l.vpnPrepareStep,
  'vless_applying' => l.vpnApplying,
  'vless_checking' => l.vpnChecking,
  'vless_conflict' => l.vpnConflict,
  'vless_port_busy' => l.vpnPortBusy,
  'vless_partial' => l.vpnPartial,
  'vless_invalid' => l.vpnInvalid,
  'vless_api_failed' => l.vpnFailed,
  'panel_downloading' => l.componentsDownloading,
  'panel_extracting' => l.componentsExtracting,
  'panel_configuring' => l.componentsConfiguring,
  'panel_starting' => l.componentsStarting,
  'panel_checking' => l.componentsChecking,
  'panel_download' => l.componentsDownloaded,
  'panel_extract' => l.componentsExtracted,
  'panel_configure' => l.componentsConfigured,
  'panel_start' => l.componentsStarted,
  'panel_check' => l.componentsChecked,
  'panel_existing' => l.componentsExisting,
  'panel_prerequisites' || 'panel_disk_full' => l.componentsPrerequisites,
  'panel_port_busy' => l.componentsPortBusy,
  'panel_conflict' => l.runnerConflict,
  'panel_download_failed' => l.componentsDownloadFailed,
  'panel_checksum_failed' => l.componentsChecksumFailed,
  'panel_api_failed' => l.componentsApiFailed,
  'panel_partial' || 'panel_cancelled_partial' => l.componentsPartial,
  'sample' => l.runnerSample,
  'recovered' => l.runnerRecovered,
  'cancel_requested' => l.runnerCancelRequested,
  _ => runnerStateLabel(l, code),
};
