import '../publication/publication_binding_dialog.dart';
import '../drag_select_list.dart';
import '../catalog_selection.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../runner/runner_panel.dart';
import '../publication/publication_controller.dart';
import '../publication/publication_panel.dart';
import 'profile_share_sheet.dart';
import 'client_deletion_panel.dart';
import 'vpn_controller.dart';
import 'vpn_plan_view.dart';
import 'vpn_strings.dart';
import 'core_config_check.dart';

class UsersPage extends StatefulWidget {
  const UsersPage({
    required this.controller,
    required this.serverName,
    required this.exporter,
    required this.motion,
    this.publications,
    this.showAddAction = true,
    this.selection,
    super.key,
  });
  final VpnController controller;
  final PublicationController? publications;
  final String Function(String) serverName;
  final ProfileExporter exporter;
  final MotionPreference motion;
  final bool showAddAction;
  final CatalogSelection? selection;
  @override
  State<UsersPage> createState() => _UsersPageState();

  static Future<void> edit(
    BuildContext context,
    VpnController controller,
    MotionPreference motion, [
    VpnUser? user,
    PublicationController? publications,
  ]) async {
    final result = await showDialog<Object>(
      context: context,
      builder: (_) => _UserForm(
        user: user,
        publications: publications,
        existingLogins: () => controller.workspace.users
            .where((u) => !u.deleted)
            .map((u) => u.login),
      ),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, motion),
      ),
    );
    if (result == null) return;
    final (VpnUser nextUser, PublicationTarget? customTarget) =
        result is (VpnUser, PublicationTarget?)
            ? result
            : (result as VpnUser, null);
    await controller.saveUser(nextUser);
    if (user == null && controller.error == null) AppHaptics.added();
    if (customTarget != null &&
        publications != null &&
        controller.error == null) {
      try {
        final preview =
            await publications.inspectFile(nextUser.id, customTarget);
        await publications.bindFile(preview);
      } catch (_) {}
    }
    if (controller.error == null && controller.workspace.serverIds.isNotEmpty) {
      await controller.prepareAndApply();
      if (customTarget != null && publications != null) {
        await publications.publishUser(nextUser.id, force: true);
      }
    }
  }

  static Future<void> deleteSelected(
    BuildContext context,
    VpnController controller,
    CatalogSelection selection,
    PublicationController? publications,
  ) async {
    final users = controller.workspace.users
        .where((u) => !u.deleted && selection.ids.contains(u.id))
        .toList();
    if (users.isEmpty || controller.busy) return;
    final l = AppLocalizations.of(context);
    final files = <String, Map<String, dynamic>>{
      for (final user in users)
        user.id: ?publications?.deletionFileFor(user.id),
    };
    var deleteFiles = false;
    final accepted = await confirmCatalogDeletion(
      context,
      explanation: l.vpnDeleteExplanation,
      names: users.map((u) => u.name).toList(),
      confirmKey: 'client-delete-confirm',
      extra: files.isEmpty
          ? null
          : StatefulBuilder(
              builder: (context, update) => CheckboxListTile(
                key: const ValueKey('client-delete-file'),
                contentPadding: EdgeInsets.zero,
                value: deleteFiles,
                onChanged: (value) => update(() => deleteFiles = value!),
                title: Text(l.vpnDeleteFile),
                subtitle: Text(
                  [
                    for (final user in users)
                      if (files.containsKey(user.id))
                        '${user.name}: ${files[user.id]!['fileId']}',
                  ].join('\n'),
                ),
              ),
            ),
    );
    if (!accepted || !context.mounted) return;
    await publications?.suspend();
    try {
      // Check every approved destination again before committing tombstones.
      if (deleteFiles &&
          files.entries.any(
            (e) =>
                canonicalJson(publications?.deletionFileFor(e.key)) !=
                canonicalJson(e.value),
          )) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.vpnConflict)));
        return;
      }
      await controller.deleteUsers(
        users,
        files: deleteFiles ? files : const {},
      );
      if (controller.error == null) selection.exit();
    } finally {
      publications?.resume();
    }
  }
}

