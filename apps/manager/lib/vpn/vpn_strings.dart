import '../l10n/app_localizations.dart';
import '../app_strings.dart';

String vpnMessage(AppLocalizations l, String code) => switch (code) {
  'succeeded' => l.runnerSucceeded,
  'planned' => l.runnerPlanned,
  'running' => l.runnerRunning,
  'cancelled' => l.runnerCancelled,
  'recovered' => l.runnerRecovered,
  'cancel_requested' => l.runnerCancelRequested,
  'vpn_pending' => l.vpnPending,
  'vpn_duplicate' => l.vpnDuplicate,
  'awg_prerequisites' => l.awgPrerequisites,
  'awg_pool_conflict' => l.awgPoolConflict,
  'awg_pool_full' => l.awgPoolFull,
  'awg_port_mapping' => l.awgDockerPortHelp,
  'awg_invalid' || 'vpn_user_invalid' || 'vless_invalid' => l.vpnInvalid,
  'vpn_connection' => l.vpnConnection,
  'vpn_identity' => l.vpnIdentity,
  'vpn_storage' => l.vpnStorage,
  'vpn_storage_conflict' => l.vpnStorageConflict,
  'vpn_conflict' || 'vless_conflict' || 'awg_conflict' => l.vpnConflict,
  'vpn_runner' || 'vpn_panel_required' => l.vpnPanelRequired,
  'vless_port_busy' || 'awg_port_busy' => l.vpnPortBusy,
  'vpn_partially_applied' || 'vless_partial' => l.vpnPartial,
  'vpn_failed' ||
  'vpn_busy' ||
  'vpn_missing' ||
  'awg_failed' ||
  'vless_api_failed' ||
  'vpn_cancelled' => l.vpnFailed,
  'vless_preparing' || 'awg_preparing' => l.vpnPrepareStep,
  'vless_applying' || 'awg_applying' => l.vpnApplying,
  'vless_checking' || 'awg_checking' => l.vpnChecking,
  _ => l.diagnostic(code),
};
