import 'egress_strings.dart';
import 'relay_strings.dart';
import '../vpn/vpn_strings.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'runner_controller.dart';
import 'component_installation_view.dart';
import 'software_overview.dart';
import '../ssh/server_activity.dart' show runnerJobTitle;

class RunnerPanel extends StatelessWidget {
  const RunnerPanel({
    required this.controller,
    required this.motion,
    this.coreUpgrade,
    this.reboot,
    super.key,
  });
  final RunnerController controller;
  final MotionPreference motion;

  /// The reboot action (with its reconnect tracking), offered on the
  /// Ubuntu card after an upgrade that left the server needing a reboot.
  final Widget? reboot;

  /// The checked Xray core transaction, shown under the 3x-ui / Xray row.
  final Widget? coreUpgrade;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller, l = AppLocalizations.of(context), job = c.selected;
      final active = job != null && !job.terminal;
      // A closed failure stays in the activity list, not on this page.
      final failed = job != null && identical(c.failedJob, job);
      final event = job?.events.where((e) => e.code != 'succeeded').lastOrNull;
      // ComponentInstallationView owns an active install's step, progress
      // and cancel (UI-39).
      final installationOwned = active && job.kind == 'component_install';
      final showJob =
          job != null &&
          !installationOwned &&
          // Ubuntu updates and the restart live on their card.
          !aptCardJobs.contains(job.kind) &&
          (active ||
              failed ||
              ((job.kind.startsWith('apt_') ||
                      job.kind == 'protocol_remove' ||
                      job.kind == 'ssh_harden') &&
                  !c.isDismissed(job)));
      // A failed job's event goes under its state, once (UI-43).
      final detail =
          failed &&
              event != null &&
              event.code != 'failed' &&
              runnerEventLabel(l, event.code) != runnerStateLabel(l, job.status)
          ? runnerEventLabel(l, event.code)
          : null;
      final resumable =
          failed &&
          const {
            'protocol_remove',
            'inbound_update',
            'inbound_remove',
            'awg_external_edit',
            'tt_external_edit',
            'tt_certificate',
          }.contains(job.kind);
      final notes = [?detail];
      final troubled =
          c.error != null || c.installed && !c.alive || c.connectionLost;
      // One reset action per panel: either under the error row or the job.
      final resetAfterError =
          troubled && (active || c.hasUnfinishedJob || c.pending != null);
      // A running job has its own Stop; the reset is only an escape hatch
      // for a stop that the server does not honour.
      final resetAfterJob =
          !resetAfterError &&
          active &&
          job.kind != 'server_reboot' &&
          job.cancelRequested;
      return AppAnimatedSize(
        motion: motion,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (c.error case final issue?)
              Semantics(
                liveRegion: true,
                child: AppNotice(
                  message: runnerIssueLabel(l, issue),
                  error: true,
                ),
              ),
            if (c.error == RunnerIssue.incompatible)
              if (c.installation?.release case final String installed)
                if (c.bundledRelease case final String bundled)
                  SelectableText(
                    l.runnerVersionDetails(
                      _shortRelease(installed),
                      _shortRelease(bundled),
                    ),
                  ),
            if (c.responseCode != null && c.responseCode != 'ok') ...[
              AppNotice(
                message: runnerCodeLabel(l, c.responseCode!),
                error: true,
              ),
              // A code without its own text: the code itself is the only
              // lead for support, so it is shown as a technical detail.
              if (runnerCodeLabel(l, c.responseCode!) ==
                  l.runnerInvalidResponse)
                SelectableText(
                  key: const ValueKey('runner-response-code'),
                  l.technicalCode(c.responseCode!),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
            if (c.connectionLost || !c.connected && active)
              AppNotice(message: l.runnerConnectionLost),
            if (c.panelDiscovery?['failed'] == true)
              AppNotice(message: l.panelDiscoveryFailed, error: true),
            if (c.installed && !c.alive) Text(l.runnerNotRunning),
            if (troubled)
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    key: const ValueKey('runner-refresh'),
                    onPressed: !c.busy && !c.actionPending
                        ? () async {
                            await c.refresh(prepare: true);
                          }
                        : null,
                    child: Text(l.runnerReconnect),
                  ),
                ],
              ),
            if (resetAfterError)
              RunnerResetQueueButton(
                controller: c,
                buttonKey: const ValueKey('runner-reset-queue-error'),
              ),
            if (showJob && job.terminal)
              Padding(
                padding: const EdgeInsets.only(top: AppLayout.gap),
                child: AppNotice(
                  key: const ValueKey('runner-job-result'),
                  title: notes.isEmpty ? null : runnerStateLabel(l, job.status),
                  message: notes.isEmpty
                      ? runnerStateLabel(l, job.status)
                      : notes.join('\n'),
                  error: failed,
                  icon: job.status == 'succeeded'
                      ? Icons.check_circle_outline
                      : Icons.info_outline,
                  liveRegion: true,
                  // Retry resumes the same job; after Close it is gone from
                  // this page, so both choices stand side by side.
                  action: Wrap(
                    spacing: 8,
                    children: [
                      if (resumable)
                        TextButton(
                          key: const ValueKey('runner-retry-job'),
                          onPressed: c.canRequestAction ? c.retryJob : null,
                          child: Text(l.runnerRetry),
                        ),
                      TextButton(
                        key: const ValueKey('runner-job-close'),
                        onPressed: c.busy ? null : c.dismissJob,
                        child: Text(l.networkClose),
                      ),
                    ],
                  ),
                ),
              ),
            if (showJob && active)
              // One card like a component install: what runs, its step in
              // a progress ring and the actions (no bare full-width bar).
              AppProgressCard(
                key: const ValueKey('runner-job-progress'),
                margin: const EdgeInsets.only(top: AppLayout.gap, bottom: 12),
                icon: job.kind.startsWith('apt_')
                    ? Icons.system_update_alt
                    : Icons.sync,
                title: runnerJobTitle(l, job.kind),
                status: event != null
                    ? runnerEventLabel(l, event.code)
                    : runnerStateLabel(l, job.status),
                value: job.count > 0 && job.checkpoint > 0
                    ? job.checkpoint / job.count
                    : null,
                notes: [if (job.cancelRequested) l.runnerCancelRequested],
                actions: [
                  if (job.kind != 'server_reboot')
                    TextButton(
                      key: const ValueKey('runner-cancel'),
                      onPressed:
                          !c.busy && !c.actionPending && !job.cancelRequested
                          ? () async {
                              await c.cancelJob();
                            }
                          : null,
                      child: Text(l.runnerCancel),
                    ),
                  if (resetAfterJob)
                    RunnerResetQueueButton(
                      controller: c,
                      buttonKey: const ValueKey('runner-reset-queue'),
                      inline: true,
                    ),
                ],
              ),
            // A job shown elsewhere (a component install) keeps the reset.
            if (resetAfterJob && !showJob)
              RunnerResetQueueButton(
                controller: c,
                buttonKey: const ValueKey('runner-reset-queue'),
              ),
            if (c.pending != null && c.waitingForProbe)
              AppProgressCard(
                key: const ValueKey('runner-waiting-probe'),
                title: runnerJobTitle(
                  l,
                  c.pending!.json['kind'] as String? ?? '',
                ),
                status: l.runnerWaitingProbe,
              )
            else if (c.pending != null) ...[
              Text(c.observesOperation ? l.operationMissing : l.runnerPending),
              TextButton(
                key: const ValueKey('runner-retry'),
                onPressed: !c.busy && !c.actionPending
                    ? () async {
                        if (await c.ensureReady()) await c.retryPending();
                      }
                    : null,
                child: Text(
                  c.observesOperation ? l.operationTakeOver : l.runnerResend,
                ),
              ),
            ],
            SoftwareOverview(
              controller: c,
              motion: motion,
              coreUpgrade: coreUpgrade,
            ),
            if (!softwareComponentKeys.any(
                  (k) => hostsComponentInstallation(c, k),
                ) &&
                (active || failed) &&
                job.kind == 'component_install')
              ComponentInstallationView(controller: c),
            AptMaintenanceView(controller: c, reboot: reboot),
          ],
        ),
      );
    },
  );
}

