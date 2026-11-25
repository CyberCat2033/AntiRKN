import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../network/ip_diagnostics_controller.dart';
import '../catalog_selection.dart';
import '../runner/component_installation_view.dart';
import '../runner/component_updates_controller.dart';
import '../runner/runner_panel.dart';
import 'server_about_view.dart';
import 'ssh_controller.dart';
import 'ssh_harden_wizard.dart';
import 'ssh_panel.dart';
import '../vpn/vpn_controller.dart';

class ServerProtocolSection {
  const ServerProtocolSection({
    required this.name,
    required this.count,
    required this.mark,
    required this.child,
    this.detected = false,
    this.onRemove,
    this.selection,
    this.selectionEnabled = true,
    this.selectionActions,
  });
  final String name, mark;
  final int count;
  final bool detected;
  final Widget child;
  final Future<bool> Function()? onRemove;
  final CatalogSelection? selection;
  final bool selectionEnabled;
  final Widget Function()? selectionActions;
}

class ServerDetailView extends StatefulWidget {
  const ServerDetailView({
    required this.session,
    required this.motion,
    this.vpn,
    this.onBack,
    this.diagnostics,
    this.protocols,
    this.sections = const [],
    this.plans,
    this.activity,
    this.coreUpgrade,
    this.clientEgress,
    this.clientCount = 0,
    super.key,
  });
  final SshController session;
  final MotionPreference motion;
  final VpnController? vpn;
  final VoidCallback? onBack;
  final IpDiagnosticsController? diagnostics;
  final Widget? protocols, plans, activity, coreUpgrade, clientEgress;
  final List<ServerProtocolSection> sections;
  final int clientCount;
  @override
  State<ServerDetailView> createState() => _ServerDetailViewState();
}

