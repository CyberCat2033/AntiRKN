import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../publication/publication_panel.dart';
import 'vpn_controller.dart';
import 'vpn_strings.dart';

class ClientDeletionPanel extends StatelessWidget {
  const ClientDeletionPanel({
    required this.controller,
    required this.serverName,
    super.key,
  });
  final VpnController controller;
  final String Function(String) serverName;

  Future<void> force(BuildContext context, VpnUser user) async {
    final l = AppLocalizations.of(context);
    final servers = (user.deletion!['targets'] as Map).entries
        .where((e) => !vpnRevocationSettled(e.value))
        .map((e) => serverName(vpnServerId(e.key as String)))
        .toSet()
        .join(', ');
    final accepted = await confirmAppDanger(
      context,
      title: l.uiForceDeleteClient,
      message: l.uiForceDeleteWarning(user.name, servers),
      confirmLabel: l.uiForceDeleteClient,
      cancelLabel: l.sshCancel,
    );
    if (!accepted) return;
    await controller.forceDeleteClient(user.id);
    // Haptic confirms the accepted deletion, not the tap before checks.
    if (controller.error == null) AppHaptics.deleted();
  }

  Widget details(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context), c = controller;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final user in c.visibleDeletions) ...[
            AppSectionHeading(title: user.name),
            for (final entry
                in (user.deletion!['targets'] as Map).entries.where(
                  (e) => !vpnRevocationSettled(e.value),
                ))
              ListTile(
                title: Text(
                  '${serverName(vpnServerId(entry.key as String))} · ${isAwgTarget(entry.key as String)
                      ? 'AmneziaWG'
                      : isTtTarget(entry.key as String)
                      ? 'TrustTunnel'
                      : 'VLESS'}',
                ),
                subtitle: Text(
                  entry.value['error'] == null
                      ? l.vpnRevocationPending
                      : vpnMessage(l, entry.value['error'] as String),
                ),
                trailing: AppBadge(
                  label: '${entry.value['connectionAttempts'] ?? 0}/3',
                ),
              ),
            if (user.deletion!['file']?['error'] case final String issue)
              AppNotice(message: publicationMessage(l, issue), error: true),
            // Force deletion is offered once, by the panel's notice (UI-51).
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: !c.canMutate
                      ? null
                      : () => c.retryDeletion(user.id),
                  child: Text(l.runnerRetry),
                ),
              ],
            ),
          ],
          if (c.visibleDeletions.isEmpty)
            AppNotice(
              message: l.vpnAccessRevoked,
              icon: Icons.check_circle_outline,
            ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller,
          l = AppLocalizations.of(context),
          pending = controller.visibleDeletions.toList();
      return AppAnimatedSize(
        motion: MotionPreference.system,
        child: pending.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card.filled(
                      child: ListTile(
                        leading: const AppIconTile(
                          icon: Icons.person_remove_outlined,
                        ),
                        title: Text(l.uiDeletingClients(pending.length)),
                        subtitle: Text(l.uiDeletingClientsHelp),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showAppDetails(
                          context,
                          title: l.uiDeletionProgress,
                          children: [details(context)],
                        ),
                      ),
                    ),
                    for (final user in pending.where(c.canForceDelete))
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: AppNotice(
                          message: l.uiForceDeleteOffer(user.name),
                          action: TextButton(
                            key: ValueKey('client-force-delete-${user.id}'),
                            onPressed: !c.canMutate
                                ? null
                                : () => force(context, user),
                            child: Text(l.uiForceDeleteClient),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      );
    },
  );
}