String _shortRelease(String release) =>
    release.length > 16 ? release.substring(0, 16) : release;

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
  final String v when v.startsWith('egress_') => egressIssue(l, v),
  final String v when v.startsWith('relay_') => relayIssue(l, v),
  'protocol_remove_conflict' => l.uiRemoveProtocolConflict,
  'protocol_remove_unsupported' => l.uiRemoveProtocolUnsupported,
  'protocol_remove_failed' => l.uiRemoveProtocolFailed,
  'ssh_harden_conflict' => l.sshHardenConflict,
  'ssh_harden_invalid' => l.sshHardenInvalid,
  'ssh_harden_port_busy' => l.sshHardenPortBusy,
  'ssh_harden_failed' => l.sshHardenFailed,
  'sync_conflict' => l.syncEffectsBlocked,
  final String v when v.startsWith('tt_') => vpnMessage(l, v),
  'panel_auth_failed' => l.panelAuthFailed,
  'panel_unreachable' => l.panelUnreachable,
  'panel_connect_unsupported' => l.panelConnectUnsupported,
  'panel_login_limited' => l.panelLoginLimited,
  'panel_api_failed' => l.componentsApiFailed,
  'panel_update_incompatible' || 'incompatible' => l.runnerIncompatible,
  'panel_conflict' || 'conflict' => l.runnerConflict,
  'panel_prerequisites' || 'prerequisites' => l.runnerPrerequisites,
  'vless_conflict' || 'awg_conflict' => l.vpnConflict,
  'vless_port_busy' || 'awg_port_busy' => l.vpnPortBusy,
  'vless_invalid' || 'awg_invalid' => l.vpnInvalid,
  'vless_api_failed' || 'awg_failed' => l.vpnFailed,
  final String v when v.startsWith('apt_') =>
    aptIssueLabel(l, v) ?? l.aptFailed,
  // A response code is never progress: unknown upgrade codes are failures.
  final String v when v.startsWith('upgrade_') =>
    upgradeOutcomeLabel(l, v) ?? l.runnerUpgradeFailedGeneric,
  'failed' => l.runnerFailed,
  'busy' => l.runnerBusy,
  'probe_busy' => l.runnerProbeBusy,
  'missing' => l.runnerMissing,
  'capacity' => l.runnerCapacity,
  _ => l.runnerInvalidResponse,
};

