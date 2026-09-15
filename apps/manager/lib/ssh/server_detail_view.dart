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
    this.onBack,
    this.protocols,
    super.key,
  });
  final SshController session;
  final MotionPreference motion;
  final Widget? protocols;
  final VoidCallback? onBack;
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
            padding: AppLayout.screenPadding(
              context,
            ).copyWith(bottom: AppLayout.smallGap),
            child: Row(
              children: [
                if (widget.onBack != null) ...[
                  IconButton(
                    key: const ValueKey('server-list-back'),
                    tooltip: l.server,
                    onPressed: c.vaultBusy || c.picking ? null : widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: AppLayout.smallGap),
                ],
                Expanded(
                  child: Text(
                    c.displayName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth:
                        MediaQuery.sizeOf(context).width < AppLayout.compact
                        ? 160
                        : 240,
                  ),
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
