import 'dart:async';
import '../publication/publication_binding_dialog.dart';
import '../drag_select_list.dart';
import '../catalog_selection.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../busy_reason.dart';
import '../l10n/app_localizations.dart';
import '../publication/publication_controller.dart';
import '../publication/publication_panel.dart';
import 'profile_share_sheet.dart';
import 'server_operations_banner.dart';
import 'vpn_controller.dart';
import 'vpn_plan_view.dart';
import 'vpn_strings.dart';
import 'core_config_check.dart';
import '../template_controller.dart';
import '../template_settings.dart';

enum UserSortField { name, creationDate }

/// Clients as the list shows them: enabled first, then disabled, each part
/// ordered by [field]. Names are lower-cased once per client, not once per
/// comparison.
@visibleForTesting
({List<VpnUser> enabled, List<VpnUser> disabled}) sortUsersForDisplay(
  List<VpnUser> users,
  UserSortField field,
  bool ascending,
) {
  final order = <String, int>{
    for (var i = 0; i < users.length; i++) users[i].id: i,
  };
  final names = field == UserSortField.name
      ? {for (final user in users) user.id: user.name.toLowerCase()}
      : const <String, String>{};
  int compare(VpnUser a, VpnUser b) {
    if (field == UserSortField.name) {
      final res = names[a.id]!.compareTo(names[b.id]!);
      if (res != 0) return ascending ? res : -res;
      return order[a.id]!.compareTo(order[b.id]!);
    }
    final res = order[a.id]!.compareTo(order[b.id]!);
    return ascending ? res : -res;
  }

  final visible = users.where((u) => !u.deleted);
  return (
    enabled: visible.where((u) => u.enabled).toList()..sort(compare),
    disabled: visible.where((u) => !u.enabled).toList()..sort(compare),
  );
}

class UsersPage extends StatefulWidget {
  const UsersPage({
    required this.controller,
    required this.serverName,
    required this.exporter,
    required this.motion,
    this.publications,
    this.showAddAction = true,
    this.selection,
    this.onOpenServer,
    super.key,
  });
  final VpnController controller;
  final PublicationController? publications;

