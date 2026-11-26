import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../busy_reason.dart';
import '../l10n/app_localizations.dart';
import '../vpn/vpn_controller.dart';
import '../vpn/vpn_strings.dart';

/// The badge of a server in service mode: on its catalog row, its overview
/// and its waiting work. Nothing while the server is not in it.
class ServiceModeBadge extends StatelessWidget {
  const ServiceModeBadge({required this.mode, super.key});
  final ServerServiceMode? mode;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return switch (mode?.state) {
      null => const SizedBox.shrink(),
      ServerServiceState.active => StatusChip(
        label: l.serviceModeTitle,
        icon: Icons.construction_outlined,
      ),
      ServerServiceState.returning => StatusChip(
        label: l.serviceModeReturningBadge,
        icon: Icons.sync,
      ),
    };
  }
}

/// «Service mode» of one server in About: its state, the way in and back,
/// and the access changes that still wait for it.
class ServerServiceModeSection extends StatelessWidget {
  const ServerServiceModeSection({
    required this.vpn,
    required this.serverId,
    required this.serverName,
    this.relay = false,
    this.motion = MotionPreference.system,
    super.key,
  });
  final VpnController vpn;

  /// The catalog id of the physical server.
  final String serverId;
  final String serverName;

  /// Whether the server has a relay inbound: a direct exit for the owner's
  /// other servers.
  final bool relay;

  final MotionPreference motion;

  /// Whether the app knows other servers may leave through this one: a
  /// relay or internal inbound on it. Otherwise the dialog says it
  /// generically.
  bool get _egressRole =>
      relay ||
      vpn.workspace.inbounds.any(
        (r) => r.serverId == serverId && !r.deleted && r.internal,
      );

