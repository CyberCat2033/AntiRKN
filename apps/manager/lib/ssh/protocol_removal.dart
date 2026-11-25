import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../runner/runner_panel.dart';
import '../vpn/vpn_controller.dart';
import 'ssh_controller.dart';

Future<bool> removeServerProtocol(
  BuildContext context,
  SshController session,
  VpnController vpn,
  String protocol,
  String name,
) async {
  final l = AppLocalizations.of(context), runner = session.runner;
  void notice(String message) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  final confirmed = await confirmAppDanger(
    context,
    title: l.uiRemoveProtocol,
    confirmLabel: l.uiRemoveProtocol,
    cancelLabel: l.sshCancel,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$name · ${session.displayName}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Text(l.uiRemoveProtocolHelp),
        if (protocol == 'vless') ...[
          const SizedBox(height: 12),
          Text(l.uiRemoveVlessHelp),
        ],
      ],
    ),
  );
  if (!confirmed || !context.mounted) return false;
  if (!vpn.canMutate || vpn.hasRunning) {
    notice(l.uiRemoveProtocolBusy);
    return false;
  }
  if (!await runner.ensureReady() || !context.mounted) return false;
  if (!runner.canStart) {
    notice(l.uiRemoveProtocolBusy);
    return false;
  }
  final plan = await runner.prepareProtocolRemoval(protocol);
  if (plan == null) {
    notice(runnerCodeLabel(l, runner.responseCode ?? 'protocol_remove_failed'));
    return false;
  }
  final submitted = await runner.removeProtocol(
    plan,
    () => vpn.retireProtocol(session.serverId, protocol),
  );
  // Haptic confirms an accepted removal, not the tap before the checks.
  if (submitted) AppHaptics.deleted();
  notice(submitted ? l.uiRemoveProtocolStarted : l.uiRemoveProtocolFailed);
  return submitted;
}
