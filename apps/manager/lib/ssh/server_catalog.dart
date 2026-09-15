import '../drag_select_list.dart';
import '../catalog_selection.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'server_detail_view.dart';
import 'protocol_removal.dart';
import 'server_catalog_controller.dart';
import 'ssh_controller.dart';
import 'ssh_panel.dart';
import '../vpn/vpn_controller.dart';
import '../vpn/inbounds_panel.dart';
import '../vpn/awg_panel.dart';
import '../vpn/tt_panel.dart';
import '../vpn/awg_existing_panel.dart';
import '../vpn/vpn_plan_view.dart';
import 'package:antirkn_domain/antirkn_domain.dart';

class ServerCatalog extends StatefulWidget {
  const ServerCatalog({
    required this.controller,
    required this.motion,
    this.vpn,
    this.selection,
    super.key,
  });
  final ServerCatalogController controller;
  final MotionPreference motion;
  final VpnController? vpn;
  final CatalogSelection? selection;

  static Future<void> deleteSelected(
    BuildContext context,
    ServerCatalogController controller,
    CatalogSelection selection,
    VpnController? vpn,
  ) async {
    final chosen = controller.servers
        .where((s) => selection.ids.contains(s.id))
        .toList();
    if (chosen.isEmpty || controller.loading) return;
    final l = AppLocalizations.of(context);
    final accepted = await confirmCatalogDeletion(
      context,
      explanation: l.sshDeleteHelp,
      names: chosen.map((s) => s.profile.displayName).toList(),
      confirmKey: 'ssh-delete-confirm',
    );
    if (!accepted || !context.mounted) return;
    await controller.deleteServers(
      chosen,
      canDelete: (id) =>
          !(vpn?.busy ?? false) &&
          !(vpn?.hasRunning ?? false) &&
          !(vpn?.hasPendingRevocation(id) ?? false),
    );
    if (controller.error == null) {
      selection.exit();
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.error == VaultIssue.busy
                ? l.catalogServerDeleteBlocked
                : vaultIssueLabel(l, controller.error!),
          ),
        ),
      );
    }
  }

  @override
  State<ServerCatalog> createState() => _ServerCatalogState();
}

class _ServerCatalogState extends State<ServerCatalog> {
  final _legacyPassword = TextEditingController();
  final ownSelection = CatalogSelection();
  CatalogSelection get selection => widget.selection ?? ownSelection;
  @override
  void dispose() {
    _legacyPassword.dispose();
    ownSelection.dispose();
    super.dispose();
  }