class _UsersPageState extends State<UsersPage> {
  final ownSelection = CatalogSelection();
  CatalogSelection get selection => widget.selection ?? ownSelection;
  VpnController get controller => widget.controller;
  PublicationController? get publications => widget.publications;
  ProfileExporter get exporter => widget.exporter;
  MotionPreference get motion => widget.motion;
  bool get showAddAction => widget.showAddAction;
  String Function(String) get serverName => widget.serverName;
  bool _syncing = false;

  Future<void> _syncAndPublish(BuildContext context, {bool force = false}) async {
    if (_syncing || controller.busy || !controller.loaded) return;
    setState(() => _syncing = true);
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await controller.syncAllServersAndProfiles();
      PublicationBatchResult? batchResult;
      if (publications != null) {
        batchResult = await publications!.forcePublishAll(force: force);
      }
      if (mounted) {
        final activeUsers = controller.workspace.users
            .where((u) => u.enabled && !u.deleted)
            .toList(growable: false);
        final isAuthError = publications?.needsAuthorization == true ||
            publications?.accountError == GoogleAccountIssue.reauthorize ||
            publications?.error == PublicationIssue.unauthorized;
        if (isAuthError) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(l.googleReauthorize),
              action: SnackBarAction(
                label: l.googleSignIn,
                onPressed: () => publications?.authorize(),
              ),
            ),
          );
        } else if (batchResult != null) {
          if (batchResult.failed > 0) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  l.vpnSyncAndPublishWithErrors(
                    batchResult.uploaded,
                    batchResult.failed,
                    activeUsers.length,
                  ),
                ),
              ),
            );
          } else if (batchResult.uploaded == 0 && batchResult.upToDate > 0) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  l.vpnSyncAndPublishUpToDate(batchResult.upToDate),
                ),
              ),
            );
          } else if (batchResult.upToDate > 0 && batchResult.uploaded > 0) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  l.vpnSyncAndPublishPartial(
                    batchResult.uploaded,
                    activeUsers.length,
                    batchResult.upToDate,
                  ),
                ),
              ),
            );
          } else {
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  l.vpnSyncAndPublishDone(
                    batchResult.uploaded,
                    activeUsers.length,
                  ),
                ),
              ),
            );
          }
        } else {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                l.vpnSyncAndPublishDone(
                  activeUsers.length,
                  activeUsers.length,
                ),
              ),
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        final isAuthError = publications?.needsAuthorization == true ||
            publications?.accountError == GoogleAccountIssue.reauthorize ||
            publications?.error == PublicationIssue.unauthorized;
        if (isAuthError) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(l.googleReauthorize),
              action: SnackBarAction(
                label: l.googleSignIn,
                onPressed: () => publications?.authorize(),
              ),
            ),
          );
        } else {
          messenger.showSnackBar(
            SnackBar(content: Text(l.vpnSyncAndPublishFailed)),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  void dispose() {
    ownSelection.dispose();
    super.dispose();
  }

  Future<void> _profile(BuildContext context, VpnUser user) async {
    final content = ProfileShareSheet(
      controller: controller,
      user: user,
      exporter: exporter,
      publications: publications,
    );
    if (MediaQuery.sizeOf(context).width < AppLayout.compact) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        sheetAnimationStyle: AnimationStyle(
          duration: AppMotion.duration(context, motion),
        ),
        builder: (_) => content,
      );
    } else {
      await showDialog<void>(
        context: context,
        animationStyle: AnimationStyle(
          duration: AppMotion.duration(context, motion),
        ),
        builder: (_) => Dialog(clipBehavior: Clip.antiAlias, child: content),
      );
    }
  }

  String _protocolSummary() {
    final c = controller, l = AppLocalizations.of(context);
    final names = <String>[
      if (c.workspace.inbounds.any(
        (r) => !r.deleted && r.enabled && r.spec['internal'] != true,
      ))
        'VLESS',
      if (c.workspace.awgInterfaces.any((r) => !r.deleted && r.enabled))
        'AmneziaWG',
      if (c.workspace.ttEndpoints.any((r) => !r.deleted && r.enabled))
        'TrustTunnel',
    ];
    return names.isEmpty ? l.uiNoClientAccess : names.join(' · ');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, selection]),
    builder: (context, _) {
      final c = controller, l = AppLocalizations.of(context);
      final activeUsers = c.workspace.users
          .where((u) => !u.deleted)
          .toList(growable: false);
      final firstUserId = activeUsers.firstOrNull?.id;
      final protocolSummary = _protocolSummary();
      return DragSelectList(
        selection: selection,
        ids: [for (final u in activeUsers) u.id],
        enabled: !c.busy && c.loaded,
        builder: (scroll, item) => ListView(
          controller: scroll,
          key: const PageStorageKey('vpn-users'),
          padding: AppLayout.screenPadding(context),
          children: [
            AppPageIntro(l.uiClientsIntro),
            CatalogNormalContent(
              selection: selection,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: c.busy || !c.loaded || _syncing
                            ? null
                            : () => UsersPage.edit(
                                context,
                                c,
                                motion,
                                null,
                                publications,
                              ),
                        icon: const Icon(Icons.add),
                        label: Text(l.vpnAddUser),
                      ),
                      Tooltip(
                        message: l.vpnSyncAndPublishTooltip,
                        child: FilledButton.tonalIcon(
                          key: const ValueKey('vpn-sync-and-publish'),
                          onPressed: c.busy || !c.loaded || _syncing
                              ? null
                              : () => _syncAndPublish(context, force: false),
                          onLongPress: c.busy || !c.loaded || _syncing
                              ? null
                              : () => _syncAndPublish(context, force: true),
                          icon: _syncing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.cloud_sync),
                          label: Text(l.vpnSyncAndPublish),
                        ),
                      ),
                    ],
                  ),
                  if (_syncing) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                  const SizedBox(height: 20),
                ],
              ),
            ),
            AppSectionHeading(
              title: l.vpnUsers,
              count: activeUsers.length,
            ),
            if (showAddAction)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      selection.active
                          ? l.catalogSelected(selection.ids.length)
                          : l.vpnUsers,
                    ),
                  ),
                  CatalogActions(
                    selection: selection,
                    available: [for (final u in activeUsers) u.id],
                    prefix: 'vpn-user',
                    busy: c.busy || !c.loaded,
                    addLabel: l.vpnAddUser,
                    onAdd: () =>
                        UsersPage.edit(context, c, motion, null, publications),
                    onDelete: () => UsersPage.deleteSelected(
                      context,
                      c,
                      selection,
                      publications,
                    ),
                  ),
                ],
              ),
            VpnPlanView(controller: c, serverName: serverName),
            if (activeUsers.isEmpty)
              AppEmptyState(
                title: l.vpnNoUsers,
                icon: Icons.people_outline,
                message: l.uiClientsEmptyHelp,
              ),
            Card.filled(
              child: AppAnimatedCollection(
                motion: motion,
                items: {
                  for (final user in activeUsers)
                    user.id: item(
                      user.id,
                      _UserTile(
                        user: user,
                        isFirst: user.id == firstUserId,
                        controller: c,
                        selection: selection,
                        publications: publications,
                        protocolSummary: protocolSummary,
                        motion: motion,
                        onProfile: _profile,
                      ),
                    ),
                },
              ),
            ),
            ClientDeletionPanel(controller: c, serverName: serverName),
            _AttentionServersSection(
              controller: c,
              serverName: serverName,
            ),
          ],
        ),
      );
    },
  );
}

