import '../vpn/vpn_strings.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'runner_controller.dart';
import 'component_installation_view.dart';
import 'software_overview.dart';

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
      final c = controller, l = AppLocalizations.of(context), job = c.selected;
      final active = job != null && !job.terminal;
      final failed =
          job != null &&
          const {
            'failed',
            'partially_applied',
            'needs_attention',
          }.contains(job.status);
      final event = job?.events.where((e) => e.code != 'succeeded').lastOrNull;
      final showJob =
          job != null &&
          (active ||
              failed ||
              ((job.kind.startsWith('apt_') ||
                      job.kind == 'protocol_remove' ||
                      job.kind == 'ssh_harden') &&
                  c.dismissedJobId != job.id));
      return AppAnimatedSize(
        motion: motion,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if ((c.busy || c.actionPending) && !active)
              const LinearProgressIndicator(),
            if (c.error case final issue?)
              Semantics(
                liveRegion: true,
                child: AppNotice(
                  message: runnerIssueLabel(l, issue),
                  error: true,
                ),
              ),
            if (c.responseCode != null && c.responseCode != 'ok')
              AppNotice(
                message: runnerCodeLabel(l, c.responseCode!),
                error: true,
              ),
            if (c.connectionLost || !c.connected && active)
              AppNotice(message: l.runnerConnectionLost),
            if (c.panelDiscovery?['failed'] == true)
              AppNotice(message: l.panelDiscoveryFailed, error: true),
            if (c.installed && !c.alive) Text(l.runnerNotRunning),
            if (c.error != null || c.installed && !c.alive)
              TextButton(
                key: const ValueKey('runner-refresh'),
                onPressed: !c.busy && !c.actionPending
                    ? () async {
                        if (await c.ensureReady()) {
                          await c.refresh(prepare: true);
                        }
                      }
                    : null,
                child: Text(l.runnerRetry),
              ),
            if (showJob) ...[
              const SizedBox(height: AppLayout.gap),
              Semantics(
                liveRegion: true,
                child: Text(
                  active
                      ? (job.kind == 'component_install'
                          ? componentStepProgressText(
                              l,
                              job.checkpoint,
                              job.count,
                            )
                          : (event != null
                              ? runnerEventLabel(l, event.code)
                              : runnerStateLabel(l, job.status)))
                      : (failed && event != null
                          ? runnerEventLabel(l, event.code)
                          : runnerStateLabel(l, job.status)),
                ),
              ),
              if (active)
                LinearProgressIndicator(value: job.checkpoint / job.count),
              if (failed && event != null)
                Text(runnerEventLabel(l, event.code)),
              if (job.events.any((e) => e.code == 'apt_reboot_required'))
                Text(l.aptReboot),
              if (active && job.kind.startsWith('apt_')) Text(l.aptRunningHelp),
              if (job.cancelRequested && active) Text(l.runnerCancelRequested),
              if (active && job.kind != 'server_reboot')
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: const ValueKey('runner-cancel'),
                    onPressed:
                        !c.busy && !c.actionPending && !job.cancelRequested
                        ? () async {
                            if (await c.ensureReady()) await c.cancelJob();
                          }
                        : null,
                    child: Text(l.runnerCancel),
                  ),
                ),
              if (job.terminal && !failed)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: c.dismissJob,
                    child: Text(l.networkClose),
                  ),
                ),
            ],
            if (c.observesOperation) Text(l.operationObserving),
            if (c.pending != null) ...[
              Text(c.observesOperation ? l.operationMissing : l.runnerPending),
              TextButton(
                key: const ValueKey('runner-retry'),
                onPressed: !c.busy && !c.actionPending
                    ? () async {
                        if (await c.ensureReady()) await c.retryPending();
                      }
                    : null,
                child: Text(
                  c.observesOperation ? l.operationTakeOver : l.runnerRetry,
                ),
              ),
            ],
            if (failed &&
                (job.kind == 'protocol_remove' ||
                    job.kind == 'inbound_update' ||
                    job.kind == 'inbound_remove' ||
                    job.kind == 'awg_external_edit' ||
                    job.kind == 'tt_external_edit' ||
                    job.kind == 'tt_certificate'))
              TextButton(
                onPressed: c.canRequestAction ? c.retryJob : null,
                child: Text(l.runnerRetry),
              ),
            SoftwareOverview(controller: c, motion: motion),
            if (c.componentPlan == null &&
                c.activeComponent == null &&
                (active || failed) &&
                job.kind == 'component_install')
              ComponentInstallationView(controller: c),
            AptMaintenanceView(controller: c),
          ],
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
  'vless_conflict' || 'awg_conflict' => l.vpnConflict,
  'vless_port_busy' || 'awg_port_busy' => l.vpnPortBusy,
  'vless_invalid' || 'awg_invalid' => l.vpnInvalid,
  'vless_api_failed' || 'awg_failed' => l.vpnFailed,
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
  'apt_failed' => l.aptFailed,
  'apt_conflict' => l.aptConflict,
  'apt_interrupted' => l.aptInterrupted,
  'apt_prerequisites' => l.runnerPrerequisites,
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