/// APT failures, both as `apt_plan` response codes and as job events.
/// Matched by string: `apt_dpkg_interrupted` comes with newer runners.
String? aptIssueLabel(AppLocalizations l, String code) => switch (code) {
  'apt_failed' => l.aptFailed,
  'apt_conflict' => l.aptConflict,
  'apt_interrupted' => l.aptInterrupted,
  'apt_prerequisites' => l.runnerPrerequisites,
  'apt_disk_full' => l.aptDiskFull,
  'apt_memory_low' => l.aptMemoryLow,
  'apt_lock_busy' => l.aptLockBusy,
  'apt_dpkg_interrupted' => l.aptDpkgInterrupted,
  _ => null,
};

/// Terminal outcomes and failures of a component upgrade; null for
/// progress and unknown codes.
String? upgradeOutcomeLabel(AppLocalizations l, String code) => switch (code) {
  'upgrade_rolled_back' => l.runnerUpgradeRolledBack,
  'upgrade_rollback_failed' => l.runnerUpgradeRollbackFailed,
  'upgrade_syntax_failed' => l.runnerUpgradeSyntaxFailed,
  'upgrade_healthcheck_failed' => l.runnerUpgradeHealthcheckFailed,
  'upgrade_connectivity_failed' => l.runnerUpgradeConnectivityFailed,
  'upgrade_checks_required' => l.runnerUpgradeChecksRequired,
  'upgrade_checks_coverage' => l.runnerUpgradeChecksCoverage,
  'upgrade_checks_changed' => l.runnerUpgradeChecksChanged,
  'upgrade_checks_timeout' => l.runnerUpgradeChecksTimeout,
  'upgrade_checks_failed' => l.runnerUpgradeChecksFailed,
  'upgrade_checks_panel_api' => l.runnerUpgradeChecksPanelApi,
  'upgrade_download_missing' => l.runnerUpgradeDownloadMissing,
  'upgrade_download_failed' => l.runnerUpgradeDownloadFailed,
  'upgrade_checksum_failed' => l.runnerUpgradeChecksumFailed,
  'upgrade_conflict' => l.runnerUpgradeConflict,
  'upgrade_binary_not_found' => l.runnerUpgradeBinaryNotFound,
  'upgrade_architecture_mismatch' => l.runnerUpgradeArchitectureMismatch,
  'upgrade_disk_full' => l.runnerUpgradeDiskFull,
  'upgrade_memory_low' => l.runnerUpgradeMemoryLow,
  'upgrade_not_installed' => l.runnerUpgradeNotInstalled,
  'upgrade_invalid_component' => l.runnerUpgradeInvalidComponent,
  'upgrade_failed' => l.runnerUpgradeFailedGeneric,
  _ => null,
};