class _UserTile extends StatelessWidget {
  const _UserTile({
    required this.user,
    required this.isFirst,
    required this.controller,
    required this.selection,
    required this.publications,
    required this.protocolSummary,
    required this.motion,
    required this.onProfile,
  });

  final VpnUser user;
  final bool isFirst;
  final VpnController controller;
  final CatalogSelection selection;
  final PublicationController? publications;
  final String protocolSummary;
  final MotionPreference motion;
  final void Function(BuildContext, VpnUser) onProfile;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = controller;
    final isSelected = selection.active && selection.ids.contains(user.id);
    return Padding(
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: isFirst
                  ? Colors.transparent
                  : Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: .55),
            ),
          ),
          color: isSelected
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          clipBehavior: Clip.hardEdge,
          child: ListTile(
            key: ValueKey('client-${user.id}'),
            leading: CatalogSelectionLeading(
              active: selection.active,
              selected: isSelected,
              checkboxKey: ValueKey('client-select-${user.id}'),
              onChanged: c.busy ? null : (_) => selection.toggle(user.id),
              child: AppIconTile(
                round: true,
                key: ValueKey('client-avatar-${user.id}'),
                text: user.name.trim().characters.firstOrNull?.toUpperCase() ?? '?',
              ),
            ),
            title: Text(user.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.enabled ? protocolSummary : l.vpnDisabled,
                ),
                if (publications != null)
                  ListenableBuilder(
                    listenable: publications!,
                    builder: (context, _) {
                      final queue = publications!.queues[user.id];
                      if (queue?['status'] == 'error') {
                        return Text(
                          publicationMessage(
                            l,
                            queue?['issue'] as String?,
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                if (c.results[user.id]?.hasBlockingErrors == true)
                  Text(
                    vpnMessage(
                      l,
                      c.results[user.id]!.diagnostics.first.code,
                    ),
                  ),
                if (!selection.active)
                  CoreConfigCheckAction(
                    controller: c,
                    userId: user.id,
                  ),
              ],
            ),
            onTap: c.busy
                ? null
                : selection.active
                ? () => selection.toggle(user.id)
                : () => UsersPage.edit(
                    context,
                    c,
                    motion,
                    user,
                    publications,
                  ),
            trailing: selection.active
                ? null
                : IconButton(
                    key: ValueKey('client-qr-${user.id}'),
                    tooltip: l.uiShareProfile,
                    onPressed: c.busy ? null : () => onProfile(context, user),
                    icon: const Icon(Icons.qr_code_2),
                  ),
          ),
        ),
      ),
    );
  }
}

