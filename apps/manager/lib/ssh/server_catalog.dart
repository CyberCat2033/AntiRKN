import '../drag_select_list.dart';
import '../catalog_selection.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'server_detail_view.dart';
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, selection]),
    builder: (context, _) {
      final c = widget.controller;
      final l = AppLocalizations.of(context);
      if (c.selected case final session?) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && !session.vaultBusy && !session.picking) c.showList();
          },
          child: Column(
            children: [
              Expanded(
                child: ServerDetailView(
                  key: ValueKey(c.selectedId),
                  session: session,
                  motion: widget.motion,
                  onBack: c.showList,
                  protocols: widget.vpn == null
                      ? null
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            InboundsPanel(
                              showPlan: false,
                              controller: widget.vpn!,
                              runner: session.runner,
                              serverHost: session.host.text.trim(),
                              serverId: c.selectedId!,
                              serverName: (id) =>
                                  c.servers
                                      .where((s) => s.id == vpnServerId(id))
                                      .firstOrNull
                                      ?.profile
                                      .displayName ??
                                  id,
                              network: session.network,
                              motion: widget.motion,
                            ),
                            const SizedBox(height: AppLayout.gap),
                            AwgPanel(
                              controller: widget.vpn!,
                              serverId: c.selectedId!,
                              network: session.network,
                              motion: widget.motion,
                            ),
                            AwgExistingPanel(
                              runner: session.runner,
                              motion: widget.motion,
                            ),
                            const SizedBox(height: AppLayout.gap),
                            TtPanel(
                              key: ValueKey('tt-${c.selectedId}'),
                              controller: widget.vpn!,
                              serverId: c.selectedId!,
                              runner: session.runner,
                              picker: c.picker,
                              network: session.network,
                              motion: widget.motion,
                            ),
                            ListenableBuilder(
                              listenable: widget.vpn!,
                              builder: (context, _) => VpnPlanView(
                                controller: widget.vpn!,
                                serverName: (id) =>
                                    c.servers
                                        .where((s) => s.id == vpnServerId(id))
                                        .firstOrNull
                                        ?.profile
                                        .displayName ??
                                    id,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      }
      return DragSelectList(
        selection: selection,
        ids: c.servers.map((s) => s.id).toList(),
        enabled: !c.loading,
        builder: (scroll, item) => ListView(
          controller: scroll,
          key: const PageStorageKey('server-list'),
          padding: AppLayout.screenPadding(context),
          children: [
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
              SectionCard(title: l.noServers, child: Text(l.noServersHelp)),
            for (final server in c.servers)
              item(
                server.id,
                Padding(
                  padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
                  child: Card.filled(
                    child: ListTile(
                      key: ValueKey('server-${server.id}'),
                      selected:
                          selection.active && selection.ids.contains(server.id),
                      leading: selection.active
                          ? Checkbox(
                              key: ValueKey('server-select-${server.id}'),
                              value: selection.ids.contains(server.id),
                              onChanged: c.loading
                                  ? null
                                  : (_) => selection.toggle(server.id),
                            )
                          : const Icon(Icons.dns_outlined),
                      title: Text(server.profile.displayName),
                      subtitle: Text(
                        [
                          '${server.profile.host}:${server.profile.port}',
                          switch (c.stageFor(server.id)) {
                            SshStage.connected => l.sshConnected,
                            SshStage.connecting => l.sshConnecting,
                            SshStage.verifying => l.sshTrustTitle,
                            SshStage.reading => l.sshReading,
                            SshStage.checkingPrivileges => l.privilegesChecking,
                            SshStage.idle => l.sshIdle,
                          },
                        ].join(' · '),
                      ),
                      trailing: selection.active
                          ? null
                          : const Icon(Icons.chevron_right),
                      onTap: c.loading
                          ? null
                          : selection.active
                          ? () => selection.toggle(server.id)
                          : () => c.select(server.id),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
