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
    if (context.mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
  }

  if (vpn.busy || vpn.hasRunning || runner.busy || session.busy) {
    notice(l.uiRemoveProtocolBusy);
    return false;
  }
  if (!runner.connected) {
    notice(l.uiRemoveProtocolConnect);
    if (session.saved && session.editing) await session.connect();
    return false; // Trust/privilege prompts are handled by the normal SSH page.
  }
  await runner.refresh(prepare: true);
  if (!context.mounted) return false;
  if (!runner.canStart) {
    notice(
      runner.error == null
          ? l.uiRemoveProtocolBusy
          : runnerIssueLabel(l, runner.error!),
    );
    return false;
  }
  final plan = await runner.prepareProtocolRemoval(protocol);
  if (!context.mounted) return false;
  if (plan == null) {
    notice(runnerCodeLabel(l, runner.responseCode ?? 'protocol_remove_failed'));
    return false;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AppFormDialog(
      title: Text(l.uiRemoveProtocol),
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
          for (final label in [
            ...?plan['services'] as List?,
            ...?plan['containers'] as List?,
          ])
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.remove_circle_outline),
              title: Text('$label'),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.sshCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l.uiRemoveProtocol),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  AppHaptics.confirm();
  final submitted = await runner.removeProtocol(
    plan,
    () => vpn.retireProtocol(session.serverId, protocol),
  );
  notice(submitted ? l.uiRemoveProtocolStarted : l.uiRemoveProtocolFailed);
  return submitted;
}