/// Единый резолвер для кодов обновления (используется и в журнале событий, и в статусе раннера).
String? tryResolveUpgradeLabel(AppLocalizations l, String code) {
  if (upgradeOutcomeLabel(l, code) case final label?) return label;
  return switch (code) {
    // Progress states
    'upgrade_preparing' => l.runnerUpgradePreparing,
    'upgrade_downloading' => l.runnerUpgradeDownloading,
    'upgrade_backing_up' => l.runnerUpgradeBackingUp,
    'upgrade_syntax_checking' => l.runnerUpgradeSyntaxChecking,
    'upgrade_switching' => l.runnerUpgradeSwitching,
    'upgrade_verifying' => l.runnerUpgradeVerifying,
    'upgrade_rolling_back' => l.runnerUpgradeRollingBack,
    'upgrade_completed' || 'upgrade_checked' => l.runnerUpgradeCompleted,
    'upgrade_awaiting_confirmation' => l.runnerUpgradeAwaitingConfirmation,
    'upgrade_awaiting_checks' => l.runnerUpgradeAwaitingChecks,
    'upgrade_confirmed' => l.runnerUpgradeConfirmed,
    // Safe fallback for future upgrade_* codes (never masks progress as failure)
    final String v
        when v.startsWith('upgrade_') &&
            (v.endsWith('_failed') || v.endsWith('_missing')) =>
      l.runnerUpgradeFailedGeneric,
    final String v when v.startsWith('upgrade_') =>
      l.runnerUpgradeInProgressGeneric,
    _ => null,
  };
}

String runnerStateLabel(AppLocalizations l, String state) =>
    tryResolveUpgradeLabel(l, state) ??
    switch (state) {
      'planned' => l.runnerPlanned,
      'running' => l.runnerRunning,
      'succeeded' => l.runnerSucceeded,
      'cancelled' => l.runnerCancelled,
      'failed' => l.runnerFailed,
      'partially_applied' => l.runnerPartial,
      _ => l.runnerAttention,
    };

