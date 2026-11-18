import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'vpn_controller.dart';
import 'vpn_strings.dart';

/// Resources the app keeps for [target] that the server does not have (never
/// sent, or the server was reinstalled). Without this they would only read
/// "not confirmed" forever; the button sends the app's configuration.
class MissingOnServerNotice extends StatelessWidget {
  const MissingOnServerNotice({
    required this.controller,
    required this.target,
    this.authorize,
    super.key,
  });
  final VpnController controller;
  final String target;

  /// Runs before sending, e.g. the 3x-ui panel login for VLESS.
  final Future<bool> Function()? authorize;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final count = controller.missingOnServer(target);
      if (count == 0) return const SizedBox.shrink();
      final l = AppLocalizations.of(context);
      // The app sends missing resources by itself once per change; this shows
      // why that attempt did not land and lets the person retry.
      final issue =
          controller.workspace.servers[target]?['error'] as String? ??
          controller.sendIssue(target);
      return AppNotice(
        key: ValueKey('vpn-missing-$target'),
        icon: Icons.cloud_upload_outlined,
        message: [
          l.vpnMissingNotice(count),
          if (issue != null) vpnMessage(l, issue),
        ].join('\n'),
        action: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: FilledButton.tonal(
            key: ValueKey('vpn-send-$target'),
            onPressed: controller.busy
                ? null
                : () async {
                    if (authorize != null && !await authorize!()) return;
                    await controller.prepareAndApply(serverIds: {target});
                  },
            child: Text(l.vpnSendToServer),
          ),
        ),
      );
    },
  );
}