  void _report(BuildContext context) {
    final code = vpn.error;
    if (code == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(vpnMessage(AppLocalizations.of(context), code))),
    );
  }

  Future<void> _enter(BuildContext context) async {
    final l = AppLocalizations.of(context), egressRole = _egressRole;
    final accepted = await confirmAppAction(
      context,
      title: l.serviceModeEnterTitle,
      content: _Consequences(
        intro: l.serviceModeEnterIntro(serverName),
        items: [
          (Icons.playlist_remove, l.serviceModeEnterProfiles),
          (Icons.cloud_done_outlined, l.serviceModeEnterPublication),
          (Icons.person_add_disabled_outlined, l.serviceModeEnterNewClients),
          (Icons.person_off_outlined, l.serviceModeEnterRevocations),
        ],
        notice: egressRole ? l.serviceModeEnterEgress : null,
        footnote: egressRole ? null : l.serviceModeEnterEgressUnknown,
      ),
      confirmLabel: l.serviceModeEnter,
      cancelLabel: l.sshCancel,
      confirmKey: const ValueKey('service-mode-enter-confirm'),
    );
    if (!accepted || !context.mounted) return;
    await vpn.enterServiceMode(serverId);
    if (context.mounted) _report(context);
  }

  Future<void> _exit(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final accepted = await confirmAppAction(
      context,
      title: l.serviceModeExitTitle,
      content: _Consequences(
        intro: l.serviceModeExitClients(
          vpn.serviceModeExitNewClients(serverId),
        ),
        items: [(Icons.verified_outlined, l.serviceModeExitHelp)],
      ),
      confirmLabel: l.serviceModeExit,
      cancelLabel: l.sshCancel,
      confirmKey: const ValueKey('service-mode-exit-confirm'),
    );
    if (!accepted || !context.mounted) return;
    await _retryExit(context);
  }

  Future<void> _retryExit(BuildContext context) async {
    await vpn.exitServiceMode(serverId);
    if (context.mounted) _report(context);
  }

  Future<void> _cancelExit(BuildContext context) async {
    await vpn.cancelServiceModeExit(serverId);
    if (context.mounted) _report(context);
  }

  Future<void> _retryAccess(BuildContext context) async {
    await vpn.retryServiceAccess(serverId);
    if (context.mounted) _report(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: vpn,
    builder: (context, _) {
      final l = AppLocalizations.of(context),
          theme = Theme.of(context),
          mode = vpn.serviceModeOf(serverId),
          reason = busyReason(l, vpn: vpn),
          ready = vpn.canMutate;
      final returning = mode?.state == ServerServiceState.returning;
      final elsewhere = returning && vpn.serviceModeExitElsewhere(serverId);
      final issue = returning && !elsewhere
          ? vpn.serviceModeExitIssue(serverId)
          : null;
      final waiting = mode == null ? 0 : vpn.serviceAccessWaiting(serverId);
      final accessIssue = vpn.serviceAccessIssue(serverId);
      VoidCallback? when(Future<void> Function(BuildContext) action) =>
          ready ? () => action(context) : null;
      Widget guarded(Widget child) =>
          AppDisabledReason(reason: reason, child: child);
      final state = switch (mode?.state) {
        null => l.serviceModeOff,
        ServerServiceState.returning => l.serviceModeReturningBadge,
        ServerServiceState.active => l.serviceModeSince(
          DateFormat.yMd(l.localeName).add_Hm().format(mode!.since.toLocal()),
        ),
      };
      Widget notice(Widget child) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: child,
      );
      return AppSettingsSection(
        key: const ValueKey('service-mode-section'),
        title: l.serviceModeTitle,
        child: AppAnimatedSize(
          motion: motion,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // On and off both ask first; the way back runs on its own
              // and is cancelled below, not with the switch.
              guarded(
                SwitchListTile(
                  key: const ValueKey('service-mode-switch'),
                  secondary: const Icon(Icons.construction_outlined),
                  title: Text(state, key: const ValueKey('service-mode-state')),
                  subtitle: Text(l.serviceModeHelp),
                  isThreeLine: true,
                  value: mode != null,
                  onChanged: !ready || returning
                      ? null
                      : (on) => on ? _enter(context) : _exit(context),
                ),
              ),
              if (returning && !elsewhere)
                notice(
                  issue == null
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              l.serviceModeReturning,
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 8),
                            const LinearProgressIndicator(
                              key: ValueKey('service-mode-progress'),
                            ),
                          ],
                        )
                      : AppNotice(
                          key: const ValueKey('service-mode-issue'),
                          title: l.serviceModeReturnStalled,
                          message: vpnMessage(l, issue),
                          error: true,
                          margin: EdgeInsets.zero,
                          action: guarded(
                            TextButton(
                              key: const ValueKey('service-mode-retry'),
                              onPressed: when(_retryExit),
                              child: Text(l.serviceModeRetry),
                            ),
                          ),
                        ),
                ),
              if (elsewhere)
                notice(
                  AppNotice(
                    key: const ValueKey('service-mode-elsewhere'),
                    icon: Icons.devices_other_outlined,
                    message: vpnMessage(l, 'vpn_service_mode_other_device'),
                    margin: EdgeInsets.zero,
                    action: guarded(
                      FilledButton.tonal(
                        key: const ValueKey('service-mode-take-over'),
                        onPressed: when(_retryExit),
                        child: Text(l.opsContinueHere),
                      ),
                    ),
                  ),
                ),
              if (waiting > 0 || accessIssue != null)
                notice(
                  AppNotice(
                    key: const ValueKey('service-access-waiting'),
                    icon: Icons.pending_actions,
                    error: accessIssue != null,
                    message: [
                      if (waiting > 0) l.serviceAccessWaiting(waiting),
                      accessIssue == null
                          ? l.serviceAccessWaitingHelp
                          : vpnMessage(l, accessIssue),
                    ].join(' '),
                    margin: EdgeInsets.zero,
                    action: guarded(
                      TextButton(
                        key: const ValueKey('service-access-retry'),
                        onPressed: when(_retryAccess),
                        child: Text(l.serviceAccessSendNow),
                      ),
                    ),
                  ),
                ),
              if (returning)
                notice(
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: guarded(
                      OutlinedButton(
                        key: const ValueKey('service-mode-cancel-exit'),
                        onPressed: when(_cancelExit),
                        child: Text(l.serviceModeCancelExit),
                      ),
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

/// What a confirmed service-mode change does, one consequence per line.
class _Consequences extends StatelessWidget {
  const _Consequences({
    required this.intro,
    required this.items,
    this.notice,
    this.footnote,
  });
  final String intro;
  final List<(IconData, String)> items;
  final String? notice, footnote;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(intro),
        const SizedBox(height: 8),
        for (final (icon, text) in items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon),
            title: Text(text, style: theme.textTheme.bodyMedium),
          ),
        if (notice case final notice?)
          AppNotice(
            key: const ValueKey('service-mode-egress'),
            icon: Icons.alt_route,
            message: notice,
            margin: const EdgeInsets.only(top: 8),
          ),
        if (footnote case final footnote?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              footnote,
              key: const ValueKey('service-mode-egress-generic'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