class _AttentionServersSection extends StatelessWidget {
  const _AttentionServersSection({
    required this.controller,
    required this.serverName,
  });

  final VpnController controller;
  final String Function(String) serverName;

  static bool needsAttention(VpnController c, String id) {
    final record = c.workspace.servers[id],
        job = c.currentJob(id);
    // A shared job is observed automatically. Only an actual failure needs
    // attention here; a restored pending marker alone is not a warning.
    if (c.observesOperation(id)) {
      return c.observationErrors[id] != null ||
          job != null &&
              [
                'failed',
                'partially_applied',
                'needs_attention',
              ].contains(job.status);
    }
    return record != null &&
        record['forgottenLocallyAt'] == null &&
        (record['error'] != null ||
            record['pending'] != null &&
                (!c.observesOperation(id) || job?.terminal != true) ||
            c.needsRestoreReview(id) && !c.observesOperation(id) ||
            c.observationErrors[id] != null ||
            job != null &&
                (!job.terminal ||
                    [
                      'failed',
                      'partially_applied',
                      'needs_attention',
                    ].contains(job.status)) ||
            !c.observesOperation(id) &&
                record['paused'] != true &&
                record['authorizedPayload'] != null &&
                record['authorizedPayload'] != record['appliedPayload']);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final attentionIds = controller.workspace.serverIds
        .where((id) => needsAttention(controller, id))
        .toList(growable: false);
    if (attentionIds.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in attentionIds)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card.filled(
              child: ListTile(
                leading: const AppIconTile(icon: Icons.pending_actions),
                title: Text(serverName(vpnServerId(id))),
                subtitle: Text(
                  controller.workspace.servers[id]?['error'] != null
                      ? vpnMessage(
                          l,
                          controller.workspace.servers[id]!['error'] as String,
                        )
                      : controller.currentJob(id) != null
                      ? runnerStateLabel(l, controller.currentJob(id)!.status)
                      : l.uiOperationPending,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showAppDetails(
                  context,
                  title: serverName(vpnServerId(id)),
                  children: [
                    ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) =>
                          VpnJobView(controller: controller, serverId: id),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _UserForm extends StatefulWidget {
  const _UserForm({required this.existingLogins, this.user, this.publications});
  final Iterable<String> Function() existingLogins;
  final VpnUser? user;
  final PublicationController? publications;
  @override
  State<_UserForm> createState() => _UserFormState();
}

class _UserFormState extends State<_UserForm> {
  late final name = TextEditingController(text: widget.user?.name ?? '');
  late final customLink = TextEditingController();
  late bool enabled = widget.user?.enabled ?? true;
  bool picking = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    customLink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AppFormDialog(
      title: Text(widget.user == null ? l.vpnAddUser : l.vpnEdit),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('vpn-user-name'),
              controller: name,
              decoration: InputDecoration(labelText: l.vpnName),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.vpnEnabled),
              value: enabled,
              onChanged: (v) {
                setState(() => enabled = v);
              },
            ),
            if (widget.user == null &&
                widget.publications?.settings?.enabled == true &&
                widget.publications?.settings?.folderReady == true) ...[
              const Divider(),
              TextField(
                key: const ValueKey('vpn-user-custom-link'),
                controller: customLink,
                decoration: InputDecoration(
                  labelText: l.publicationFileLink,
                  hintText: 'https://drive.google.com/...',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('vpn-user-pick-file'),
                    onPressed: picking ||
                            widget.publications?.pickerReady != true
                        ? null
                        : () async {
                            setState(() => picking = true);
                            try {
                              final target =
                                  await widget.publications!.pickFile();
                              if (target != null && mounted) {
                                customLink.text = target.resourceKey == null
                                    ? target.fileId
                                    : Uri.https('drive.google.com', '/uc', {
                                        'id': target.fileId,
                                        'resourcekey': target.resourceKey!,
                                      }).toString();
                              }
                            } catch (_) {}
                            if (mounted) setState(() => picking = false);
                          },
                    icon: const Icon(Icons.folder_open),
                    label: Text(l.publicationPickFile),
                  ),
                ],
              ),
            ],
            if (widget.user != null && widget.publications != null)
              ListenableBuilder(
                listenable: Listenable.merge([name, widget.publications!]),
                builder: (context, _) {
                  final c = widget.publications!;
                  final unchanged =
                      name.text.trim() == widget.user!.name &&
                      enabled == widget.user!.enabled;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(),

                      UserPublicationView(
                        controller: c,
                        userId: widget.user!.id,
                      ),
                      Builder(
                        builder: (context) {
                          final fileId =
                              c.bindings[widget.user!.id]?['fileId'] ??
                              c.results[widget.user!.id]?['fileId'];
                          if (fileId is String && fileId.isNotEmpty) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 4, bottom: 8),
                              child: Text(
                                '${l.publicationFileLink}: $fileId',
                                style: Theme.of(context).textTheme.bodySmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('client-change-file'),
                        onPressed:
                            !unchanged ||
                                c.editing ||
                                !enabled ||
                                c.settings?.folderReady != true ||
                                c.settings?.enabled != true
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                builder: (_) => PublicationBindingDialog(
                                  controller: c,
                                  user: widget.user!,
                                ),
                              ),
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(l.publicationChangeFile),
                      ),
                      if (c.settings?.folderReady != true ||
                          c.settings?.enabled != true)
                        Text(l.publicationBindSetupHelp),
                      if (!unchanged) Text(l.publicationSaveClientFirst),
                    ],
                  );
                },
              ),
            if (error != null) Text(l.vpnInvalid),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.runnerNotNow),
        ),
        FilledButton(
          key: const ValueKey('vpn-user-save'),
          onPressed: () {
            try {
              PublicationTarget? target;
              if (widget.user == null &&
                  customLink.text.trim().isNotEmpty) {
                target = PublicationTarget.parse(customLink.text.trim());
              }
              final user = VpnUser(
                id: widget.user?.id ?? newVpnId(),
                login:
                    widget.user?.login ??
                    generateClientLogin(
                      name.text.trim(),
                      widget.existingLogins(),
                    ),
                name: name.text.trim(),
                enabled: enabled,
              );
              Navigator.pop(context, (user, target));
            } catch (_) {
              setState(() => error = 'invalid');
            }
          },
          child: Text(l.vpnSave),
        ),
      ],
    );
  }
}
