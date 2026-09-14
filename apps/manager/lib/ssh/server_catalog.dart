import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../network/network_workbench.dart';
import 'server_catalog_controller.dart';
import 'ssh_controller.dart';
import 'ssh_panel.dart';
import '../vpn/vpn_controller.dart';
import '../vpn/inbounds_panel.dart';

class ServerCatalog extends StatefulWidget {
  const ServerCatalog({
    required this.controller,
    required this.motion,
    this.vpn,
    super.key,
  });
  final ServerCatalogController controller;
  final MotionPreference motion;
  final VpnController? vpn;
  @override
  State<ServerCatalog> createState() => _ServerCatalogState();
}

class _ServerCatalogState extends State<ServerCatalog> {
  final _legacyPassword = TextEditingController();
  @override
  void dispose() {
    _legacyPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
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
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('server-list-back'),
                  onPressed: session.vaultBusy || session.picking
                      ? null
                      : c.showList,
                  icon: const Icon(Icons.arrow_back),
                  label: Text(l.server),
                ),
              ),
              Expanded(
                child: NetworkWorkbench(
                  key: ValueKey(c.selectedId),
                  controller: session.network,
                  ssh: session,
                  motion: widget.motion,
                  protocols: widget.vpn == null
                      ? null
                      : InboundsPanel(
                          controller: widget.vpn!,
                          serverId: c.selectedId!,
                          serverName: (id) =>
                              c.servers
                                  .where((s) => s.id == id)
                                  .firstOrNull
                                  ?.profile
                                  .displayName ??
                              id,
                          network: session.network,
                          motion: widget.motion,
                        ),
                ),
              ),
            ],
          ),
        );
      }
      return ListView(
        key: const PageStorageKey('server-list'),
        padding: AppLayout.padding,
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
            Padding(
              padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
              child: Card(
                child: ListTile(
                  key: ValueKey('server-${server.id}'),
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(server.profile.displayName),
                  subtitle: Text(
                    [
                      '${server.profile.host}:${server.profile.port}',
                      ?c.osFor(server.id),
                      switch (c.stageFor(server.id)) {
                        SshStage.connected => l.sshConnected,
                        SshStage.connecting => l.sshConnecting,
                        SshStage.verifying => l.sshTrustTitle,
                        SshStage.reading => l.sshReading,
                        SshStage.checkingPrivileges => l.privilegesChecking,
                        SshStage.idle => l.sshIdle,
                      },
                    ].join('\n'),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => c.select(server.id),
                ),
              ),
            ),
        ],
      );
    },
  );
}