  /// Opens a server page from a summary that needs the person there.
  final void Function(String serverId)? onOpenServer;
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
        pickTemplate: controller.pickTemplate,
        existingLogins: () => controller.workspace.users
            .where((u) => !u.deleted)
            .map((u) => u.login),
        // The form stays open until the change is stored: a rejected or
        // failed save is shown in the form instead of being lost.
        save: (next) async {
          await controller.saveUser(next);
          return controller.error;
        },
      ),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, motion),
      ),
    );
    if (result == null) return;
    final (
      VpnUser nextUser,
      PublicationTarget? customTarget,
    ) = result is (VpnUser, PublicationTarget?)
        ? result
        : (result as VpnUser, null);
    if (user == null) AppHaptics.added();
    if (customTarget != null && publications != null) {
      try {
        final preview = await publications.inspectFile(
          nextUser.id,
          customTarget,
        );
        await publications.bindFile(preview);
      } on PublicationFailure catch (e) {
        if (context.mounted) {
          final l = AppLocalizations.of(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(publicationMessage(l, e.issue.name))),
          );
        }
      } catch (e) {
        debugPrint('client_bind_failed type=${e.runtimeType}');
        if (context.mounted) {
          final l = AppLocalizations.of(context);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.publicationBindInvalid)));
        }
      }
    }
    final accessChanged =
        user == null ||
        user.login != nextUser.login ||
        user.enabled != nextUser.enabled;
    if (controller.error == null &&
        accessChanged &&
        controller.workspace.serverIds.isNotEmpty) {
      unawaited(() async {
        try {
          await controller.prepareAndApply(background: true);
          if (customTarget != null && publications != null) {
            await publications.publishUser(nextUser.id, force: true);
          }
        } catch (e) {
          debugPrint('client_save_background_failed type=${e.runtimeType}');
        }
      }());
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
    if (users.isEmpty || !controller.canMutate) return;
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
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.vpnConflict)));
        }
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
  UserSortField _sortField = UserSortField.creationDate;
  bool _sortAscending = true;

  /// The sorted lists for one immutable users list and sort order: busy,
  /// selection and publication notifications rebuild without sorting.
  ({List<VpnUser> enabled, List<VpnUser> disabled})? _sorted;
  (List<VpnUser>, UserSortField, bool)? _sortedFor;
  ({List<VpnUser> enabled, List<VpnUser> disabled}) _sortedUsers(
    List<VpnUser> users,
  ) {
    final cached = _sorted, key = _sortedFor;
    if (cached != null &&
        key != null &&
        identical(key.$1, users) &&
        key.$2 == _sortField &&
        key.$3 == _sortAscending) {
      return cached;
    }
    _sortedFor = (users, _sortField, _sortAscending);
    return _sorted = sortUsersForDisplay(users, _sortField, _sortAscending);
  }

  Future<void> _syncAndPublish(
    BuildContext context, {
    bool force = false,
  }) async {
    if (_syncing || !controller.canMutate) return;
    setState(() => _syncing = true);
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final serverSync = await controller.syncAllServersAndProfiles(
        allowVerifiedSnapshot: !force,
      );
      if (!serverSync.verified) {
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(content: Text(l.vpnSyncServerUnverified)),
          );
        }
        return;
      }
      PublicationBatchResult? batchResult;
      if (publications != null) {
        batchResult = await publications!.forcePublishAll(force: force);
      }
      if (mounted) {
        final activeUsers = controller.workspace.users
            .where((u) => u.enabled && !u.deleted)
            .toList(growable: false);
        final isAuthError =
            publications?.needsAuthorization == true ||
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
                l.vpnSyncAndPublishDone(activeUsers.length, activeUsers.length),
              ),
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        final isAuthError =
            publications?.needsAuthorization == true ||
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

  Widget _buildSyncButton(
    BuildContext context,
    VpnController c,
    AppLocalizations l,
  ) {
    final isSyncingActive = _syncing || (publications?.hasActiveSync == true);
    return Tooltip(
      message: l.vpnSyncAndPublishTooltip,
      child: FilledButton.tonalIcon(
        key: const ValueKey('vpn-sync-and-publish'),
        onPressed: !c.canMutate || isSyncingActive
            ? null
            : () => _syncAndPublish(context, force: false),
        onLongPress: !c.canMutate || isSyncingActive
            ? null
            : () => _syncAndPublish(context, force: true),
        icon: const Icon(Icons.cloud_sync),
        label: Text(l.vpnSyncAndPublish),
      ),
    );
  }

  Widget _buildSyncProgress() {
    final active = _syncing || (publications?.hasActiveSync == true);
    if (!active) return const SizedBox.shrink();
    final total = publications?.activeSyncTotal ?? 0;
    final completed = publications?.activeSyncCompleted ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: LinearProgressIndicator(
        value: total > 0 ? (completed / total).clamp(0.0, 1.0) : null,
      ),
    );
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
      final sorted = _sortedUsers(c.workspace.users);
      final enabledUsers = sorted.enabled, disabledUsers = sorted.disabled;
      final sortedAllUsers = [...enabledUsers, ...disabledUsers];
      final allUsers = sortedAllUsers;
      final protocolSummary = _protocolSummary();
      return DragSelectList(
        selection: selection,
        ids: [for (final u in sortedAllUsers) u.id],
        enabled: c.canMutate,
        builder: (scroll, item) => CustomScrollView(
          controller: scroll,
          key: const PageStorageKey('vpn-users'),
          slivers: [
            SliverPadding(
              padding: AppLayout.screenPadding(context),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverList.list(
                    children: [
                      AppPageIntro(l.uiClientsIntro),
                      ServerOperationsBanner(
                        controller: c,
                        serverName: serverName,
                        onOpenServer: widget.onOpenServer,
                      ),
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
                                  onPressed: !c.canMutate || _syncing
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
                                if (publications != null)
                                  ListenableBuilder(
                                    listenable: publications!,
                                    builder: (context, _) =>
                                        _buildSyncButton(context, c, l),
                                  )
                                else
                                  _buildSyncButton(context, c, l),
                              ],
                            ),
                            if (publications != null)
                              ListenableBuilder(
                                listenable: publications!.changes,
                                builder: (context, _) => _buildSyncProgress(),
                              )
                            else
                              _buildSyncProgress(),
                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                      AppSectionHeading(
                        title: l.vpnUsers,
                        count: allUsers.length,
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
                              available: [for (final u in sortedAllUsers) u.id],
                              prefix: 'vpn-user',
                              busy: !c.canMutate,
                              addLabel: l.vpnAddUser,
                              onAdd: () => UsersPage.edit(
                                context,
                                c,
                                motion,
                                null,
                                publications,
                              ),
                              onDelete: () => UsersPage.deleteSelected(
                                context,
                                c,
                                selection,
                                publications,
                              ),
                            ),
                          ],
                        ),
                      if (allUsers.length > 1 && !selection.active)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.sort,
                                    size: 18,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    l.vpnSortBy,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                ],
                              ),
                              // The field is a segmented choice; the direction is its
                              // own visible button, not a hidden second tap (UI-59).
                              SegmentedButton<UserSortField>(
                                showSelectedIcon: false,
                                segments: [
                                  ButtonSegment(
                                    value: UserSortField.name,
                                    label: Text(
                                      key: const ValueKey('vpn-sort-name'),
                                      l.vpnSortByName,
                                    ),
                                  ),
                                  ButtonSegment(
                                    value: UserSortField.creationDate,
                                    label: Text(
                                      key: const ValueKey('vpn-sort-date'),
                                      l.vpnSortByDate,
                                    ),
                                  ),
                                ],
                                selected: {_sortField},
                                onSelectionChanged: (value) => setState(() {
                                  _sortField = value.single;
                                  _sortAscending = true;
                                }),
                              ),
                              IconButton(
                                key: const ValueKey('vpn-sort-direction'),
                                tooltip: _sortAscending
                                    ? l.vpnSortAscending
                                    : l.vpnSortDescending,
                                onPressed: () => setState(
                                  () => _sortAscending = !_sortAscending,
                                ),
                                icon: Icon(
                                  _sortAscending
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (publications != null)
                        ListenableBuilder(
                          listenable: publications!,
                          builder: (context, _) => VpnPlanView(
                            controller: c,
                            serverName: serverName,
                            showProgress:
                                !_syncing && !publications!.hasActiveSync,
                          ),
                        )
                      else
                        VpnPlanView(
                          controller: c,
                          serverName: serverName,
                          showProgress: !_syncing,
                        ),
                      if (allUsers.isEmpty)
                        AppEmptyState(
                          title: l.vpnNoUsers,
                          icon: Icons.people_outline,
                          message: l.uiClientsEmptyHelp,
                        ),
                    ],
                  ),
                  // A lazy sliver: only the rows in view are built, so a long
                  // client list does not stall the first frame (UI-31).
                  if (allUsers.isNotEmpty)
                    AppAnimatedCollection.sliver(
                      motion: motion,
                      items: {
                        for (var i = 0; i < enabledUsers.length; i++)
                          enabledUsers[i].id: item(
                            enabledUsers[i].id,
                            _UserTile(
                              user: enabledUsers[i],
                              isFirst: i == 0,
                              controller: c,
                              selection: selection,
                              publications: publications,
                              protocolSummary: protocolSummary,
                              motion: motion,
                              onProfile: _profile,
                              isSyncing: _syncing,
                            ),
                          ),
                        if (disabledUsers.isNotEmpty) ...{
                          if (enabledUsers.isNotEmpty)
                            '__disabled_header__': Container(
                              key: const ValueKey(
                                'vpn-disabled-section-header',
                              ),
                              padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant
                                        .withValues(alpha: .55),
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.pause_circle_outline,
                                    size: 18,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outline,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    l.vpnDisabledClients,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const SizedBox(width: 8),
                                  AppBadge(label: '${disabledUsers.length}'),
                                ],
                              ),
                            ),
                          for (var i = 0; i < disabledUsers.length; i++)
                            disabledUsers[i].id: item(
                              disabledUsers[i].id,
                              _UserTile(
                                user: disabledUsers[i],
                                isFirst: i == 0 && enabledUsers.isEmpty,
                                controller: c,
                                selection: selection,
                                publications: publications,
                                protocolSummary: protocolSummary,
                                motion: motion,
                                onProfile: _profile,
                                isSyncing: _syncing,
                              ),
                            ),
                        },
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

