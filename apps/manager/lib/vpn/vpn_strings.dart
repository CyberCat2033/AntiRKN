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
  'vpn_user_invalid' || 'vless_invalid' => l.vpnInvalid,
  'vpn_connection' => l.vpnConnection,
  'vpn_identity' => l.vpnIdentity,
  'vpn_storage' => l.vpnStorage,
  'vpn_storage_conflict' => l.vpnStorageConflict,
  'vpn_conflict' || 'vless_conflict' => l.vpnConflict,
  'vpn_runner' || 'vpn_panel_required' => l.vpnPanelRequired,
  'vless_port_busy' => l.vpnPortBusy,
  'vpn_partially_applied' || 'vless_partial' => l.vpnPartial,
  'vpn_failed' ||
  'vpn_busy' ||
  'vpn_missing' ||
  'vless_api_failed' ||
  'vpn_cancelled' => l.vpnFailed,
  'vless_preparing' => l.vpnPrepareStep,
  'vless_applying' => l.vpnApplying,
  'vless_checking' => l.vpnChecking,
  _ => l.diagnostic(code),
};
