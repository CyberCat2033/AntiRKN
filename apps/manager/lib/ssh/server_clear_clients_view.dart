import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../vpn/vpn_controller.dart';
import 'ssh_controller.dart';

class ServerClearClientsView extends StatefulWidget {
  const ServerClearClientsView({
    required this.controller,
    this.vpn,
    super.key,
  });
  final SshController controller;
  final VpnController? vpn;

  @override
  State<ServerClearClientsView> createState() => _ServerClearClientsViewState();
}

class _ServerClearClientsViewState extends State<ServerClearClientsView> {
  bool clearing = false;
  String? lastResult;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, l = AppLocalizations.of(context);
    final disabled = c.busy || !c.runner.canRequestAction || clearing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('server-clear-clients'),
          onPressed: disabled
              ? null
              : () async {
                  final accepted = await confirmAppDanger(
                    context,
                    title: l.serverClearClients,
                    message: l.serverClearClientsConfirm,
                    confirmLabel: l.serverClearClients,
                    cancelLabel: l.runnerNotNow,
                    confirmKey: const ValueKey('server-clear-clients-confirm'),
                  );
                  if (!accepted || !mounted) return;
                  setState(() {
                    clearing = true;
                    lastResult = null;
                  });
                  var ok = false;
                  try {
                    ok = await c.runner.clearManagedClients();
                    if (ok && widget.vpn != null) {
                      final vpn = widget.vpn!;
                      final sid = c.serverId;
                      for (final target in [sid, 'awg/$sid', 'tt/$sid']) {
                        if (vpn.remote(target) != null) {
                          try {
                            await vpn.refreshServer(target);
                          } catch (_) {}
                        }
                      }
                      try {
                        await vpn.refreshProfiles();
                      } catch (_) {}
                    }
                  } catch (_) {
                    ok = false;
                  } finally {
                    if (mounted) {
                      setState(() {
                        clearing = false;
                        // The result is shown once, under the button (UI-51).
                        lastResult = ok ? 'done' : 'failed';
                      });
                    }
                  }
                },
          icon: clearing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.person_remove_outlined),
          label: Text(
            clearing ? l.serverClearClientsWaiting : l.serverClearClients,
          ),
        ),
        if (lastResult != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Semantics(
              liveRegion: true,
              child: Text(
              lastResult == 'done'
                  ? l.serverClearClientsDone
                  : l.serverClearClientsFailed,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: lastResult == 'done'
                        ? null
                        : Theme.of(context).colorScheme.error,
                  ),
              ),
            ),
          ),
      ],
    );
  }
}
