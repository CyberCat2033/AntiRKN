import '../publication/publication_binding_dialog.dart';
import '../drag_select_list.dart';
import '../catalog_selection.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../publication/publication_controller.dart';
import '../publication/publication_panel.dart';
import 'profile_share_sheet.dart';
import 'vpn_controller.dart';
import 'vpn_plan_view.dart';
import 'vpn_strings.dart';

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
      builder: (_) => _UserForm(user: user, publications: publications),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, motion),
      ),
    );
    if (result == null) return;
    await controller.saveUser(result as VpnUser);
    if (controller.error == null && controller.workspace.serverIds.isNotEmpty) {
      await controller.prepare();
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
  @override
  void dispose() {
    ownSelection.dispose();
    super.dispose();
  }

  Future<void> _profile(BuildContext context, VpnUser user) async {
    await controller.refreshProfiles();
    if (!context.mounted) return;
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
        builder: (_) => Dialog(child: content),
      );
    }
  }

  bool _needsAttention(String id) {
    final c = controller,
        record = c.workspace.servers[id],
        job = c.currentJob(id);
    return record != null &&
        (record['error'] != null ||
            record['pending'] != null ||
            c.needsRestoreReview(id) ||
            c.observesOperation(id) ||
            job != null &&
                (!job.terminal ||
                    [
                      'failed',
                      'partially_applied',
                      'needs_attention',
                    ].contains(job.status)) ||
            record['authorizedPayload'] != null &&
                record['authorizedPayload'] != record['appliedPayload']);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, selection]),
    builder: (context, _) {
      final c = controller, l = AppLocalizations.of(context);
      return DragSelectList(
        selection: selection,
        ids: c.workspace.users
            .where((u) => !u.deleted)
            .map((u) => u.id)
            .toList(),
        enabled: !c.busy && c.loaded,
        builder: (scroll, item) => ListView(
          controller: scroll,
          key: const PageStorageKey('vpn-users'),
          padding: AppLayout.screenPadding(context),
          children: [
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
                    available: c.workspace.users
                        .where((u) => !u.deleted)
                        .map((u) => u.id),
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
            if (!c.workspace.users.any((u) => !u.deleted)) Text(l.vpnNoUsers),
            for (final user in c.workspace.users.where((u) => !u.deleted))
              item(
                user.id,
                Padding(
                  padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
                  child: Card.filled(
                    child: ListTile(
                      key: ValueKey('client-${user.id}'),
                      selected:
                          selection.active && selection.ids.contains(user.id),
                      leading: selection.active
                          ? Checkbox(
                              key: ValueKey('client-select-${user.id}'),
                              value: selection.ids.contains(user.id),
                              onChanged: c.busy
                                  ? null
                                  : (_) => selection.toggle(user.id),
                            )
                          : null,
                      title: Text(user.name),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${user.login} · ${user.enabled ? l.vpnEnabled : l.vpnDisabled}',
                          ),
                          if (publications != null)
                            UserPublicationView(
                              controller: publications!,
                              userId: user.id,
                            ),
                          if (c.results[user.id]?.hasBlockingErrors == true)
                            Text(
                              vpnMessage(
                                l,
                                c.results[user.id]!.diagnostics.first.code,
                              ),
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
                              tooltip: l.vpnProfile,
                              onPressed: c.busy
                                  ? null
                                  : () => _profile(context, user),
                              icon: const Icon(Icons.ios_share_outlined),
                            ),
                    ),
                  ),
                ),
              ),
            for (final user in c.pendingDeletions)
              AppExpansionTile(
                key: PageStorageKey('client-deletion-${user.id}'),
                leading: const Icon(Icons.person_remove_outlined),
                title: Text(user.name),
                subtitle: Text(
                  user.revocationComplete
                      ? l.vpnDeleteFilePending
                      : l.vpnRevocationPending,
                ),
                children: [
                  for (final entry
                      in (user.deletion!['targets'] as Map).entries)
                    ListTile(
                      title: Text(serverName(vpnServerId(entry.key as String))),
                      subtitle: Text(
                        entry.value['status'] == 'revoked'
                            ? l.vpnAccessRevoked
                            : entry.value['error'] != null
                            ? vpnMessage(l, entry.value['error'] as String)
                            : l.vpnRevocationPending,
                      ),
                    ),
                  if (user.deletion!['file']?['error'] case final String issue)
                    Padding(
                      padding: const EdgeInsets.all(AppLayout.gap),
                      child: Text(publicationMessage(l, issue)),
                    ),
                  TextButton(
                    key: ValueKey('client-deletion-retry-${user.id}'),
                    onPressed: c.busy ? null : () => c.retryDeletion(user.id),
                    child: Text(
                      c.ownsDeletion(user)
                          ? l.runnerRetry
                          : l.operationTakeOver,
                    ),
                  ),
                ],
              ),
            for (final id in c.workspace.serverIds.where(_needsAttention))
              AppExpansionTile(
                key: PageStorageKey('vpn-operation-$id'),
                leading: const Icon(Icons.pending_actions),
                title: Text(serverName(vpnServerId(id))),
                subtitle: Text(
                  c.workspace.servers[id]?['error'] != null
                      ? vpnMessage(
                          l,
                          c.workspace.servers[id]!['error'] as String,
                        )
                      : l.uiOperationPending,
                ),
                children: [VpnJobView(controller: c, serverId: id)],
              ),
          ],
        ),
      );
    },
  );
}

class _UserForm extends StatefulWidget {
  const _UserForm({this.user, this.publications});
  final VpnUser? user;
  final PublicationController? publications;
  @override
  State<_UserForm> createState() => _UserFormState();
}

class _UserFormState extends State<_UserForm> {
  late final login = TextEditingController(text: widget.user?.login ?? '');
  late final name = TextEditingController(text: widget.user?.name ?? '');
  late bool enabled = widget.user?.enabled ?? true;
  late bool automaticName =
      widget.user == null || widget.user!.name == widget.user!.login;
  String? error;
  @override
  void dispose() {
    login.dispose();
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.user == null ? l.vpnAddUser : l.vpnEdit),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('vpn-user-login'),
              controller: login,
              onChanged: (value) {
                if (automaticName) name.text = value.trim();
              },
              autocorrect: false,
              decoration: InputDecoration(labelText: l.vpnLogin),
            ),
            const SizedBox(height: AppLayout.gap),
            TextField(
              key: const ValueKey('vpn-user-name'),
              controller: name,
              onChanged: (value) => automaticName =
                  value.trim().isEmpty || value.trim() == login.text.trim(),
              decoration: InputDecoration(labelText: l.vpnName),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.vpnEnabled),
              value: enabled,
              onChanged: (v) => setState(() => enabled = v),
            ),
            if (widget.user != null && widget.publications != null)
              ListenableBuilder(
                listenable: Listenable.merge([
                  login,
                  name,
                  widget.publications!,
                ]),
                builder: (context, _) {
                  final c = widget.publications!;
                  final unchanged =
                      login.text.trim() == widget.user!.login &&
                      name.text.trim() == widget.user!.name &&
                      enabled == widget.user!.enabled;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(),
                      if (c.results[widget.user!.id]?['fileId']
                          case final String id)
                        SelectableText(id),
                      UserPublicationView(
                        controller: c,
                        userId: widget.user!.id,
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
              final user = VpnUser(
                id: widget.user?.id ?? newVpnId(),
                login: login.text.trim(),
                name: name.text.trim().isEmpty
                    ? login.text.trim()
                    : name.text.trim(),
                enabled: enabled,
              );
              Navigator.pop(context, user);
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
