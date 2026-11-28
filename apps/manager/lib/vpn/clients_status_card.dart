import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../publication/publication_controller.dart';
import '../publication/publication_panel.dart';
import 'vpn_controller.dart';

/// Status above the client list, shown only when there is something to
/// say. Nowhere to connect is a standing state of the setup and is said on
/// its own; of the passing states only the most pressing is shown: Google
/// sign-in, a check in progress, profiles that failed to publish.
class ClientsStatusCard extends StatelessWidget {
  const ClientsStatusCard({
    required this.vpn,
    required this.hasAccess,
    required this.syncing,
    required this.motion,
    required this.onShowFailed,
    this.publications,
    super.key,
  });
  final VpnController vpn;
  final PublicationController? publications;

  /// Whether any server offers a protocol for clients.
  final bool hasAccess;

  /// This page's own check of the servers is running.
  final bool syncing;
  final MotionPreference motion;

  /// Narrows the list to the clients with errors.
  final VoidCallback onShowFailed;

  @override
  Widget build(BuildContext context) {
    final pub = publications;
    if (pub == null) return _status(context, null);
    return ListenableBuilder(
      listenable: Listenable.merge([pub, pub.changes]),
      builder: (context, _) => _status(context, pub),
    );
  }

  Widget _status(BuildContext context, PublicationController? pub) {
    final l = AppLocalizations.of(context);
    final configured = pub?.settings != null;
    final failed = configured ? pub!.publicationErrorUserIds : const <String>[];
    final Widget? banner;
    if (configured && pub!.needsAuthorization) {
      banner = AppStatusBanner(
        key: const ValueKey('clients-sign-in'),
        tone: AppStatusTone.attention,
        icon: Icons.account_circle_outlined,
        title: l.googleReauthorize,
        message: l.clientsSignInMessage,
        actions: [
          TextButton(
            key: const ValueKey('clients-sign-in-action'),
            onPressed: pub.editing ? null : pub.authorize,
            child: Text(l.googleSignIn),
          ),
        ],
      );
    } else if (syncing || pub?.hasActiveSync == true) {
      final total = pub?.activeSyncTotal ?? 0;
      final done = pub?.activeSyncCompleted ?? 0;
      banner = AppStatusBanner(
        key: const ValueKey('clients-sync-progress'),
        title: l.clientsSyncTitle,
        message: total > 0 ? l.clientsSyncProgress(done, total) : null,
        progress: total > 0 ? (done / total).clamp(0.0, 1.0) : null,
      );
    } else if (failed.isNotEmpty) {
      final names = [
        for (final id in failed) ?vpn.workspace.userById(id)?.name,
      ].join(', ');
      final issues = {
        for (final id in failed) pub!.queues[id]?['issue'] as String?,
      };
      banner = AppStatusBanner(
        key: const ValueKey('publication-failures'),
        tone: AppStatusTone.error,
        title: l.publicationClientsFailed(failed.length),
        // One shared reason is said here; different ones are on the rows.
        message: issues.length == 1
            ? '$names · ${publicationMessage(l, issues.single)}'
            : names,
        actions: [
          if (!issues.every(publicationIssueShared))
            TextButton(
              key: const ValueKey('publication-failures-show'),
              onPressed: onShowFailed,
              child: Text(l.clientsShowFailed),
            ),
          TextButton(
            key: const ValueKey('publication-failures-retry'),
            onPressed: pub!.busy || pub.hasActiveSync
                ? null
                : () {
                    for (final id in failed) {
                      pub.request(force: true, targetUserId: id);
                    }
                  },
            child: Text(l.publicationRetry),
          ),
        ],
      );
    } else {
      banner = null;
    }
    Widget spaced(Widget child) =>
        Padding(padding: const EdgeInsets.only(bottom: 12), child: child);
    return AppAnimatedSize(
      motion: motion,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!hasAccess)
            spaced(
              AppStatusBanner(
                key: const ValueKey('vpn-clients-no-access'),
                tone: AppStatusTone.attention,
                icon: Icons.dns_outlined,
                title: l.uiClientsNoAccessTitle,
                message: l.uiClientsNoAccessHelp,
              ),
            ),
          if (banner != null) spaced(banner),
        ],
      ),
    );
  }
}
