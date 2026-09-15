import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../network/network_workbench.dart';
import '../runner/runner_panel.dart';
import 'server_inventory_panel.dart';
import 'ssh_controller.dart';
import 'ssh_panel.dart';

class ServerDetailView extends StatefulWidget {
  const ServerDetailView({
    required this.session,
    required this.motion,
    required this.canDelete,
    required this.onDeleted,
    this.protocols,
    super.key,
  });
  final SshController session;
  final MotionPreference motion;
  final Widget? protocols;
  final bool Function() canDelete;
  final Future<void> Function() onDeleted;
  @override
  State<ServerDetailView> createState() => _ServerDetailViewState();
}

class _ServerDetailViewState extends State<ServerDetailView>
    with SingleTickerProviderStateMixin {
  late final tabs = TabController(length: 3, vsync: this);
  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  Widget _page(String key, List<Widget> children) => ListView(
    key: PageStorageKey('${widget.session.serverId}-$key'),
    padding: AppLayout.screenPadding(context),
    children: children,
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final c = widget.session, l = AppLocalizations.of(context);
      if (!c.initialised) {
        return const Center(child: CircularProgressIndicator());
      }
      // First-time credentials, host trust and sudo challenges remain directly reachable.
      final connectionRequired =
          !c.hasSavedProfile || c.challenge != null || c.showPrivilegePrompt;
      if (connectionRequired && tabs.index != 2) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && tabs.index != 2) tabs.index = 2;
        });
      }
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppLayout.gap),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    c.displayName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Flexible(
                  child: FilledButton.tonal(
                    key: ValueKey(
                      c.busy
                          ? 'ssh-cancel'
                          : c.stage == SshStage.connected
                          ? 'ssh-disconnect'
                          : 'ssh-connect',
                    ),
                    onPressed: c.busy || c.stage == SshStage.connected
                        ? c.disconnect
                        : c.editing
                        ? c.connect
                        : null,
                    child: Text(
                      c.busy
                          ? l.sshCancel
                          : c.stage == SshStage.connected
                          ? l.sshDisconnect
                          : c.saved
                          ? l.sshConnect
                          : l.sshSaveAndConnect,
                    ),
                  ),
                ),
                if (c.hasSavedProfile)
                  PopupMenuButton<String>(
                    key: const ValueKey('server-actions'),
                    tooltip: l.uiActions,
                    onSelected: (_) async {
                      if (!c.editing ||
                          c.stage != SshStage.idle ||
                          c.runner.busy ||
                          !widget.canDelete()) {
                        tabs.animateTo(2);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l.uiDisconnectBeforeDelete)),
                        );
                        return;
                      }
                      await confirmSshProfileDeletion(context, c);
                      if (mounted && !c.hasSavedProfile) {
                        await widget.onDeleted();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        key: const ValueKey('ssh-delete'),
                        value: 'delete',
                        child: Text(l.uiDeleteServer),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          TabBar(
            controller: tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: l.uiProtocols),
              Tab(text: l.uiMaintenance),
              Tab(
                key: const ValueKey('server-tab-connection'),
                text: l.uiConnection,
              ),
            ],
          ),
          if (c.error != null)
            ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(sshIssueLabel(l, c.error!)),
              onTap: () => tabs.animateTo(2),
            ),
          ListenableBuilder(
            listenable: c.runner,
            builder: (context, _) {
              final job = c.runner.selected;
              final attention =
                  c.runner.error != null ||
                  c.runner.pending != null ||
                  job != null &&
                      (!job.terminal ||
                          [
                            'failed',
                            'partially_applied',
                            'needs_attention',
                          ].contains(job.status));
              if (!attention) return const SizedBox.shrink();
              return ListTile(
                leading: const Icon(Icons.pending_actions),
                title: Text(
                  job == null
                      ? l.runnerAttention
                      : runnerStateLabel(l, job.status),
                ),
                onTap: () => tabs.animateTo(1),
              );
            },
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: tabs,
              builder: (context, _) => IndexedStack(
                index: connectionRequired ? 2 : tabs.index,
                children: [
                  _page('protocols', [
                    if (c.hasSavedProfile && widget.protocols != null)
                      widget.protocols!
                    else
                      Text(l.sshConnect),
                  ]),
                  _page('maintenance', [
                    RunnerPanel(controller: c.runner, motion: widget.motion),
                  ]),
                  _page('connection', [
                    SshPanel(
                      controller: c,
                      motion: widget.motion,
                      showDelete: false,
                      showConnectionActions: false,
                    ),
                    ExpansionTile(
                      key: PageStorageKey('server-details-${c.serverId}'),
                      title: Text(l.serverDetails),
                      children: [
                        if (c.software case final software?)
                          ServerInventoryPanel(
                            inventory: software,
                            current: c.stage == SshStage.connected,
                            motion: widget.motion,
                          ),
                        NetworkWorkbench(
                          controller: c.network,
                          motion: widget.motion,
                          diagnosticsOnly: true,
                        ),
                      ],
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}
