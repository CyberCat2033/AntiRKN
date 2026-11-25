import 'l10n/app_localizations.dart';
import 'runner/runner_controller.dart';
import 'ssh/ssh_controller.dart';
import 'vpn/vpn_controller.dart';

/// Why a control that depends on these resources is unavailable now, or
/// null when none of them holds it (the control may still be disabled for
/// its own reason, e.g. invalid input). One rule for every tooltip of a
/// disabled action (UI-63).
String? busyReason(
  AppLocalizations l, {
  VpnController? vpn,
  RunnerController? runner,
  SshController? ssh,
  bool syncing = false,
  bool needsConnection = false,
}) {
  if (syncing) return l.uiBusySync;
  if (vpn != null && !vpn.canMutate) return l.uiBusyChanges;
  if (runner != null && (runner.busy || runner.actionPending)) {
    return l.uiBusyServerOperation;
  }
  if (ssh != null) {
    if (ssh.busy) return l.uiBusyConnecting;
    if (ssh.vaultBusy) return l.uiBusyChanges;
    if (needsConnection && ssh.stage != SshStage.connected) {
      return l.uiNeedsConnection;
    }
  }
  return null;
}