typedef _UserTile = UserTile;

@visibleForTesting
class UserTile extends StatelessWidget {
  const UserTile({
    required this.user,
    required this.isFirst,
    required this.controller,
    required this.selection,
    required this.publications,
    required this.protocolSummary,
    required this.motion,
    required this.onProfile,
    this.isSyncing = false,
  });

  final VpnUser user;
  final bool isFirst;
  final VpnController controller;
  final CatalogSelection selection;
  final PublicationController? publications;
  final String protocolSummary;
  final MotionPreference motion;
  final void Function(BuildContext, VpnUser) onProfile;
  final bool isSyncing;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = controller;
    final isSelected = selection.active && selection.ids.contains(user.id);
    return RepaintBoundary(
      child: Padding(
        padding: EdgeInsets.zero,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              // The first row has no divider above it (UI-59).
              top: isFirst
                  ? BorderSide.none
                  : BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
            ),
            color: isSelected
                ? Theme.of(context).colorScheme.secondaryContainer
                : (!user.enabled
                      ? Theme.of(context).colorScheme.surfaceContainerHighest
                            .withValues(alpha: .25)
                      : null),
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
                onChanged: !c.canMutate
                    ? null
                    : (_) => selection.toggle(user.id),
                child: AppIconTile(
                  round: true,
                  key: ValueKey('client-avatar-${user.id}'),
                  text:
                      user.name.trim().characters.firstOrNull?.toUpperCase() ??
                      '?',
                ),
              ),
              // Only the text of a disabled client is muted; its switch
              // stays fully legible and live (no Opacity layer, UI-59).
              title: Text(
                user.name,
                style: user.enabled
                    ? null
                    : Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.enabled ? protocolSummary : l.vpnDisabled),
                  if (publications != null)
                    _PublicationSelector(
                      listenable: publications!.changes,
                      select: () => (
                        publications!.queues[user.id]?['status'],
                        publications!.queues[user.id]?['issue'],
                      ),
                      builder: (context) {
                        final queue = publications!.queues[user.id];
                        if (queue?['status'] == 'error') {
                          return AppNotice(
                            message: publicationMessage(
                              l,
                              queue?['issue'] as String?,
                            ),
                            error: true,
                            margin: const EdgeInsets.only(top: 8),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  if (c.results[user.id]?.hasBlockingErrors == true)
                    AppNotice(
                      message: vpnMessage(
                        l,
                        c.results[user.id]!.diagnostics.first.code,
                      ),
                      error: true,
                      margin: const EdgeInsets.only(top: 8),
                    ),
                  if (!selection.active)
                    CoreConfigCheckAction(controller: c, userId: user.id),
                ],
              ),
              onTap: !c.canMutate
                  ? null
                  : selection.active
                  ? () => selection.toggle(user.id)
                  : () =>
                        UsersPage.edit(context, c, motion, user, publications),
              trailing: selection.active
                  ? null
                  : publications != null
                  ? _PublicationSelector(
                      listenable: publications!.changes,
                      select: () => (
                        publications!.hasActiveSync,
                        publications!.isUserInFlight(user.id),
                        publications!.isUserCompleted(user.id),
                        publications!.isUserFailed(user.id),
                      ),
                      builder: (context) => _buildTrailing(context, c),
                    )
                  : _buildTrailing(context, c),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrailing(BuildContext context, VpnController c) {
    final pub = publications;
    final activeSync = isSyncing || (pub?.hasActiveSync == true);
    final reason = busyReason(
      AppLocalizations.of(context),
      vpn: c,
      syncing: activeSync,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppDisabledReason(
          reason: reason,
          // The switch names its client for screen readers (UI-73).
          child: Semantics(
            label: AppLocalizations.of(context).uiClientAccessFor(user.name),
            child: Switch(
              key: ValueKey('client-toggle-${user.id}'),
              value: user.enabled,
              onChanged: !c.canMutate || activeSync
                  ? null
                  : (val) async {
                      final next = user.copyWith(enabled: val);
                      await c.saveUser(next);
                      if (c.error case final code?) {
                        // The switch snaps back to the stored value; say why.
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                vpnMessage(AppLocalizations.of(context), code),
                              ),
                            ),
                          );
                        }
                        return;
                      }
                      if (c.workspace.serverIds.isNotEmpty) {
                        unawaited(c.prepareAndApply(background: true));
                      }
                    },
            ),
          ),
        ),
        _buildTrailingAction(context, c, activeSync: activeSync),
      ],
    );
  }

  Widget _buildTrailingAction(
    BuildContext context,
    VpnController c, {
    required bool activeSync,
  }) {
    final pub = publications;
    final inFlight = activeSync && pub?.isUserInFlight(user.id) == true;
    final completed = activeSync && pub?.isUserCompleted(user.id) == true;
    final failed = activeSync && pub?.isUserFailed(user.id) == true;
    final l = AppLocalizations.of(context);

    Widget iconWidget;
    if (inFlight) {
      iconWidget = const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (completed) {
      iconWidget = Icon(
        Icons.check_circle,
        color: Theme.of(context).colorScheme.primary,
      );
    } else if (failed) {
      iconWidget = Icon(
        Icons.error_outline,
        color: Theme.of(context).colorScheme.error,
      );
    } else {
      iconWidget = const Icon(Icons.qr_code_2);
    }

    return IconButton(
      key: ValueKey('client-qr-${user.id}'),
      // A disabled button names its reason instead of its action (UI-63).
      tooltip: busyReason(l, vpn: c, syncing: activeSync) ?? l.uiShareProfile,
      onPressed: !c.canMutate || activeSync
          ? null
          : () => onProfile(context, user),
      icon: iconWidget,
    );
  }
}

