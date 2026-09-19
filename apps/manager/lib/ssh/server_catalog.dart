import '../runner/xray_upgrade_view.dart';
import '../drag_select_list.dart';
import '../catalog_selection.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../network/ip_diagnostics_controller.dart';
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
import '../vpn/adopt_resource.dart';
import '../vpn/vpn_plan_view.dart';
import 'package:antirkn_domain/antirkn_domain.dart';

class ServerCatalog extends StatefulWidget {
  const ServerCatalog({
    required this.controller,
    required this.motion,
    this.vpn,
    this.selection,
    this.diagnostics,
    super.key,
  });
  final ServerCatalogController controller;
  final MotionPreference motion;
  final VpnController? vpn;
  final CatalogSelection? selection;
  final IpDiagnosticsController? diagnostics;

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
          !(vpn?.hasPendingRevocation(id) ?? false) &&
          !(vpn?.hasLocalServerState(id) ?? false),
    );
    if (controller.error == null) {
      selection.exit();
      return;
    }
    if (!context.mounted) return;
    if (controller.error == VaultIssue.busy) {
      final forget = await showDialog<bool>(
        context: context,
        builder: (context) => AppFormDialog(
          title: Text(l.catalogForgetServerTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.catalogForgetServerWarning),
                const SizedBox(height: AppLayout.gap),
                for (final server in chosen) Text(server.profile.displayName),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.sshCancel),
            ),
            FilledButton(
              key: const ValueKey('ssh-forget-local-confirm'),
              onPressed: () {
                AppHaptics.deleted();
                Navigator.pop(context, true);
              },
              child: Text(l.catalogForgetServerAction),
            ),
          ],
        ),
      );
      if (forget != true || !context.mounted) return;
      final ids = chosen.map((server) => server.id).toSet();
      await controller.forgetServersLocally(
        ids,
        abandonVpnState: () async =>
            vpn == null || await vpn.forgetServersLocally(ids),
      );
      if (controller.error == null) {
        selection.exit();
        return;
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.error == VaultIssue.busy
                ? l.catalogServerForgetBlocked
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
  final inboundSelection = CatalogSelection();
  final inboundPanel = GlobalKey<InboundsPanelState>();
  CatalogSelection get selection => widget.selection ?? ownSelection;
  @override
  void dispose() {
    _legacyPassword.dispose();
    ownSelection.dispose();
    inboundSelection.dispose();
    super.dispose();
  }

  final navigation = GlobalKey<NavigatorState>();
  bool containerOpen = false;
  VoidCallback? closeContainer;
  Widget? _detail;
  SshController? _detailSession;

  Widget _content(
    BuildContext context, {
    bool detail = false,
    VoidCallback? onBack,
  }) {
    final c = widget.controller;
    final l = AppLocalizations.of(context);
    if (detail && c.selected != null) {
      final session = c.selected!;
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
              (r) =>
                  (r.spec['adoption'] as Map?)?['sourceId'] ==
                          '${value['id']}' &&
                      (r.spec['adoption'] as Map?)?['panelPort'] ==
                          panel['port'] ||
                  value['name'] ==
                      'AntiRKN:${vpn?.workspace.resourceWorkspaceId(r.serverId)}:${r.id}',
            ))
              value,
      ];
      final awgManaged =
          vpn?.workspace.awgInterfaces
              .where((r) => r.serverId == c.selectedId && !r.deleted)
              .toList() ??
          <AwgInterface>[];
      final awgExternal = (session.runner.awgDiscovery?['resources'] as List? ?? [])
          .whereType<Map>()
          .where(
            (item) => !hasAdoptedSource(
              awgManaged.map((r) => r.spec),
              item['id'] as String,
            ),
          )
          .toList();
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
        key: ObjectKey(session),
        session: session,
        vpn: vpn,
        coreUpgrade: vpn == null
            ? null
            : XrayUpgradeView(
                runner: session.runner,
                vpn: vpn,
                host: session.host.text.trim(),
              ),
        diagnostics: widget.diagnostics,
        motion: widget.motion,
        onBack: onBack ?? c.showList,
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
                  selection: inboundSelection,
                  selectionActions: () =>
                      inboundPanel.currentState?.selectionActions() ??
                      const SizedBox.shrink(),
                  selectionEnabled:
                      !vpn.busy &&
                      !vpn.hasRunning &&
                      !session.runner.busy &&
                      !session.runner.actionPending &&
                      managed.length + external.length > 0,
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
                    key: inboundPanel,
                    selectionInHeader: true,
                    selection: inboundSelection,
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
                  count: awgManaged.length + awgExternal.length,
                  detected:
                      session.runner.presence(VpnComponent.amneziaWg) ==
                          ComponentPresence.detected ||
                      awgExternal.isNotEmpty,
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
                        controller: vpn,
                        serverId: c.selectedId!,
                        serverHost: session.host.text.trim(),
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
          await c.refresh();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          controller: scroll,
          key: const PageStorageKey('server-list'),
          padding: AppLayout.screenPadding(context),
          children: [
            CatalogNormalContent(
              selection: selection,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('server-add'),
                    onPressed: c.loading
                        ? null
                        : () {
                            c.add();
                          },
                    icon: const Icon(Icons.add),
                    label: Text(l.addServer),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
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
                      AppOpenContainer(
                        motion: widget.motion,
                        onClosed: () {
                          containerOpen = false;
                          closeContainer = null;
                          c.showList();
                        },
                        openBuilder: (context, close) {
                          closeContainer = close;
                          return ListenableBuilder(
                            listenable: Listenable.merge([c, widget.vpn]),
                            builder: (context, _) {
                              if (c.selected == null) {
                                final route = ModalRoute.of(context);
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (mounted &&
                                      containerOpen &&
                                      c.selected == null &&
                                      route?.isCurrent == true) {
                                    close();
                                  }
                                });
                                return _detail ?? const SizedBox.shrink();
                              }
                              _detail = _content(
                                context,
                                detail: true,
                                onBack: close,
                              );
                              return _detail!;
                            },
                          );
                        },
                        closedBuilder: (context, openContainer) => Padding(
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
                                leading: CatalogSelectionLeading(
                                  active: selection.active,
                                  selected: selection.ids.contains(server.id),
                                  checkboxKey: ValueKey(
                                    'server-select-${server.id}',
                                  ),
                                  onChanged: c.loading
                                      ? null
                                      : (_) => selection.toggle(server.id),
                                  child: AppIconTile(
                                    text: server.profile.displayName
                                        .trim()
                                        .characters
                                        .take(2)
                                        .toString()
                                        .toUpperCase(),
                                  ),
                                ),
                                title: Text(server.profile.displayName),
                                subtitle: Column(
                                  mainAxisSize: MainAxisSize.min,
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
                                        containerOpen = true;
                                        c.select(server.id);
                                        openContainer();
                                      },
                              ),
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
  Widget build(BuildContext context) => NavigatorPopHandler<void>(
    enabled: AppPageVisibility.of(context),
    onPopWithResult: (_) => navigation.currentState?.maybePop(),
    child: Navigator(
      key: navigation,
      onGenerateRoute: (_) =>
          MaterialPageRoute<void>(builder: (context) => _catalogue(context)),
    ),
  );

  Widget _catalogue(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, selection, widget.vpn]),
    builder: (context, _) {
      final selected = widget.controller.selected != null;
      if (selected && !containerOpen) {
        _detailSession = widget.controller.selected;
        _detail = _content(context, detail: true);
      } else if (_detailSession != null &&
          widget.controller.sessionFor(_detailSession!.serverId) !=
              _detailSession) {
        _detail = null;
        _detailSession = null;
      }
      return AppPageSwitch(
        index: selected && !containerOpen ? 1 : 0,
        depth: selected && !containerOpen ? 1 : 0,
        motion: widget.motion,
        children: [
          _content(context),
          containerOpen
              ? const SizedBox.shrink()
              : _detail ?? const SizedBox.shrink(),
        ],
      );
    },
  );
}