class _ServerDetailViewState extends State<ServerDetailView> {
  int selected = 0;
  final visited = <int>{0};
  final workingProtocols = <int>{};
  final protocolJobs = <int, String>{};

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_keepAccessPage);
    _keepAccessPage();
  }

  @override
  void didUpdateWidget(ServerDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_keepAccessPage);
      widget.session.addListener(_keepAccessPage);
      _keepAccessPage();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_keepAccessPage);
    super.dispose();
  }

  /// A server that needs a connection shows the access page; keep it built
  /// afterwards so its drafts survive (outside build, which stays pure).
  void _keepAccessPage() {
    final c = widget.session;
    if (!c.hasSavedProfile || c.challenge != null) visited.add(1);
  }

  bool protocolBusy(int index) =>
      workingProtocols.contains(index) ||
      widget.session.runner.jobs.any(
        (j) => j.id == protocolJobs[index] && !j.terminal,
      );

  Future<void> removeProtocol(int index) async {
    if (protocolBusy(index)) return;
    setState(() => workingProtocols.add(index));
    try {
      final submitted = await widget.sections[index].onRemove!();
      if (submitted && widget.session.runner.selected != null) {
        protocolJobs[index] = widget.session.runner.selected!.id;
      }
    } finally {
      if (mounted) setState(() => workingProtocols.remove(index));
    }
  }

  Future<void> openProtocol(int index) async {
    final section = widget.sections[index];
    if (section.detected) {
      open(5 + index);
      return;
    }
    final l = AppLocalizations.of(context);
    final install = await showDialog<bool>(
      context: context,
      builder: (context) => AppFormDialog(
        title: Text('${l.softwareInstall} · ${section.name}'),
        content: Text(l.uiInstallProtocolHelp),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.runnerNotNow),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.softwareInstall),
          ),
        ],
      ),
    );
    if (!mounted || install != true) return;
    final c = widget.session;
    c.closeSettings();
    setState(() => workingProtocols.add(index));
    try {
      await c.runner.installOrUpdate(protocolComponent(section.name));
    } finally {
      if (mounted) {
        setState(() {
          workingProtocols.remove(index);
          if (c.runner.selected != null && !c.runner.selected!.terminal) {
            protocolJobs[index] = c.runner.selected!.id;
          }
        });
      }
    }
    final componentPlan = c.runner.componentPlan;
    final panelPlan = c.runner.panelPlan;
    final blocked = componentPlan != null && !componentPlan.canApply
        ? !componentPlan.supported
              ? l.protocolPrerequisites
              : componentPlan.state == 'current'
              ? l.protocolCurrent
              : componentPlan.state == 'incompatible'
              ? l.runnerIncompatible
              : l.protocolExisting
        : panelPlan != null && !panelPlan.canApply
        ? !panelPlan.supported
              ? l.componentsPrerequisites
              : !panelPlan.portAvailable
              ? l.componentsPortBusy
              : l.componentsExisting
        : null;
    if (mounted &&
        (blocked != null ||
            c.runner.error != null ||
            c.runner.responseCode != null && c.runner.responseCode != 'ok')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            blocked ??
                (c.runner.responseCode != null && c.runner.responseCode != 'ok'
                    ? runnerCodeLabel(l, c.runner.responseCode!)
                    : runnerIssueLabel(l, c.runner.error!)),
          ),
        ),
      );
    }
  }

  /// Back during IP diagnostics is their explicit cancel (the page stays so
  /// the cancelled result is visible). Returns whether it was consumed.
  bool _cancelDiagnostics() {
    if (!(widget.diagnostics?.busy ?? false)) return false;
    widget.diagnostics!.stop();
    return true;
  }

  /// IP diagnostics keep running in the background: switching section never
  /// silently stops them (the About page shows their progress again).
  void open(int index) {
    if (index == 1) {
      widget.session.editSettings();
    } else {
      widget.session.closeSettings();
    }
    setState(() {
      selected = index;
      visited.add(index);
    });
  }

  Future<void> refresh() async {
    if (widget.diagnostics?.busy ?? false) return;
    if (!await widget.session.ensureConnected()) return;
    await widget.session.refresh();
    await widget.session.runner.refresh(prepare: true);
    if (widget.session.runner.installed && widget.session.runner.connected) {
      await widget.session.runner.awgRequest('awg_discover');
    }
  }

  Widget page(String id, List<Widget> children) => RefreshIndicator(
    onRefresh: refresh,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      key: PageStorageKey('${widget.session.serverId}-$id'),
      padding: AppLayout.screenPadding(context),
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    ),
  );
  int updateCount(ComponentUpdatesController? updates) {
    if (updates == null) return 0;
    final versions = <String, String>{};
    for (final component
        in widget.session.software?.components ?? <ComponentObservation>[]) {
      for (final installation in component.installations) {
        if (installation.version?.value case final version?) {
          versions[releaseKey(component.component, installation.identity)] =
              version;
        }
      }
    }
    return versions.entries
        .where(
          (entry) =>
              updates.latest[entry.key] != null &&
              updates.latest[entry.key] != entry.value,
        )
        .length;
  }

  Widget overview(BuildContext context) {
    final c = widget.session, l = AppLocalizations.of(context);
    final connected = c.stage == SshStage.connected;
    final updates = updateCount(ComponentUpdatesScope.of(context));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card.filled(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    AppIconTile(
                      size: 52,
                      text: c.displayName.characters
                          .take(2)
                          .toString()
                          .toUpperCase(),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.os ?? l.server,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            c.host.text,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            connected
                                ? l.sshConnected
                                : c.busy
                                ? l.sshConnecting
                                : l.uiOffline,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                AppActionRow(
                  children: [
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      key: ValueKey(
                        c.busy
                            ? 'ssh-cancel'
                            : connected
                            ? 'ssh-disconnect'
                            : 'ssh-connect',
                      ),
                      onPressed: c.busy || connected
                          ? () {
                              c.disconnect();
                            }
                          : c.editing
                          ? () {
                              c.connect();
                            }
                          : null,
                      icon: const Icon(Icons.key_outlined),
                      label: Text(
                        c.busy
                            ? l.sshCancel
                            : connected
                            ? l.sshDisconnect
                            : l.sshConnect,
                      ),
                    ),
                    OutlinedButton(
                      key: const ValueKey('server-ssh-access'),
                      onPressed: () => open(1),
                      child: Text(l.uiSshAccess),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _Count(
                      value:
                          '${widget.sections.where((s) => s.count > 0 || s.detected).length}',
                      label: l.uiProtocols,
                    ),
                    const SizedBox(
                      height: 40,
                      child: VerticalDivider(width: 20),
                    ),
                    _Count(value: '${widget.clientCount}', label: l.vpnUsers),
                    const SizedBox(
                      height: 40,
                      child: VerticalDivider(width: 20),
                    ),
                    _Count(value: '$updates', label: l.uiUpdatesShort),
                  ],
                ),
              ],
            ),
          ),
        ),
        if ((widget.session.isRoot ||
                widget.session.profile?.hardenRecovery != null) &&
            widget.session.stage == SshStage.connected) ...[
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.errorContainer.withAlpha(80),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    Icons.security_outlined,
                    color: Theme.of(context).colorScheme.error,
                    size: 32,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.sshHardenBannerTitle,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l.sshHardenBannerSubtitle,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  FilledButton.tonal(
                    onPressed: () =>
                        showSshHardenWizard(context, widget.session),
                    child: Text(l.sshHardenBannerAction),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        AppTwoColumn(
          first: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSectionHeading(title: l.uiProtocols),
              LayoutBuilder(
                builder: (context, constraints) {
                  final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
                  final columns = constraints.maxWidth >= 740
                      ? 3
                      : constraints.maxWidth >= 300 && scale < 1.5
                      ? 2
                      : 1;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 12) / columns;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (var i = 0; i < widget.sections.length; i++)
                        SizedBox(
                          width: width,
                          child: _ProtocolTile(
                            section: widget.sections[i],
                            motion: widget.motion,
                            busy: protocolBusy(i),
                            queued: widget.session.runner.queuedInstalls
                                .contains(
                                  protocolComponent(widget.sections[i].name),
                                ),
                            onTap: () => openProtocol(i),
                            onLongPress:
                                widget.sections[i].onRemove == null ||
                                    !widget.sections[i].detected
                                ? null
                                : () => removeProtocol(i),
                          ),
                        ),
                    ],
                  );
                },
              ),
              if (widget.sections.isEmpty && widget.protocols != null)
                widget.protocols!,
            ],
          ),
          second: AppSettingsSection(
            title: l.uiMaintenance,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: Text(l.uiUpdatesShort),
                  subtitle: Text(
                    updates > 0 ? l.softwareUpdateAvailable : l.uiUpdatesHelp,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(2),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(l.uiActivity),
                  subtitle: Text(l.uiActivityHelp),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(3),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  key: const ValueKey('server-about'),
                  leading: const Icon(Icons.info_outline),
                  title: Text(l.uiServerAbout),
                  subtitle: Text(l.uiServerAboutSummary),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => open(4),
                ),
              ],
            ),
          ),
        ),
        if (widget.plans != null)
          AppAnimatedSize(motion: widget.motion, child: widget.plans!),
      ],
    );
  }

  Widget history(BuildContext context) {
    final c = widget.session.runner, l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPageIntro(l.uiActivityHelp),
        if (c.jobs.isEmpty && widget.activity == null)
          AppEmptyState(title: l.uiNoActivity, icon: Icons.history),
        if (c.jobs.isNotEmpty)
          Card.filled(
            child: Column(
              children: [
                for (final job in c.jobs)
                  ListTile(
                    leading: Icon(
                      job.status == 'succeeded'
                          ? Icons.check_circle_outline
                          : job.terminal
                          ? Icons.info_outline
                          : Icons.pending_outlined,
                    ),
                    title: Text(switch (job.kind) {
                      'apt_update' || 'apt_upgrade' => l.aptTitle,
                      'panel_update' || 'panel_install' => '3x-ui',
                      'component_install' => l.protocolSoftware,
                      'protocol_remove' => l.uiRemoveProtocol,
                      _ => l.uiServerChanges,
                    }),
                    subtitle: Text(
                      !job.terminal && job.kind == 'component_install'
                          ? componentStepProgressText(
                              l,
                              job.checkpoint,
                              job.count,
                            )
                          : runnerStateLabel(l, job.status),
                    ),
                  ),
              ],
            ),
          ),
        ?widget.activity,
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.session,
      widget.session.runner,
      ...widget.sections.map((s) => s.selection),
    ]),
    builder: (context, _) {
      final c = widget.session, l = AppLocalizations.of(context);
      final active = AppPageVisibility.of(context);
      if (!c.initialised) {
        final issue = c.vaultError;
        if (c.vaultBusy || issue == null) {
          return const Center(child: CircularProgressIndicator());
        }
        // Opening the vault failed: never leave an endless spinner without a
        // way back or a retry.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('server-list-back'),
                    tooltip: l.uiBack,
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Expanded(child: AppAnimatedTitle(c.displayName)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppLayout.gap),
              child: Semantics(
                liveRegion: true,
                child: AppNotice(
                  key: const ValueKey('server-vault-error'),
                  message: vaultIssueLabel(l, issue),
                  error: true,
                  action: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextButton.icon(
                      key: const ValueKey('server-vault-retry'),
                      onPressed: c.initialise,
                      icon: const Icon(Icons.refresh),
                      label: Text(l.runnerRetry),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      }
      final requiresConnection = !c.hasSavedProfile || c.challenge != null;
      final index = requiresConnection ? 1 : selected;
      final section = index >= 5 ? widget.sections[index - 5] : null;
      final selecting = section?.selection?.active == true;
      // Pages built so far plus the shown one; build itself never mutates
      // [visited].
      final built = {...visited, index};
      final titles = [
        c.displayName,
        l.uiSshAccess,
        l.uiComponentUpdates,
        l.uiActivity,
        l.uiServerAbout,
        ...widget.sections.map((s) => s.name),
      ];
      return PopScope(
        canPop: !active,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || !active || c.vaultBusy || c.picking) return;
          final selection = index >= 5
              ? widget.sections[index - 5].selection
              : null;
          if (selection?.active == true) {
            selection!.exit();
            return;
          }
          if (_cancelDiagnostics()) return;
          if (index == 0 || (index == 1 && requiresConnection)) {
            widget.onBack?.call();
          } else {
            open(0);
          }
        },
        child: Column(
          children: [
            if (selecting)
              AppBar(
                key: const ValueKey('inbound-selection-toolbar'),
                primary: false,
                automaticallyImplyLeading: false,
                title: CatalogTitle(
                  selection: section!.selection!,
                  title: section.name,
                ),
                actions: [
                  if (section.selectionActions != null)
                    section.selectionActions!(),
                ],
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    IconButton(
                      key: const ValueKey('server-list-back'),
                      tooltip: l.uiBack,
                      onPressed: c.vaultBusy || c.picking
                          ? null
                          : index == 0 || (index == 1 && requiresConnection)
                          ? widget.onBack
                          : () {
                              if (_cancelDiagnostics()) return;
                              final selection = index >= 5
                                  ? widget.sections[index - 5].selection
                                  : null;
                              if (selection?.active == true) {
                                selection!.exit();
                              } else {
                                open(0);
                              }
                            },
                      icon: const Icon(Icons.arrow_back),
                    ),
                    Expanded(child: AppAnimatedTitle(titles[index])),
                    if (index >= 5 &&
                        widget.sections[index - 5].selection != null &&
                        !widget.sections[index - 5].selection!.active)
                      IconButton(
                        key: const ValueKey('inbound-edit'),
                        tooltip: l.catalogEdit,
                        onPressed: widget.sections[index - 5].selectionEnabled
                            ? widget.sections[index - 5].selection!.start
                            : null,
                        icon: const Icon(Icons.edit_outlined),
                      ),
                  ],
                ),
              ),
            if (c.error != null)
              ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(sshIssueLabel(l, c.error!)),
                onTap: () => open(1),
              ),
            if (c.showPrivilegePrompt)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(
                  c.privileges == null
                      ? l.privilegesUnknown
                      : privilegeStatusLabel(l, c.privileges!.status),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(1),
              ),
            if (c.runner.error != null ||
                c.runner.selected != null &&
                    [
                      'failed',
                      'partially_applied',
                      'needs_attention',
                    ].contains(c.runner.selected!.status))
              ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(l.runnerAttention),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(2),
              ),
            Expanded(
              child: AppPageSwitch(
                index: index,
                depth: index == 0 ? 0 : 1,
                motion: widget.motion,
                children: [
                  page('overview', [overview(context)]),
                  built.contains(1)
                      ? page('ssh', [
                          SshPanel(
                            controller: c,
                            motion: widget.motion,
                            showDelete: false,
                            editorOnly: true,
                            onCancel: () => open(0),
                            showConnectionActions: true,
                          ),
                        ])
                      : const SizedBox.shrink(),
                  built.contains(2)
                      ? page('updates', [
                          ?widget.coreUpgrade,
                          RunnerPanel(
                            controller: c.runner,
                            motion: widget.motion,
                          ),
                        ])
                      : const SizedBox.shrink(),
                  built.contains(3)
                      ? page('activity', [history(context)])
                      : const SizedBox.shrink(),
                  built.contains(4)
                      ? page('about', [
                          ServerAboutView(
                            controller: c,
                            diagnostics: widget.diagnostics,
                            vpn: widget.vpn,
                            clientEgress: widget.clientEgress,
                            motion: widget.motion,
                          ),
                        ])
                      : const SizedBox.shrink(),
                  for (var i = 0; i < widget.sections.length; i++)
                    built.contains(5 + i)
                        ? page('protocol-$i', [
                            widget.sections[i].child,
                            if (widget.plans != null) widget.plans!,
                          ])
                        : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _Count extends StatelessWidget {
  const _Count({required this.value, required this.label});
  final String value, label;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );
}

/// The installable component behind a protocol section.
String protocolComponent(String section) => section == 'VLESS'
    ? 'panel'
    : section == 'AmneziaWG'
    ? 'amneziawg'
    : 'trusttunnel';

class _ProtocolTile extends StatelessWidget {
  const _ProtocolTile({
    required this.section,
    required this.motion,
    required this.onTap,
    this.onLongPress,
    this.busy = false,
    this.queued = false,
  });
  final ServerProtocolSection section;
  final MotionPreference motion;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool busy, queued;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context),
        colors = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: AppMotion.duration(context, motion),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: .92, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: Card.filled(
        key: ValueKey('${section.detected}-$busy'),
        color: section.count == 0 && !section.detected
            ? Theme.of(context).scaffoldBackgroundColor
            : null,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppLayout.radius),
          side: section.count == 0 && !section.detected
              ? BorderSide(color: colors.outlineVariant)
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppLayout.radius),
          onTap: busy ? null : onTap,
          onLongPress: busy ? null : onLongPress,
          enableFeedback: false,
          child: Padding(
            padding: const EdgeInsets.all(17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      section.mark,
                      style: TextStyle(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (busy)
                      const SizedBox.square(
                        dimension: 19,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        section.count == 0 && !section.detected
                            ? Icons.add
                            : Icons.arrow_forward,
                        size: 19,
                      ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  section.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  queued
                      ? l.uiOperationQueued
                      : busy
                      ? l.uiOperationRunning
                      : !section.detected
                      ? l.uiNotInstalled
                      : section.count > 0
                      ? l.uiConnectionCount(section.count)
                      : l.uiNotConfigured,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