/// Rebuilds a client row part only when that client's publication state
/// changes: a batch reports progress for one client at a time, and every
/// other row stays as it is.
class _PublicationSelector<T> extends StatefulWidget {
  const _PublicationSelector({
    required this.listenable,
    required this.select,
    required this.builder,
  });
  final Listenable listenable;
  final T Function() select;
  final WidgetBuilder builder;

  @override
  State<_PublicationSelector<T>> createState() =>
      _PublicationSelectorState<T>();
}

class _PublicationSelectorState<T> extends State<_PublicationSelector<T>> {
  late T _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.select();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(_PublicationSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _selected = widget.select();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final next = widget.select();
    if (next != _selected) setState(() => _selected = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class _UserForm extends StatefulWidget {
  const _UserForm({
    required this.existingLogins,
    required this.save,
    this.user,
    this.publications,
    this.pickTemplate,
  });
  final Iterable<String> Function() existingLogins;

  /// Stores the client and returns the error code, or null on success.
  final Future<String?> Function(VpnUser) save;
  final VpnUser? user;
  final PublicationController? publications;
  final Future<ImportedTemplate?> Function()? pickTemplate;
  @override
  State<_UserForm> createState() => _UserFormState();
}

class _UserFormState extends State<_UserForm> {
  late final name = TextEditingController(text: widget.user?.name ?? '');
  late final customLink = TextEditingController();
  late bool enabled = widget.user?.enabled ?? true;
  late bool individualTemplate = widget.user?.baseTemplate != null;
  late final template = TemplateController(
    source: widget.user?.baseTemplate ?? '',
    previewTemplate: previewInBackground,
    pickTemplate: widget.pickTemplate,
  )..importedName = widget.user?.baseTemplateName;
  bool picking = false, saving = false;
  String? error, saveError;
  @override
  void dispose() {
    name.dispose();
    customLink.dispose();
    template.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // While the client is being stored the form cannot be dismissed: the
    // follow-up (file binding, sending to servers) needs its result.
    return PopScope(
      canPop: !saving,
      child: AppFormDialog(
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
              const Divider(),
              SwitchListTile(
                key: const ValueKey('vpn-user-individual-template'),
                contentPadding: EdgeInsets.zero,
                title: Text(l.vpnIndividualTemplate),
                subtitle: Text(
                  individualTemplate
                      ? l.vpnIndividualTemplateHelp
                      : l.vpnSharedTemplateHelp,
                ),
                value: individualTemplate,
                onChanged: (value) =>
                    setState(() => individualTemplate = value),
              ),
              if (individualTemplate)
                TemplateSettings(
                  controller: template,
                  emptyMessage: l.vpnIndividualTemplateRequired,
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
                      onPressed:
                          picking || widget.publications?.pickerReady != true
                          ? null
                          : () async {
                              setState(() => picking = true);
                              try {
                                final target = await widget.publications!
                                    .pickFile();
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
                  listenable: Listenable.merge([
                    name,
                    template,
                    widget.publications!,
                  ]),
                  builder: (context, _) {
                    final c = widget.publications!;
                    final unchanged =
                        name.text.trim() == widget.user!.name &&
                        enabled == widget.user!.enabled &&
                        (individualTemplate ? template.source : null) ==
                            widget.user!.baseTemplate;
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
                                padding: const EdgeInsets.only(
                                  top: 4,
                                  bottom: 8,
                                ),
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
              if (error != null)
                Text(
                  error == 'template_required'
                      ? l.vpnIndividualTemplateRequired
                      : l.vpnInvalid,
                ),
              if (saveError case final code?)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: AppNotice(
                      key: const ValueKey('vpn-user-save-error'),
                      message: vpnMessage(l, code),
                      error: true,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: Text(l.sshCancel),
          ),
          FilledButton(
            key: const ValueKey('vpn-user-save'),
            onPressed: saving ? null : _submit,
            child: Text(l.vpnSave),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (template.importing || template.busy) return;
    if (individualTemplate && template.source.trim().isEmpty) {
      setState(() => error = 'template_required');
      return;
    }
    final VpnUser user;
    PublicationTarget? target;
    try {
      if (widget.user == null && customLink.text.trim().isNotEmpty) {
        target = PublicationTarget.parse(customLink.text.trim());
      }
      user = VpnUser(
        id: widget.user?.id ?? newVpnId(),
        login:
            widget.user?.login ??
            generateClientLogin(name.text.trim(), widget.existingLogins()),
        name: name.text.trim(),
        enabled: enabled,
        baseTemplate: individualTemplate ? template.source : null,
        baseTemplateName: individualTemplate ? template.importedName : null,
      );
    } catch (_) {
      setState(() => error = 'invalid');
      return;
    }
    setState(() {
      error = null;
      saveError = null;
      saving = true;
    });
    final issue = await widget.save(user);
    if (!mounted) return;
    if (issue != null) {
      setState(() {
        saving = false;
        saveError = issue;
      });
      return;
    }
    Navigator.pop(context, (user, target));
  }
}