String runnerEventLabel(AppLocalizations l, String code) =>
    tryResolveUpgradeLabel(l, code) ??
    switch (code) {
      'egress_preparing' => l.egressPreparing,
      'egress_applying' => l.egressApplying,
      'egress_checking' => l.egressChecking,
      'relay_preparing' => l.relayPreparing,
      'relay_applying' => l.relayApplying,
      'relay_checking' => l.egressChecking,
      final String v when v.startsWith('egress_') => egressIssue(l, v),
      final String v when v.startsWith('relay_') => relayIssue(l, v),
      'protocol_remove_conflict' => l.uiRemoveProtocolConflict,
      'protocol_remove_unsupported' => l.uiRemoveProtocolUnsupported,
      'protocol_remove_failed' => l.uiRemoveProtocolFailed,
      'ssh_harden_conflict' => l.sshHardenConflict,
      'ssh_harden_invalid' => l.sshHardenInvalid,
      'ssh_harden_port_busy' => l.sshHardenPortBusy,
      'ssh_harden_failed' => l.sshHardenFailed,
      'ssh_harden_preparing' => l.sshHardenPreparing,
      'ssh_harden_user_created' => l.sshHardenUserCreated,
      'ssh_harden_sudoers_configured' => l.sshHardenSudoersConfigured,
      'ssh_harden_ports_configured' => l.sshHardenPortsConfigured,
      'ssh_harden_firewall_configured' => l.sshHardenFirewallConfigured,
      'ssh_harden_testing' => l.sshHardenTesting,
      'ssh_harden_confirmed' => l.sshHardenConfirmed,
      'ssh_harden_aborted' => l.sshHardenAborted,
      final String v when v.startsWith('tt_') => vpnMessage(l, v),
      'apt_updating' => l.aptUpdating,
      'apt_upgrading' => l.aptUpgrading,
      'apt_checked' => l.runnerSucceeded,
      'apt_reboot_required' => l.aptReboot,
      final String v when aptIssueLabel(l, v) != null => aptIssueLabel(l, v)!,
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
      'component_archive_invalid' => l.componentsArchiveInvalid,
      'component_build_failed' => l.protocolBuildFailed,
      'component_check_failed' => l.protocolCheckFailed,
      'component_prerequisites' => l.protocolPrerequisites,
      'component_partial' => l.componentsPartial,
      'vless_preparing' || 'awg_preparing' => l.vpnPrepareStep,
      'vless_applying' || 'awg_applying' => l.vpnApplying,
      'vless_checking' || 'awg_checking' => l.vpnChecking,
      'vless_conflict' || 'awg_conflict' => l.vpnConflict,
      'vless_port_busy' || 'awg_port_busy' => l.vpnPortBusy,
      'vless_partial' => l.vpnPartial,
      'vless_invalid' || 'awg_invalid' => l.vpnInvalid,
      'vless_api_failed' || 'awg_failed' => l.vpnFailed,
      'server_reboot_waiting' => l.serverRebootWaiting,
      'server_reboot_done' => l.serverRebootDone,
      'server_reboot_failed' => l.serverRebootFailed,
      'panel_update_preparing' => l.panelUpdatePreparing,
      'panel_update_backup' => l.panelUpdateBackup,
      'panel_update_switching' => l.panelUpdateSwitching,
      'panel_update_incompatible' => l.panelUpdateCompatibility,
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

/// Cancels every server job and resets the runner state. Destructive and
/// rare, so it stands apart from Cancel/Retry, uses the error colour and
/// asks first.
class RunnerResetQueueButton extends StatelessWidget {
  const RunnerResetQueueButton({
    required this.controller,
    this.buttonKey,
    this.inline = false,
    super.key,
  });
  final RunnerController controller;
  final Key? buttonKey;

  /// Only the button, for a row of job actions.
  final bool inline;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), c = controller;
    final button = TextButton.icon(
      key: buttonKey,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
      ),
      onPressed: !c.busy && !c.actionPending
          ? () async {
              final confirmed = await confirmAppDanger(
                context,
                title: l.runnerResetQueueTitle,
                message: l.runnerResetQueueHelp,
                confirmLabel: l.runnerResetQueue,
                cancelLabel: l.sshCancel,
                confirmKey: const ValueKey('runner-reset-queue-confirm'),
              );
              if (confirmed && !c.busy && !c.actionPending) {
                await c.resetJobQueue();
              }
            }
          : null,
      icon: const Icon(Icons.restart_alt),
      label: Text(l.runnerResetQueue),
    );
    if (inline) return button;
    return Padding(
      padding: const EdgeInsets.only(top: AppLayout.gap / 2),
      child: Align(alignment: AlignmentDirectional.centerStart, child: button),
    );
  }
}
