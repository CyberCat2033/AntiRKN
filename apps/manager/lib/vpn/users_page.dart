import 'dart:async';
import '../publication/publication_binding_dialog.dart';
import '../drag_select_list.dart';
import '../catalog_selection.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../busy_reason.dart';
import '../l10n/app_localizations.dart';
import '../publication/publication_controller.dart';
import '../publication/publication_panel.dart';
import 'profile_share_sheet.dart';
import 'server_operations_banner.dart';
import 'vpn_controller.dart';
import 'vpn_plan_view.dart';
import 'client_traffic_controller.dart';
import 'client_traffic_view.dart';
import 'vpn_strings.dart';
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
    this.traffic,
    this.title,
    this.selection,
    this.onOpenServer,
    super.key,
  });
  final VpnController controller;
  final PublicationController? publications;

  /// Per-client traffic for the profile sheet; null: not shown.
  final ClientTrafficController? traffic;

  /// Opens a server page from a summary that needs the person there.
  final void Function(String serverId)? onOpenServer;
  final String Function(String) serverName;
  final ProfileExporter exporter;
  final MotionPreference motion;

  /// The page title; "Clients" when not given.
  final String? title;
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
        coreValidator: controller.templateValidator,
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
  String Function(String) get serverName => widget.serverName;
  bool _syncing = false;
  UserSortField _sortField = UserSortField.creationDate;
  bool _sortAscending = true;

  /// Disabled clients are folded away until asked for.
  bool _disabledOpen = false;

  @override
  void initState() {
    super.initState();
    // The cached counters only: reading the servers waits for the sheet.
    unawaited(widget.traffic?.load());
  }

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

  static const _sortOptions = [
    (UserSortField.creationDate, true),
    (UserSortField.creationDate, false),
    (UserSortField.name, true),
    (UserSortField.name, false),
  ];

  static String _sortLabel(
    AppLocalizations l,
    UserSortField field,
    bool ascending,
  ) => switch ((field, ascending)) {
    (UserSortField.creationDate, true) => l.vpnSortOldest,
    (UserSortField.creationDate, false) => l.vpnSortNewest,
    (UserSortField.name, true) => l.vpnSortNameAz,
    (UserSortField.name, false) => l.vpnSortNameZa,
  };

  Widget _sortMenu(AppLocalizations l) => AppMenuButton(
    buttonKey: const ValueKey('vpn-sort-menu'),
    icon: Icons.sort,
    tooltip: l.vpnSortTooltip,
    label: _sortLabel(l, _sortField, _sortAscending),
    children: [
      for (final (field, ascending) in _sortOptions)
        AppMenuItem(
          key: ValueKey('vpn-sort-${field.name}-${ascending ? 'asc' : 'desc'}'),
          label: _sortLabel(l, field, ascending),
          selected: field == _sortField && ascending == _sortAscending,
          onPressed: () => setState(() {
            _sortField = field;
            _sortAscending = ascending;
          }),
        ),
    ],
  );

  /// Checking the servers and publishing are rare and slow: they live in
  /// the page menu, the full check as its own item instead of a long press.
  Widget _menu(BuildContext context, VpnController c, AppLocalizations l) {
    final busy =
        !c.canMutate || _syncing || (publications?.hasActiveSync == true);
    return AppMoreMenu(
      buttonKey: const ValueKey('vpn-clients-menu'),
      tooltip: l.vpnClientsMenu,
      children: [
        AppMenuItem(
          key: const ValueKey('vpn-sync-and-publish'),
          icon: Icons.cloud_sync_outlined,
          label: l.vpnSyncAndPublish,
          onPressed: busy ? null : () => _syncAndPublish(context),
        ),
        AppMenuItem(
          key: const ValueKey('vpn-sync-force'),
          icon: Icons.sync,
          label: l.vpnSyncForce,
          onPressed: busy ? null : () => _syncAndPublish(context, force: true),
        ),
      ],
    );
  }

  void _add(BuildContext context) =>
      UsersPage.edit(context, controller, motion, null, publications);

  /// The add action is a button in the header where it fits, otherwise a
  /// floating button over the list (compact width or large text).
  bool _addInHeader(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= AppLayout.compact &&
      MediaQuery.textScalerOf(context).scale(14) <= 21;

  Widget _header(
    BuildContext context,
    VpnController c,
    AppLocalizations l,
    List<String> ids,
  ) {
    return AppPageHeader(
      title: CatalogTitle(
        selection: selection,
        title: widget.title ?? l.vpnUsers,
      ),
      actions: [
        if (!selection.active && _addInHeader(context)) ...[
          FilledButton.icon(
            key: const ValueKey('vpn-user-add'),
            onPressed: !c.canMutate || _syncing ? null : () => _add(context),
            icon: const Icon(Icons.add),
            label: Text(l.vpnAddUser),
          ),
          const SizedBox(width: AppLayout.smallGap),
        ],
        CatalogActions(
          selection: selection,
          available: ids,
          prefix: 'vpn-user',
          busy: !c.canMutate,
          onDelete: () =>
              UsersPage.deleteSelected(context, c, selection, publications),
        ),
        if (!selection.active)
          if (publications != null)
            ListenableBuilder(
              listenable: publications!,
              builder: (context, _) => _menu(context, c, l),
            )
          else
            _menu(context, c, l),
      ],
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
      traffic: widget.traffic,
      serverName: widget.serverName,
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

  /// Protocols through which clients get access, the same for every client.
  List<String> _protocols() {
    final w = controller.workspace;
    return [
      if (w.inbounds.any(
        (r) => !r.deleted && r.enabled && r.spec['internal'] != true,
      ))
        'VLESS',
      if (w.awgInterfaces.any((r) => !r.deleted && r.enabled)) 'AmneziaWG',
      if (w.ttEndpoints.any((r) => !r.deleted && r.enabled)) 'TrustTunnel',
    ];
  }

  Widget _row(VpnController c, VpnUser user, bool first) => UserTile(
    user: user,
    isFirst: first,
    controller: c,
    selection: selection,
    publications: publications,
    traffic: widget.traffic,
    motion: motion,
    onProfile: _profile,
    isSyncing: _syncing,
  );

  /// The period of the traffic in the rows, and the order of the list.
  Widget? _listBar(AppLocalizations l, int count) {
    final traffic = widget.traffic;
    final sort = count > 1 ? _sortMenu(l) : null;
    if (traffic == null && sort == null) return null;
    final month = DateFormat.LLLL(l.localeName).format(DateTime.now());
    final caption = traffic == null
        ? const SizedBox.shrink()
        : ListenableBuilder(
            listenable: traffic,
            builder: (context, _) => traffic.servers().isEmpty
                ? const SizedBox.shrink()
                : Text(
                    l.vpnTrafficFor(month),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
          );
    // Side by side where they fit; with large text the order moves under
    // the period instead of pushing it off the row.
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 16, bottom: 4),
      child: OverflowBar(
        alignment: MainAxisAlignment.spaceBetween,
        overflowAlignment: OverflowBarAlignment.end,
        overflowSpacing: 4,
        children: [caption, ?sort],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, selection]),
    builder: (context, _) {
      final c = controller, l = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final sorted = _sortedUsers(c.workspace.users);
      final enabledUsers = sorted.enabled, disabledUsers = sorted.disabled;
      final allUsers = [...enabledUsers, ...disabledUsers];
      final ids = [for (final u in allUsers) u.id];
      final protocols = _protocols();
      // With no active clients the disabled ones are the list itself.
      final showDisabled = _disabledOpen || enabledUsers.isEmpty;
      final fab = !selection.active && !_addInHeader(context);
      final listBar = selection.active || allUsers.isEmpty
          ? null
          : _listBar(l, allUsers.length);
      return Column(
        children: [
          _header(context, c, l, ids),
          Expanded(
            child: Stack(
              children: [
                DragSelectList(
                  selection: selection,
                  ids: [
                    for (final u in [
                      ...enabledUsers,
                      if (showDisabled) ...disabledUsers,
                    ])
                      u.id,
                  ],
                  enabled: c.canMutate,
                  builder: (scroll, item) => CustomScrollView(
                    controller: scroll,
                    key: const PageStorageKey('vpn-users'),
                    slivers: [
                      SliverPadding(
                        padding: AppLayout.screenPadding(context).copyWith(
                          top: 0,
                          // The last row scrolls clear of the floating button.
                          bottom: fab ? 96 : null,
                        ),
                        sliver: SliverMainAxisGroup(
                          slivers: [
                            SliverList.list(
                              children: [
                                ServerOperationsBanner(
                                  controller: c,
                                  serverName: serverName,
                                  onOpenServer: widget.onOpenServer,
                                ),
                                CatalogNormalContent(
                                  selection: selection,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (protocols.isEmpty)
                                        AppNotice(
                                          key: const ValueKey(
                                            'vpn-clients-no-access',
                                          ),
                                          icon: Icons.dns_outlined,
                                          message: l.uiClientsNoAccessHelp,
                                        ),
                                      if (publications != null)
                                        ListenableBuilder(
                                          listenable: publications!.changes,
                                          builder: (context, _) =>
                                              _buildSyncProgress(),
                                        )
                                      else
                                        _buildSyncProgress(),
                                      if (publications != null)
                                        PublicationFailuresNotice(
                                          controller: publications!,
                                        ),
                                    ],
                                  ),
                                ),
                                ?listBar,
                                if (publications != null)
                                  ListenableBuilder(
                                    listenable: publications!,
                                    builder: (context, _) => VpnPlanView(
                                      controller: c,
                                      serverName: serverName,
                                      showProgress:
                                          !_syncing &&
                                          !publications!.hasActiveSync,
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
                            // A lazy sliver: only the rows in view are built,
                            // so a long list does not stall the first frame
                            // (UI-31).
                            if (allUsers.isNotEmpty)
                              AppAnimatedCollection.sliver(
                                motion: motion,
                                items: {
                                  for (var i = 0; i < enabledUsers.length; i++)
                                    enabledUsers[i].id: item(
                                      enabledUsers[i].id,
                                      _row(c, enabledUsers[i], i == 0),
                                    ),
                                  if (disabledUsers.isNotEmpty &&
                                      enabledUsers.isNotEmpty)
                                    '__disabled_header__': _DisabledHeader(
                                      count: disabledUsers.length,
                                      open: _disabledOpen,
                                      motion: motion,
                                      onTap: () => setState(
                                        () => _disabledOpen = !_disabledOpen,
                                      ),
                                    ),
                                  if (showDisabled)
                                    for (
                                      var i = 0;
                                      i < disabledUsers.length;
                                      i++
                                    )
                                      disabledUsers[i].id: item(
                                        disabledUsers[i].id,
                                        _row(
                                          c,
                                          disabledUsers[i],
                                          i == 0 && enabledUsers.isEmpty,
                                        ),
                                      ),
                                },
                              ),
                            if (allUsers.isNotEmpty && protocols.isNotEmpty)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsetsDirectional.only(
                                    start: 16,
                                    top: AppLayout.gap,
                                  ),
                                  child: Text(
                                    l.uiClientsAccessVia(protocols.join(' · ')),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (fab)
                  PositionedDirectional(
                    end: AppLayout.gap,
                    bottom: AppLayout.gap,
                    child: FloatingActionButton.extended(
                      key: const ValueKey('vpn-user-add'),
                      onPressed: !c.canMutate || _syncing
                          ? null
                          : () => _add(context),
                      icon: const Icon(Icons.add),
                      label: Text(l.vpnAddUser),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

/// Folds the disabled clients away under one row with their count.
class _DisabledHeader extends StatelessWidget {
  const _DisabledHeader({
    required this.count,
    required this.open,
    required this.motion,
    required this.onTap,
  });
  final int count;
  final bool open;
  final MotionPreference motion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppLayout.smallGap),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: Material(
          type: MaterialType.transparency,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppLayout.radius),
          ),
          child: Semantics(
            button: true,
            expanded: open,
            child: InkWell(
              key: const ValueKey('vpn-disabled-section-header'),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: AppLayout.smallGap,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.pause_circle_outline,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          AppLocalizations.of(context).vpnDisabledClients,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppLayout.smallGap),
                      AppBadge(label: '$count'),
                      const Spacer(),
                      AnimatedRotation(
                        turns: open ? .5 : 0,
                        duration: AppMotion.duration(context, motion),
                        curve: AppMotion.curve,
                        child: Icon(
                          Icons.expand_more,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A client's own problem on one line; the whole text in its tooltip.
class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.message);
  final String message;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: message,
      excludeFromSemantics: true,
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: colors.error),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
class UserTile extends StatelessWidget {
  const UserTile({
    required this.user,
    required this.isFirst,
    required this.controller,
    required this.selection,
    required this.publications,
    required this.motion,
    this.traffic,
    required this.onProfile,
    this.isSyncing = false,
  });

  final VpnUser user;
  final bool isFirst;
  final VpnController controller;
  final CatalogSelection selection;
  final PublicationController? publications;

  /// This month's traffic under the name; null: not shown.
  final ClientTrafficController? traffic;
  final MotionPreference motion;
  final void Function(BuildContext, VpnUser) onProfile;
  final bool isSyncing;

  @override
  Widget build(BuildContext context) {
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
              subtitle: _subtitle(context, c),
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

  /// What concerns this client alone: its own error, or else its traffic
  /// this month. Access shared by every client is said once, under the list.
  Widget? _subtitle(BuildContext context, VpnController c) {
    final l = AppLocalizations.of(context);
    if (!user.enabled) return Text(l.vpnDisabled);
    final result = c.results[user.id];
    if (result != null && result.hasBlockingErrors) {
      return _ErrorLine(vpnMessage(l, result.diagnostics.first.code));
    }
    final traffic = this.traffic;
    Widget usage() => traffic == null
        ? const SizedBox.shrink()
        : ListenableBuilder(
            listenable: traffic,
            builder: (context, _) {
              final summary = traffic.summary(user.id);
              // Nothing counted anywhere (statistics off or unavailable) is
              // not shown as zero.
              final counted = summary.servers.any(
                (s) => s.protocols.any((p) => p.state == TrafficSourceState.ok),
              );
              return !counted
                  ? const SizedBox.shrink()
                  : TrafficUsageText(
                      summary.usage(trafficMonth(DateTime.now())),
                    );
            },
          );
    final pub = publications;
    if (pub == null) return traffic == null ? null : usage();
    return _PublicationSelector(
      listenable: pub.changes,
      select: () =>
          (pub.queues[user.id]?['status'], pub.queues[user.id]?['issue']),
      builder: (context) {
        final queue = pub.queues[user.id];
        // A disabled client is not published: its stored failure is stale.
        if (!user.deleted && queue?['status'] == 'error') {
          return _ErrorLine(publicationMessage(l, queue?['issue'] as String?));
        }
        return usage();
      },
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
    this.coreValidator,
  });
  final Iterable<String> Function() existingLogins;

  /// Stores the client and returns the error code, or null on success.
  final Future<String?> Function(VpnUser) save;
  final VpnUser? user;
  final PublicationController? publications;
  final Future<ImportedTemplate?> Function()? pickTemplate;
  final CoreConfigValidator? coreValidator;
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
    coreValidator: widget.coreValidator,
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
