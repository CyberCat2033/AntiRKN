import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../publication/publication_panel.dart';
import 'vpn_controller.dart';
import 'vpn_strings.dart';

/// One summary of waiting server work above the client list (variant B).
/// Work that runs by itself is a quiet progress line without buttons; only
/// what needs the person gets an action. Details open in a sheet.
class ServerOperationsBanner extends StatelessWidget {
  const ServerOperationsBanner({
    required this.controller,
    required this.serverName,
    this.onOpenServer,
    super.key,
  });
  final VpnController controller;
  final String Function(String) serverName;

  /// Shows the server page where the person connects, signs in or updates.
  final void Function(String serverId)? onOpenServer;

  static String protocolLabel(String target) => isAwgTarget(target)
      ? 'AmneziaWG'
      : isTtTarget(target)
      ? 'TrustTunnel'
      : 'VLESS';

  Future<void> _force(BuildContext context, VpnUser user) async {
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

  Future<void> _continueHere(VpnServerAttention item) async {
    final c = controller;
    for (final user in item.removing) {
      await c.retryDeletion(user.id);
    }
    for (final target in item.targets) {
      if (c.needsRestoreReview(target.target)) {
        await c.reviewRestored(target.target);
      }
    }
  }

  /// The primary button for [item], or null when only the details help.
  Widget? _action(BuildContext context, VpnServerAttention item) {
    final l = AppLocalizations.of(context), c = controller;
    if (!item.needsUser) return null;
    switch (item.action) {
      case VpnAttentionAction.openServer:
        final open = onOpenServer;
        if (open == null) return null;
        return FilledButton.tonal(
          key: ValueKey('ops-open-${item.serverId}'),
          onPressed: () {
            // The sheet, if open, must not stay above the server page.
            Navigator.of(context).popUntil((route) => route.isFirst);
            open(item.serverId);
          },
          child: Text(l.opsOpenServer),
        );
      case VpnAttentionAction.forceDelete:
        final user = item.removing.where(c.canForceDelete).firstOrNull;
        if (user == null) return null;
        return FilledButton.tonal(
          key: ValueKey('client-force-delete-${user.id}'),
          onPressed: !c.canMutate ? null : () => _force(context, user),
          child: Text(l.uiForceDeleteClient),
        );
      case VpnAttentionAction.continueHere:
        return FilledButton.tonal(
          key: ValueKey('ops-continue-${item.serverId}'),
          onPressed: !c.canMutate ? null : () => _continueHere(item),
          child: Text(l.opsContinueHere),
        );
      case VpnAttentionAction.details:
        return null;
    }
  }

  void _details(BuildContext context) => showAppDetails(
    context,
    title: AppLocalizations.of(context).opsDetailsTitle,
    children: [
      ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _OperationsDetails(
          controller: controller,
          serverName: serverName,
          action: (item) => _action(context, item),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final items = controller.attention;
      Widget? banner;
      if (items.isNotEmpty) {
        final first = items.first;
        final names = {
          for (final item in items)
            for (final user in item.removing) user.name,
        };
        final what = names.isEmpty ? null : l.opsRemoving(names.join(', '));
        if (first.needsUser) {
          final action = _action(context, first);
          banner = AppStatusBanner(
            key: const ValueKey('server-operations-banner'),
            tone: first.failed ? AppStatusTone.error : AppStatusTone.attention,
            title: vpnMessage(l, first.blocker!),
            message: [serverName(first.serverId), ?what].join(' · '),
            onTap: () => _details(context),
            actions: [
              TextButton(
                onPressed: () => _details(context),
                child: Text(l.componentsDetails),
              ),
              ?action,
            ],
          );
        } else {
          final servers = [for (final item in items) serverName(item.serverId)];
          final running = [
            for (final item in items)
              for (final target in item.targets) ?target.progress,
          ];
          banner = AppStatusBanner(
            key: const ValueKey('server-operations-banner'),
            title: what ?? l.opsApplying,
            message: servers.length <= 2
                ? servers.join(', ')
                : l.opsMoreServers(
                    servers.take(2).join(', '),
                    servers.length - 2,
                  ),
            progress: running.length == 1 ? running.single : null,
            onTap: () => _details(context),
            tooltip: l.componentsDetails,
          );
        }
      }
      return AppAnimatedSize(
        motion: MotionPreference.system,
        child: banner == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: banner,
              ),
      );
    },
  );
}

class _OperationsDetails extends StatelessWidget {
  const _OperationsDetails({
    required this.controller,
    required this.serverName,
    required this.action,
  });
  final VpnController controller;
  final String Function(String) serverName;
  final Widget? Function(VpnServerAttention) action;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), c = controller;
    final items = c.attention;
    if (items.isEmpty) {
      return AppNotice(
        message: l.vpnAccessRevoked,
        icon: Icons.check_circle_outline,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in items) ...[
          AppSectionHeading(title: serverName(item.serverId), subheader: true),
          if (item.needsUser)
            AppNotice(
              message: vpnMessage(l, item.blocker!),
              error: item.failed,
              icon: Icons.pending_actions,
              action: action(item),
            ),
          for (final user in item.removing)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_remove_outlined),
              title: Text(l.opsRemovalOf(user.name)),
            ),
          for (final target in item.targets)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(ServerOperationsBanner.protocolLabel(target.target)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(vpnMessage(l, target.code)),
                  if (target.progress case final progress?)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: LinearProgressIndicator(value: progress),
                    ),
                ],
              ),
            ),
          Wrap(
            spacing: AppLayout.smallGap,
            runSpacing: 4,
            children: [
              if (item.needsUser)
                for (final user in item.removing)
                  OutlinedButton(
                    key: ValueKey('ops-retry-deletion-${user.id}'),
                    onPressed: !c.canMutate
                        ? null
                        : () => c.retryDeletion(user.id),
                    child: Text(l.runnerRetry),
                  ),
              for (final target in item.targets)
                if (const {
                  'failed',
                  'partially_applied',
                }.contains(c.currentJob(target.target)?.status))
                  OutlinedButton(
                    onPressed: !c.canMutate
                        ? null
                        : () => c.resume(target.target),
                    child: Text(
                      '${l.runnerRetry} · '
                      '${ServerOperationsBanner.protocolLabel(target.target)}',
                    ),
                  ),
            ],
          ),
          for (final user in item.removing)
            if (user.deletion!['file']?['error'] case final String issue)
              AppNotice(message: publicationMessage(l, issue), error: true),
        ],
      ],
    );
  }
}