  Widget _content(BuildContext context) {
    final c = widget.controller;
    final l = AppLocalizations.of(context);
    if (c.selected case final session?) {
      final vpn = widget.vpn;
      final managed =
          vpn?.workspace.inbounds
              .where((r) => r.serverId == c.selectedId && !r.deleted)
              .toList() ??
          <VlessInbound>[];
      final external = [
        for (final panel in session.runner.panels)
          for (final value in panel['inbounds'] as List)
            if (!managed.any(
              (r) => value['name'] == 'AntiRKN:${vpn?.workspace.id}:${r.id}',
            ))
              value,
      ];
      String serverName(String id) =>
          c.servers
              .where((s) => s.id == vpnServerId(id))
              .firstOrNull
              ?.profile
              .displayName ??
          id;
      final activityTargets = vpn == null
          ? <String>[]
          : vpn.workspace.serverIds
                .where(
                  (id) =>
                      vpnServerId(id) == c.selectedId &&
                      (vpn.currentJob(id) != null ||
                          vpn.workspace.servers[id]?['pending'] != null ||
                          vpn.observationErrors[id] != null),
                )
                .toList();
      return ServerDetailView(
        key: ValueKey(c.selectedId),
        session: session,
        motion: widget.motion,
        onBack: c.showList,
        clientCount:
            vpn?.workspace.users.where((u) => !u.deleted && u.enabled).length ??
            0,
        plans: vpn == null
            ? null
            : VpnPlanView(controller: vpn, serverName: serverName),
        activity: vpn == null || activityTargets.isEmpty
            ? null
            : Column(
                children: [
                  for (final id in activityTargets)
                    Card.filled(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: VpnJobView(
                          controller: vpn,
                          serverId: id,
                          showSnapshot: false,
                        ),
                      ),
                    ),
                ],
              ),
        sections: vpn == null
            ? const []
            : [
                ServerProtocolSection(
                  name: 'VLESS',
                  onRemove: () => removeServerProtocol(
                    context,
                    session,
                    vpn,
                    'vless',
                    'VLESS',
                  ),
                  mark: 'V',
                  count: managed.length + external.length,
                  detected: session.runner.panelDetected,
                  child: InboundsPanel(
                    showPlan: false,
                    controller: vpn,
                    runner: session.runner,
                    serverHost: session.host.text.trim(),
                    serverId: c.selectedId!,
                    serverName: serverName,
                    network: session.network,
                    motion: widget.motion,
                  ),
                ),
                ServerProtocolSection(
                  name: 'AmneziaWG',
                  onRemove: () => removeServerProtocol(
                    context,
                    session,
                    vpn,
                    'amneziawg',
                    'AmneziaWG',
                  ),
                  mark: 'W',
                  count: vpn.workspace.awgInterfaces
                      .where((r) => r.serverId == c.selectedId && !r.deleted)
                      .length,
                  detected:
                      session.runner.presence(VpnComponent.amneziaWg) ==
                      ComponentPresence.detected,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AwgPanel(
                        controller: vpn,
                        serverId: c.selectedId!,
                        network: session.network,
                        motion: widget.motion,
                      ),
                      const SizedBox(height: AppLayout.gap),
                      AwgExistingPanel(
                        runner: session.runner,
                        motion: widget.motion,
                      ),
                    ],
                  ),
                ),
                ServerProtocolSection(
                  name: 'TrustTunnel',
                  onRemove: () => removeServerProtocol(
                    context,
                    session,
                    vpn,
                    'trusttunnel',
                    'TrustTunnel',
                  ),
                  mark: 'T',
                  count: vpn.workspace.ttEndpoints
                      .where((r) => r.serverId == c.selectedId && !r.deleted)
                      .length,
                  detected:
                      session.runner.presence(VpnComponent.trustTunnel) ==
                      ComponentPresence.detected,
                  child: TtPanel(
                    key: ValueKey('tt-${c.selectedId}'),
                    controller: vpn,
                    serverId: c.selectedId!,
                    runner: session.runner,
                    picker: c.picker,
                    network: session.network,
                    motion: widget.motion,
                  ),
                ),
              ],
      );
    }
    return DragSelectList(
      selection: selection,
      ids: c.servers.map((s) => s.id).toList(),
      enabled: !c.loading,
      builder: (scroll, item) => RefreshIndicator(
        onRefresh: () async {
          AppHaptics.selection();
          await c.refresh();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          controller: scroll,
          key: const PageStorageKey('server-list'),
          padding: AppLayout.screenPadding(context),
          children: [
            if (!selection.active) ...[
              FilledButton.icon(
                onPressed: c.loading
                    ? null
                    : () {
                        AppHaptics.selection();
                        c.add();
                      },
                icon: const Icon(Icons.add),
                label: Text(l.addServer),
              ),
              const SizedBox(height: 20),
            ],
            AppSectionHeading(title: l.uiMyServers, count: c.servers.length),
            if (c.loading) const LinearProgressIndicator(),
            if (c.error case final issue?) ...[
              Text(vaultIssueLabel(l, issue)),
              OutlinedButton(
                onPressed: c.loading ? null : c.load,
                child: Text(l.vaultRetry),
              ),
            ],
            if (c.needsLegacyPassword)
              SectionCard(
                title: l.migrateConnection,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l.migrateConnectionHelp),
                    const SizedBox(height: AppLayout.gap),
                    TextField(
                      controller: _legacyPassword,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(labelText: l.vaultPassword),
                    ),
                    FilledButton(
                      onPressed: c.loading
                          ? null
                          : () async {
                              final password = _legacyPassword.text;
                              _legacyPassword.clear();
                              await c.load(password: password);
                            },
                      child: Text(l.migrateConnection),
                    ),
                  ],
                ),
              ),
            if (c.servers.isEmpty && !c.loading)
              AppEmptyState(
                title: l.noServers,
                message: l.noServersHelp,
                icon: Icons.dns_outlined,
              ),
            Card.filled(
              child: AppAnimatedCollection(
                motion: widget.motion,
                items: {
                  for (final server in c.servers)
                    server.id: item(
                      server.id,
                      Padding(
                        padding: EdgeInsets.zero,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(
                                color: server.id == c.servers.first.id
                                    ? Colors.transparent
                                    : Theme.of(context)
                                          .colorScheme
                                          .outlineVariant
                                          .withValues(alpha: .55),
                              ),
                            ),
                          ),
                          child: Material(
                            type: MaterialType.transparency,
                            clipBehavior: Clip.hardEdge,
                            child: ListTile(
                              key: ValueKey('server-${server.id}'),
                              selected:
                                  selection.active &&
                                  selection.ids.contains(server.id),
                              leading: selection.active
                                  ? Checkbox(
                                      key: ValueKey(
                                        'server-select-${server.id}',
                                      ),
                                      value: selection.ids.contains(server.id),
                                      onChanged: c.loading
                                          ? null
                                          : (_) => selection.toggle(server.id),
                                    )
                                  : AppIconTile(
                                      text: server.profile.displayName
                                          .trim()
                                          .characters
                                          .take(2)
                                          .toString()
                                          .toUpperCase(),
                                    ),
                              title: Text(server.profile.displayName),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    [
                                      ?c.osFor(server.id),
                                      server.profile.host,
                                    ].join(' · '),
                                  ),
                                  const SizedBox(height: 5),
                                  Row(
                                    children: [
                                      Icon(
                                        c.stageFor(server.id) ==
                                                SshStage.connected
                                            ? Icons.check_circle_outline
                                            : Icons.circle_outlined,
                                        size: 13,
                                        color:
                                            c.stageFor(server.id) ==
                                                SshStage.connected
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 5),
                                      Flexible(
                                        child: Text(
                                          switch (c.stageFor(server.id)) {
                                            SshStage.connected =>
                                              l.sshConnected,
                                            SshStage.connecting =>
                                              l.sshConnecting,
                                            SshStage.verifying =>
                                              l.sshTrustTitle,
                                            SshStage.reading => l.sshReading,
                                            SshStage.checkingPrivileges =>
                                              l.privilegesChecking,
                                            SshStage.idle => l.uiOffline,
                                          },
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              trailing: selection.active
                                  ? null
                                  : const Icon(Icons.chevron_right),
                              onTap: c.loading
                                  ? null
                                  : selection.active
                                  ? () => selection.toggle(server.id)
                                  : () {
                                      AppHaptics.selection();
                                      c.select(server.id);
                                    },
                            ),
                          ),
                        ),
                      ),
                    ),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, selection, widget.vpn]),
    builder: (context, _) => ClipRect(
      child: AnimatedSwitcher(
        duration: AppMotion.navigationDuration(context, widget.motion),
        transitionBuilder: (child, animation) {
          final entering =
              child.key ==
              ValueKey(widget.controller.selectedId ?? 'catalogue');
          final forward = widget.controller.selectedId != null;
          final offset = entering
              ? (forward ? const Offset(.3, 0) : const Offset(-.15, 0))
              : (forward ? const Offset(-.15, 0) : const Offset(.3, 0));
          return AppPageVisibility(
            active: AppPageVisibility.of(context) && entering,
            child: IgnorePointer(
              ignoring: !entering,
              child: FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: animation.drive(
                    Tween(begin: offset, end: Offset.zero),
                  ),
                  child: child,
                ),
              ),
            ),
          );
        },
        switchInCurve: AppMotion.curve,
        layoutBuilder: (current, previous) => Stack(
          fit: StackFit.expand,
          children: [...previous, if (current != null) current],
        ),
        child: KeyedSubtree(
          key: ValueKey(widget.controller.selectedId ?? 'catalogue'),
          child: _content(context),
        ),
      ),
    ),
  );
}
