import 'external_connection_check.dart';
import 'connection_check_view.dart';
import 'dart:async';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../catalog_selection.dart';
import '../drag_select_list.dart';
import '../network/network_controller.dart';
import '../network/server_address_field.dart';
import 'vpn_controller.dart';
import 'missing_on_server_notice.dart';
import 'adopt_resource.dart';
import 'observed_inbound_dialog.dart';
import 'xhttp_options_editor.dart';
import '../runner/runner_controller.dart';
import '../runner/panel_login_view.dart';
import 'vpn_plan_view.dart';
import 'reality_scan_result.dart';

class InboundsPanel extends StatefulWidget {
  const InboundsPanel({
    required this.controller,
    this.runner,
    this.selection,
    this.selectionInHeader = false,
    this.serverHost = '',
    required this.serverId,
    required this.serverName,
    required this.network,
    required this.motion,
    super.key,
  });
  final VpnController controller;
  final RunnerController? runner;
  final String serverHost;
  final String serverId;
  final String Function(String) serverName;
  final NetworkController network;
  final MotionPreference motion;
  final CatalogSelection? selection;
  final bool selectionInHeader;
  @override
  InboundsPanelState createState() => InboundsPanelState();
}

class InboundsPanelState extends State<InboundsPanel> {
  final ownSelection = CatalogSelection();
  CatalogSelection get selection => widget.selection ?? ownSelection;
  VpnController get controller => widget.controller;
  RunnerController? get runner => widget.runner;
  String get serverId => widget.serverId;
  String get serverHost => widget.serverHost;
  NetworkController get network => widget.network;
  MotionPreference get motion => widget.motion;
  final deletionState = ValueNotifier(false);
  bool get deleting => deletionState.value;
  set deleting(bool value) => deletionState.value = value;
  String? deletionIssue;
  String externalId(Map panel, Map inbound) =>
      'external-${panel['port']}-${inbound['id']}';
  String? _queried;
  final Set<String> _busyInboundIds = {};
  final Set<String> _busyExternalKeys = {};
  @override
  void initState() {
    super.initState();
    widget.runner?.addListener(_checkDiscovery);
    widget.controller.addListener(_rediscoverAfterJob);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkDiscovery());
  }

  String? _rediscoveredJob;

  /// Panel rows are a snapshot. After a VPN job of this server finished, read
  /// them again so a deleted inbound leaves "Deleting" and a row that no
  /// longer exists stops being shown as an existing foreign inbound.
  void _rediscoverAfterJob() {
    final r = widget.runner, job = widget.controller.currentJob(serverId);
    if (r == null || !mounted || job == null || !job.terminal) return;
    if (_rediscoveredJob == job.id || !r.connected || r.busy) return;
    // Only a deletion leaves stale rows; a needless discovery would occupy
    // the server while the automatic connection check starts.
    if (pendingDeletions.isEmpty) return;
    _rediscoveredJob = job.id;
    unawaited(r.discoverPanel());
  }

  @override
  void didUpdateWidget(InboundsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runner != widget.runner) {
      oldWidget.runner?.removeListener(_checkDiscovery);
      widget.runner?.addListener(_checkDiscovery);
      _queried = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkDiscovery());
    }
  }

  @override
  void dispose() {
    widget.runner?.removeListener(_checkDiscovery);
    widget.controller.removeListener(_rediscoverAfterJob);
    ownSelection.dispose();
    deletionState.dispose();
    super.dispose();
  }

  void _checkDiscovery() {
    final r = widget.runner;
    if (r == null || !mounted) return;
    final key =
        '${r.identity()}|${r.selected?.terminal == true ? r.selected?.id : ''}';
    if (r.installed &&
        r.connected &&
        !r.busy &&
        r.panelDiscovery == null &&
        _queried != key) {
      _queried = key;
      unawaited(r.discoverPanel());
    }
  }

  /// True when a panel row belongs to one of this device's resources,
  /// including a resource whose deletion is still waiting for the server.
  /// Such a row must never be presented as a foreign inbound.
  bool ownsRow(Map panel, Map row) => controller.workspace.inbounds.any(
    (r) =>
        r.serverId == serverId &&
        ((r.spec['adoption'] as Map?)?['sourceId'] == '${row['id']}' &&
                (r.spec['adoption'] as Map?)?['panelPort'] == panel['port'] ||
            row['name'] ==
                'AntiRKN:${controller.workspace.resourceWorkspaceId(r.serverId)}:${r.id}'),
  );

  /// Locally deleted resources that the server still reports.
  List<VlessInbound> get pendingDeletions => [
    for (final r in controller.workspace.inbounds)
      if (r.serverId == serverId &&
          r.deleted &&
          (runner?.panels ?? <Map<String, dynamic>>[]).any(
            (panel) => (panel['inbounds'] as List).any(
              (row) =>
                  (row as Map)['name'] ==
                      'AntiRKN:${controller.workspace.resourceWorkspaceId(r.serverId)}:${r.id}' ||
                  (r.spec['adoption'] as Map?)?['sourceId'] == '${row['id']}' &&
                      (r.spec['adoption'] as Map?)?['panelPort'] ==
                          panel['port'],
            ),
          ))
        r,
  ];

  List<String> get availableIds {
    final inbounds = controller.workspace.inbounds.where(
      (r) => r.serverId == serverId && !r.deleted,
    );
    return [
      for (final panel in runner?.panels ?? <Map<String, dynamic>>[])
        for (final row in panel['inbounds'] as List)
          if (!ownsRow(panel, row as Map)) externalId(panel, row),
      ...inbounds.map((r) => r.id),
    ];
  }

  Widget selectionActions() => ListenableBuilder(
    listenable: Listenable.merge([
      controller,
      runner,
      selection,
      deletionState,
    ]),
    builder: (context, _) => CatalogActions(
      selection: selection,
      available: availableIds,
      onDelete: removeSelected,
      prefix: 'inbound',
      busy:
          deleting ||
          !controller.canMutate ||
          controller.hasRunning ||
          (runner?.busy ?? false) ||
          (runner?.actionPending ?? false),
    ),
  );

  Widget selectable(String id, Widget child) => Row(
    children: [
      CatalogSelectionLeading(
        active: selection.active,
        selected: selection.ids.contains(id),
        onChanged: deleting ? null : (_) => selection.toggle(id),
        child: const SizedBox.shrink(),
      ),
      Expanded(
        child: Material(
          color: selection.ids.contains(id)
              ? Theme.of(context).colorScheme.secondaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppLayout.radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: selection.active && !deleting
                ? () => selection.toggle(id)
                : null,
            child: AbsorbPointer(
              absorbing: selection.active || deleting,
              child: child,
            ),
          ),
        ),
      ),
    ],
  );

  Future<bool> waitForJob(String id, {bool managed = false}) async {
    for (var i = 0; i < 180 && mounted; i++) {
      if (managed) {
        await controller.reconcile();
      } else {
        await runner!.refresh();
      }
      final job = managed ? controller.currentJob(serverId) : runner!.selected;
      if (job != null && job.id == id && job.terminal) {
        if (managed) await controller.refreshServer(serverId);
        return job.status == 'succeeded';
      }
      if (job != null && job.id != id) return false;
      if (!managed && runner!.error != null) return false;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  Future<void> removeSelected() async {
    final l = AppLocalizations.of(context);
    final managed = controller.workspace.inbounds
        .where(
          (r) =>
              r.serverId == serverId &&
              !r.deleted &&
              selection.ids.contains(r.id),
        )
        .toList();
    final external = <int, List<Map<String, dynamic>>>{};
    for (final panel in runner?.panels ?? <Map<String, dynamic>>[]) {
      for (final row in panel['inbounds'] as List) {
        if (selection.ids.contains(externalId(panel, row as Map))) {
          external
              .putIfAbsent(panel['port'] as int, () => [])
              .add(Map<String, dynamic>.from(row));
        }
      }
    }
    if (managed.isEmpty && external.isEmpty || deleting) return;
    setState(() {
      deleting = true;
      deletionIssue = null;
    });
    try {
      // Read external snapshots before consent, then retain their fingerprints through execution.
      final removals = <int, List<Map<String, Object?>>>{};
      for (final group in external.entries) {
        if (runner == null ||
            !await showPanelLogin(context, runner!, port: group.key) ||
            !mounted) {
          return;
        }
        for (final row in group.value) {
          final snapshot = await runner!.readInbound(row['id'] as int);
          if (snapshot == null) throw const FormatException('inbound_snapshot');
          final actual = snapshot['row'] as Map;
          if (actual['remark'] != row['name'] ||
              actual['port'] != row['port'] ||
              actual['protocol'] != row['protocol']) {
            throw const FormatException('inbound_changed');
          }
          removals.putIfAbsent(group.key, () => []).add({
            'inboundId': row['id'],
            'observedHash': snapshot['fingerprint'],
          });
        }
      }
      if (!mounted ||
          !await confirmCatalogDeletion(
            context,
            explanation: l.inboundDeleteSelectionHelp,
            names: [
              ...managed.map((r) => '${r.spec['name']} · ${r.spec['port']}'),
              for (final rows in external.values)
                for (final row in rows) '${row['name']} · ${row['port']}',
            ],
            confirmKey: 'inbound-confirm-delete',
          ) ||
          !mounted) {
        return;
      }
      if (managed.isNotEmpty) {
        if (runner != null &&
            (!await showPanelLogin(context, runner!) || !mounted)) {
          return;
        }
        await controller.deleteInbounds(managed);
        if (controller.error != null) {
          throw const FormatException('inbound_local');
        }
        await controller.prepareAndApply(serverIds: {serverId});
        final job = controller.currentJob(serverId);
        if (controller.error != null ||
            job == null ||
            !await waitForJob(job.id, managed: true)) {
          throw const FormatException('inbound_incomplete');
        }
        selection.replace(
          selection.ids.difference(managed.map((r) => r.id).toSet()),
        );
      }
      for (final group in removals.entries) {
        if (!mounted ||
            !await showPanelLogin(context, runner!, port: group.key) ||
            !mounted) {
          return;
        }
        final payload = <String, Object?>{'removals': group.value};
        final plan = await runner!.planInbound(payload);
        if (plan == null ||
            !await runner!.applyInbound(
              payload,
              plan['fingerprint'] as String,
              remove: true,
            )) {
          throw const FormatException('inbound_submit');
        }
        final id = runner!.selected?.id ?? runner!.pending?.id;
        if (id == null || !await waitForJob(id)) {
          throw const FormatException('inbound_incomplete');
        }
        selection.replace(
          selection.ids.difference(
            external[group.key]!
                .map((row) => 'external-${group.key}-${row['id']}')
                .toSet(),
          ),
        );
      }
      selection.exit();
    } catch (_) {
      if (mounted) setState(() => deletionIssue = l.inboundDeleteIncomplete);
    } finally {
      if (mounted) setState(() => deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, runner, selection]),
    builder: (context, _) {
      final c = controller,
          l = AppLocalizations.of(context),
          inbounds = c.workspace.inbounds.where(
            (r) => r.serverId == serverId && !r.deleted,
          ),
          externalInbounds = [
            for (final panel in runner?.panels ?? <Map<String, dynamic>>[])
              for (final row in panel['inbounds'] as List)
                if (!ownsRow(panel, row as Map)) (panel: panel, row: row),
          ],
          pendingDeleted = pendingDeletions;
      return DragSelectList(
        selection: selection,
        ids: availableIds,
        enabled: !deleting && c.canMutate && !(runner?.busy ?? false),
        builder: (scroll, item) => ListView(
          controller: scroll,
          shrinkWrap: true,
          physics: const ClampingScrollPhysics(),
          key: const PageStorageKey('vless-inbounds'),
          children: [
            if (selection.active && !widget.selectionInHeader)
              Row(
                children: [
                  Expanded(
                    child: CatalogTitle(
                      selection: selection,
                      title: l.vpnInbounds,
                    ),
                  ),
                  selectionActions(),
                ],
              ),
            // The page's VpnPlanView shows a busy controller and
            // VpnJobView a running job; this bar covers the rest of a
            // deletion, so the tab has one indicator (UI-40).
            if (deleting &&
                !c.foregroundBusy &&
                c.currentJob(serverId)?.terminal != false)
              const LinearProgressIndicator(),
            if (deletionIssue != null) Text(deletionIssue!),
            CatalogNormalContent(
              selection: selection,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppPageIntro(l.uiVlessIntro),
                  if (runner != null &&
                      (runner!.panelAccess == null ||
                          runner!.panelLoginRequired)) ...[
                    FilledButton.icon(
                      key: const ValueKey('vless-panel-login'),
                      onPressed: runner!.busy || runner!.actionPending
                          ? null
                          : () => showPanelLogin(context, runner!),
                      icon: const Icon(Icons.login),
                      label: Text(l.panelConnectTitle),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton.icon(
                    key: const ValueKey('vpn-inbound-add'),
                    onPressed: !c.canMutate ? null : () => _edit(context),
                    icon: const Icon(Icons.add),
                    label: Text(l.vpnAddInbound),
                  ),
                  ConnectionCheckAll(
                    controller: c,
                    readOthers: runner == null
                        ? null
                        : () async {
                            final keys = <({String target, String resource})>[];
                            for (final panel in runner!.panels) {
                              if (panel['port'] is! int) continue;
                              for (final row
                                  in (panel['inbounds'] as List? ?? const [])
                                      .whereType<Map>()) {
                                // Rows come from the server panel: skip ones
                                // that cannot be addressed.
                                if (row['id'] is! int) continue;
                                if (inbounds.any(
                                  (r) =>
                                      (r.spec['adoption']
                                                  as Map?)?['sourceId'] ==
                                              '${row['id']}' &&
                                          (r.spec['adoption']
                                                  as Map?)?['panelPort'] ==
                                              panel['port'] ||
                                      row['name'] ==
                                          'AntiRKN:${c.workspace.resourceWorkspaceId(r.serverId)}:${r.id}',
                                )) {
                                  continue;
                                }
                                if (!context.mounted) {
                                  break;
                                }
                                final key = row['protocol'] != 'vless'
                                    ? null
                                    : await prepareExternalConnection(
                                        context,
                                        controller: c,
                                        runner: runner!,
                                        serverId: serverId,
                                        protocol: 'vless',
                                        source: row['id'] as int,
                                        panelPort: panel['port'] as int,
                                        host: serverHost,
                                      );
                                keys.add(
                                  key ??
                                      externalConnectionTarget(
                                        serverId,
                                        'vless',
                                        row['id'] as int,
                                        panel['port'] as int,
                                      ),
                                );
                              }
                            }
                            return keys;
                          },
                    targets: [
                      for (final r in inbounds)
                        (target: serverId, resource: r.id),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
            MissingOnServerNotice(
              controller: controller,
              target: serverId,
              authorize: runner == null
                  ? null
                  : () => showPanelLogin(context, runner!),
            ),
            AppSectionHeading(
              title: l.vpnInbounds,
              count:
                  inbounds.length +
                  externalInbounds.length +
                  pendingDeleted.length,
              action: selection.active
                  ? null
                  : IconButton(
                      tooltip: l.sshRefresh,
                      onPressed: (runner?.busy ?? false) || !c.canMutate
                          ? null
                          : () async {
                              await c.refreshServer(serverId);
                              if (runner != null) {
                                _queried = null;
                                await runner!.discoverPanel();
                              }
                              if (c.error == null &&
                                  inbounds.any(
                                    (r) =>
                                        !c.adoptionConfirmed(serverId, r.id) &&
                                        !r.deleted,
                                  )) {
                                await c.prepareAndApply(serverIds: {serverId});
                              }
                            },
                      icon: const Icon(Icons.refresh),
                    ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (runner?.panelDetected == true &&
                    (runner?.panels.isEmpty ?? true))
                  Text(l.panelDiscoveryFailed),
                if (inbounds.isEmpty &&
                    externalInbounds.isEmpty &&
                    runner?.panelDiscovery?['failed'] != true &&
                    !(runner?.panelDetected == true &&
                        (runner?.panels.isEmpty ?? true)))
                  AppEmptyState(
                    title: l.vpnNoInbounds,
                    icon: Icons.hub_outlined,
                  ),
                for (final entry in externalInbounds)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
                    child: item(
                      externalId(entry.panel, entry.row),
                      selectable(
                        externalId(entry.panel, entry.row),
                        ResourceTile(
                          storageId:
                              'observed-$serverId-${entry.panel['port']}-${entry.row['id']}',
                          footer:
                              selection.active ||
                                  entry.row['protocol'] != 'vless'
                              ? null
                              : ExternalConnectionCheck(
                                  controller: c,
                                  runner: runner!,
                                  serverId: serverId,
                                  protocol: 'vless',
                                  source: entry.row['id'] as int,
                                  panelPort: entry.panel['port'] as int,
                                  host: serverHost,
                                ),
                          title: '${entry.row['name'] ?? ''}'.trim().isEmpty
                              ? "${'${entry.row['protocol']}'.toUpperCase()} · ${entry.row['port']}"
                              : '${entry.row['name']}',
                          subtitle:
                              '${entry.row['transport']} · ${entry.row['security']}',
                          badge: entry.row['enabled'] == true
                              ? l.vpnEnabled
                              : l.vpnDisabled,
                          note: l.vpnObserved,
                          detailsLabel: l.componentsDetails,
                          details: const [],
                          badgeBusy: _busyExternalKeys.contains(
                            externalId(entry.panel, entry.row),
                          ),
                          onBadgeTap:
                              runner == null ||
                                  runner!.busy ||
                                  runner!.actionPending ||
                                  _busyExternalKeys.contains(
                                    externalId(entry.panel, entry.row),
                                  )
                              ? null
                              : () async {
                                  final id = (entry.row['id'] as num?)?.toInt();
                                  if (id == null) return;
                                  final extKey = externalId(
                                    entry.panel,
                                    entry.row,
                                  );
                                  if (_busyExternalKeys.contains(extKey) ||
                                      runner == null ||
                                      runner!.busy ||
                                      runner!.actionPending) {
                                    return;
                                  }
                                  setState(() => _busyExternalKeys.add(extKey));
                                  try {
                                    final port =
                                        (entry.panel['port'] as num?)
                                            ?.toInt() ??
                                        0;
                                    if (!await showPanelLogin(
                                          context,
                                          runner!,
                                          port: port,
                                        ) ||
                                        !context.mounted) {
                                      return;
                                    }
                                    await runner!.setInboundEnabled(
                                      id,
                                      entry.row['enabled'] != true,
                                    );
                                  } finally {
                                    if (mounted) {
                                      setState(
                                        () => _busyExternalKeys.remove(extKey),
                                      );
                                    }
                                  }
                                },
                          actions: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (entry.row['protocol'] == 'vless')
                                IconButton(
                                  key: ValueKey(
                                    'adopt-vless-${entry.panel['port']}-${entry.row['id']}',
                                  ),
                                  tooltip: l.vpnAdopt,
                                  icon: const Icon(Icons.people_outline),
                                  onPressed:
                                      !c.canMutate ||
                                          c.hasRunning ||
                                          runner == null
                                      ? null
                                      : () => adoptExistingResource(
                                          context,
                                          controller: c,
                                          runner: runner!,
                                          serverId: serverId,
                                          protocol: 'vless',
                                          sourceId: entry.row['id'] as int,
                                          panelPort: entry.panel['port'] as int,
                                          host: serverHost,
                                          motion: motion,
                                        ),
                                ),
                              IconButton(
                                tooltip: l.vpnEdit,
                                icon: const Icon(Icons.edit_outlined),
                                onPressed:
                                    runner == null ||
                                        runner!.busy ||
                                        runner!.actionPending
                                    ? null
                                    : () async {
                                        if (!await showPanelLogin(
                                              context,
                                              runner!,
                                              port: entry.panel['port'] as int,
                                            ) ||
                                            !context.mounted) {
                                          return;
                                        }
                                        await showDialog<void>(
                                          context: context,
                                          animationStyle: AnimationStyle(
                                            duration: AppMotion.duration(
                                              context,
                                              motion,
                                            ),
                                          ),
                                          builder: (context) =>
                                              ObservedInboundDialog(
                                                controller: runner!,
                                                network: network,
                                                inboundId:
                                                    entry.row['id'] as int,
                                                port:
                                                    entry.panel['port'] as int,
                                                motion: motion,
                                              ),
                                        );
                                      },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                for (final r in pendingDeleted)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
                    child: ResourceTile(
                      key: ValueKey('inbound-deleting-${r.id}'),
                      storageId: 'deleting-${r.id}',
                      title: r.spec['name'] as String,
                      subtitle:
                          '${r.spec['transport'].toString().toUpperCase()} · ${r.spec['security'].toString().toUpperCase()}',
                      badge: l.vpnDisabled,
                      note: l.vpnPendingDeletion,
                      detailsLabel: l.componentsDetails,
                      details: const [],
                    ),
                  ),
                for (final r in inbounds)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
                    child: item(
                      r.id,
                      selectable(
                        r.id,
                        ResourceTile(
                          key: ValueKey('inbound-summary-${r.id}'),
                          footer: selection.active
                              ? null
                              : ConnectionCheckView(
                                  controller: c,
                                  target: (target: serverId, resource: r.id),
                                  onEdit: () => _edit(context, r),
                                ),
                          storageId: r.id,
                          title: r.spec['name'] as String,
                          subtitle:
                              '${r.spec['transport'].toString().toUpperCase()} · ${r.spec['security'].toString().toUpperCase()}',
                          badge: r.enabled ? l.vpnEnabled : l.vpnDisabled,
                          note:
                              r.spec.containsKey('adoption') &&
                                  !c.adoptionConfirmed(serverId, r.id)
                              ? l.vpnAdopting
                              : !c.adoptionConfirmed(serverId, r.id)
                              // The check below states why; without it
                              // (selection mode) the note says it.
                              ? (selection.active
                                    ? (c.connections.unavailableReasonCode((
                                                target: serverId,
                                                resource: r.id,
                                              )) ==
                                              'vpn_missing'
                                          ? l.vpnMissingOnServer
                                          : l.vpnPendingReadback)
                                    : null)
                              : r.internal
                              ? l.vpnInternal
                              : l.vpnClientAccess,
                          detailsLabel: l.componentsDetails,
                          details: const [],
                          badgeBusy: _busyInboundIds.contains(r.id),
                          onBadgeTap:
                              _busyInboundIds.contains(r.id) || !c.canMutate
                              ? null
                              : () async {
                                  if (_busyInboundIds.contains(r.id) ||
                                      !c.canMutate) {
                                    return;
                                  }
                                  setState(() => _busyInboundIds.add(r.id));
                                  try {
                                    if (runner != null &&
                                        (!await showPanelLogin(
                                              context,
                                              runner!,
                                            ) ||
                                            !context.mounted)) {
                                      return;
                                    }
                                    await c.saveInbound(
                                      VlessInbound(
                                        serverId: r.serverId,
                                        spec: {
                                          ...r.spec,
                                          'enabled': !r.enabled,
                                        },
                                      ),
                                    );
                                    if (c.error == null) {
                                      await c.prepareAndApply(
                                        serverIds: {r.serverId},
                                      );
                                    }
                                  } finally {
                                    if (mounted) {
                                      setState(
                                        () => _busyInboundIds.remove(r.id),
                                      );
                                    }
                                  }
                                },
                          actions: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                key: ValueKey('vpn-internal-${r.id}'),
                                tooltip: r.internal
                                    ? l.vpnInternal
                                    : l.vpnClientAccess,
                                icon: Icon(
                                  r.internal
                                      ? Icons.lock_outline
                                      : Icons.people_outline,
                                ),
                                onPressed: !c.canMutate
                                    ? null
                                    : () async {
                                        await c.saveInbound(
                                          VlessInbound(
                                            serverId: r.serverId,
                                            spec: {
                                              ...r.spec,
                                              'internal': !r.internal,
                                            },
                                          ),
                                        );
                                        if (c.error == null) {
                                          await c.prepareAndApply(
                                            serverIds: {r.serverId},
                                          );
                                        }
                                      },
                              ),
                              IconButton(
                                tooltip: l.vpnEdit,
                                onPressed: !c.canMutate
                                    ? null
                                    : () => _edit(context, r),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                VpnJobView(
                  showSnapshot: false,
                  controller: c,
                  serverId: serverId,
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
  Future<void> _edit(BuildContext context, [VlessInbound? inbound]) async {
    if (runner != null &&
        (!await showPanelLogin(context, runner!) || !context.mounted)) {
      return;
    }
    if (inbound?.spec.containsKey('adoption') == true) {
      final spec = await editAdoptedResource(context, inbound!.spec);
      if (spec == null) return;
      await controller.saveInbound(
        VlessInbound(serverId: serverId, spec: spec),
      );
      if (controller.error == null) {
        await controller.prepareAndApply(serverIds: {serverId});
      }
      return;
    }
    final result = await showDialog<VlessInbound>(
      context: context,
      builder: (context) => InboundForm(
        serverId: serverId,
        network: network,
        motion: motion,
        inbound: inbound,
        defaultEndpoint: serverHost,
        scanReality: runner?.scanReality,
      ),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, motion),
      ),
    );
    if (result == null) return;
    await controller.saveInbound(result);
    if (controller.error == null) {
      if (result.deleted && inbound != null && !inbound.deleted) {
        AppHaptics.deleted();
      } else if (inbound == null && !result.deleted) {
        AppHaptics.added();
      }
    }
    if (controller.error == null) {
      await controller.prepareAndApply(serverIds: {serverId});
    }
  }
}

class InboundForm extends StatefulWidget {
  const InboundForm({
    required this.serverId,
    required this.network,
    required this.motion,
    this.inbound,
    this.defaultEndpoint = '',
    this.scanReality,
    super.key,
  });
  final String serverId;
  final NetworkController network;
  final MotionPreference motion;
  final VlessInbound? inbound;
  final String defaultEndpoint;
  final Future<Map<String, dynamic>?> Function(String target, String sni)?
  scanReality;
  @override
  State<InboundForm> createState() => _InboundFormState();
}

class _InboundFormState extends State<InboundForm> {
  late final Map<String, Object?> spec = {
    ...(widget.inbound?.spec ??
        {...VlessInbound.defaults(), 'endpoint': widget.defaultEndpoint}),
  };
  late final fields = <String, TextEditingController>{
    for (final key in [
      'name',
      'listen',
      'port',
      'sni',
      'target',
      'path',
      'host',
      'certificate',
      'certificateKey',
    ])
      key: TextEditingController(text: '${spec[key]}'),
  };
  @override
  void initState() {
    super.initState();
    if (spec['transport'] == 'xhttp') {
      spec['xhttp'] = xhttpFormDefaults(spec['xhttp'] as Map? ?? {});
    }
  }

  bool invalid = false;
  bool regenerated = false;
  bool scanning = false;
  bool scanFailed = false;
  Map<String, dynamic>? scanResult;
  late bool automaticSni =
      fields['sni']!.text.isEmpty ||
      fields['sni']!.text == realityTargetHost(fields['target']!.text);
  Future<void> scan() async {
    final target = normalizeRealityTarget(fields['target']!.text.trim());
    final sni = fields['sni']!.text.trim();
    setState(() {
      scanning = true;
      scanFailed = false;
      scanResult = null;
    });
    Map<String, dynamic>? result;
    try {
      result = await widget.scanReality?.call(target, sni);
    } catch (_) {
      /* Display a localized failure below. */
    }
    if (!mounted) return;
    setState(() {
      scanning = false;
      if (target != normalizeRealityTarget(fields['target']!.text.trim()) ||
          sni != fields['sni']!.text.trim()) {
        return;
      }
      scanResult = result;
      scanFailed = result == null;
    });
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Widget field(String key, String label, {bool number = false}) => Padding(
    padding: const EdgeInsets.only(bottom: AppLayout.gap),
    child: TextField(
      key: ValueKey('vpn-inbound-$key'),
      controller: fields[key],
      onChanged: (value) {
        if (key == 'target' || key == 'sni') {
          setState(() {
            scanResult = null;
            scanFailed = false;
            if (key == 'sni') {
              automaticSni =
                  value.isEmpty ||
                  value == realityTargetHost(fields['target']!.text);
            }
            if (key == 'target' && automaticSni) {
              fields['sni']!.text = realityTargetHost(value);
            }
          });
        }
      },
      keyboardType: number ? TextInputType.number : TextInputType.text,
      minLines: 1,
      maxLines: key == 'sni' ? null : 1,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: label),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context),
        xhttp = spec['transport'] == 'xhttp',
        tls = spec['security'] == 'tls';
    return AppFormDialog(
      title: Text(widget.inbound == null ? l.vpnAddInbound : l.vpnEdit),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field('name', l.vpnName),
              AppSelectField<String>(
                key: ValueKey('transport-${spec['transport']}'),
                value: spec['transport'] as String,
                label: l.vpnTransport,
                motion: widget.motion,
                options: const [
                  ('raw', 'RAW/TCP · Vision'),
                  ('xhttp', 'XHTTP'),
                ],
                onChanged: (v) => setState(() {
                  spec['transport'] = v;
                  if (v == 'xhttp') spec['xhttp'] = xhttpFormDefaults();
                  if (v == 'raw') {
                    spec.remove('xhttp');
                    spec['security'] = 'reality';
                    spec['mode'] = 'auto';
                  }
                }),
              ),
              const SizedBox(height: AppLayout.gap),
              if (xhttp) ...[
                AppSelectField<String>(
                  key: ValueKey('security-${spec['security']}'),
                  value: spec['security'] as String,
                  label: l.vpnSecurity,
                  motion: widget.motion,
                  options: const [('reality', 'REALITY'), ('tls', 'TLS')],
                  onChanged: (v) => setState(() {
                    spec['security'] = v;
                    spec['mode'] = 'auto';
                  }),
                ),
                const SizedBox(height: AppLayout.gap),
              ],
              ServerAddressField(
                label: l.vpnListen,
                fieldKey: const ValueKey('vpn-inbound-listen'),
                network: widget.network,
                controller: fields['listen']!,
                motion: widget.motion,
              ),
              const SizedBox(height: AppLayout.gap),
              field('port', l.vpnPort, number: true),
              AppSelectField<String>(
                key: const ValueKey('vpn-inbound-utls'),
                value: spec['fingerprint'] as String? ?? 'chrome',
                label: 'uTLS',
                motion: widget.motion,
                options: [for (final name in vlessFingerprints) (name, name)],
                onChanged: (value) {
                  setState(() => spec['fingerprint'] = value);
                },
              ),
              const SizedBox(height: AppLayout.gap),
              if (!tls) ...[
                field('target', l.vpnTarget),
                OutlinedButton.icon(
                  key: const ValueKey('vpn-reality-scan'),
                  onPressed:
                      scanning ||
                          widget.scanReality == null ||
                          fields['target']!.text.trim().isEmpty
                      ? null
                      : scan,
                  icon: scanning
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.radar),
                  label: Text(l.realityScan),
                ),
                Text(l.realityScanHelp),
                if (scanFailed) Text(l.realityScanFailed),
                if (scanResult case final result?)
                  RealityScanResultView(
                    result: result,
                    onSni: (name) => setState(() {
                      fields['sni']!.text = name;
                      automaticSni = false;
                      scanResult = null;
                    }),
                  ),
              ],
              field('sni', l.vpnSni),
              if (!tls) ...[
                OutlinedButton.icon(
                  key: const ValueKey('vpn-reality-regenerate'),
                  onPressed: () => setState(() {
                    spec['realitySeed'] = newVpnId();
                    regenerated = true;
                  }),
                  icon: const Icon(Icons.refresh),
                  label: Text(l.vpnRegenerateReality),
                ),
                Text(
                  regenerated ? l.vpnRealityRegenerated : l.vpnRealityAutomatic,
                ),
              ],
              if (xhttp) ...[
                field('path', l.vpnPath),
                field('host', l.vpnHost),
                AppSelectField<String>(
                  key: ValueKey('mode-${spec['mode']}-$tls'),
                  value: spec['mode'] as String,
                  label: l.vpnMode,
                  motion: widget.motion,
                  options: [
                    for (final mode in [
                      'auto',
                      'stream-one',
                      if (tls) 'packet-up',
                      if (tls) 'stream-up',
                    ])
                      (mode, mode),
                  ],
                  onChanged: (v) => setState(() => spec['mode'] = v),
                ),
                const SizedBox(height: AppLayout.gap),
              ],
              if (xhttp)
                XhttpOptionsEditor(
                  motion: widget.motion,
                  initial: Map<String, Object?>.from(
                    spec['xhttp'] as Map? ?? {},
                  ),
                  onChanged: (values) {
                    if (values.isEmpty) {
                      spec.remove('xhttp');
                    } else {
                      spec['xhttp'] = values;
                    }
                  },
                ),
              if (tls) ...[
                Text(l.vpnTlsHelp),
                field('certificate', l.vpnCertificate),
                field('certificateKey', l.vpnCertificateKey),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.vpnEnabled),
                value: spec['enabled'] as bool,
                onChanged: spec['deleted'] == true
                    ? null
                    : (v) => setState(() => spec['enabled'] = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.vpnInternal),
                subtitle: Text(l.vpnInternalHelp),
                secondary: const Icon(Icons.lock_outline),
                value: spec['internal'] == true,
                onChanged: (v) => setState(() => spec['internal'] = v),
              ),
              if (widget.inbound != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.vpnDeleteInbound),
                  subtitle: Text(l.vpnDeleteHelp),
                  value: spec['deleted'] as bool,
                  onChanged: (v) => setState(() {
                    spec['deleted'] = v == true;
                    if (v == true) spec['enabled'] = false;
                  }),
                ),
              Text(l.connectionAfterSave),
              if (invalid)
                Text(
                  l.vpnInvalid,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.runnerNotNow),
        ),
        FilledButton(
          key: const ValueKey('vpn-inbound-save'),
          onPressed: () {
            try {
              final port = int.tryParse(fields['port']!.text.trim());
              final listen = fields['listen']!.text.trim();
              final defaultHost =
                  (spec['endpoint'] as String? ?? '').trim().isNotEmpty &&
                      !['0.0.0.0', '::'].contains(spec['endpoint'])
                  ? (spec['endpoint'] as String).trim()
                  : widget.defaultEndpoint.trim();
              final endpoint = !['0.0.0.0', '::', ''].contains(listen)
                  ? listen
                  : defaultHost;
              final values = <String, Object?>{
                ...spec,
                for (final e in fields.entries)
                  e.key: e.key == 'port' ? port : e.value.text.trim(),
                'endpoint': endpoint,
                'externalPort': port,
              };
              if (!tls) {
                values['target'] = normalizeRealityTarget(
                  values['target'] as String,
                );
              }
              if (tls && values['target'] == '') {
                values['target'] = '${values['sni']}:443';
              }
              final inbound = VlessInbound(
                serverId: widget.serverId,
                spec: values,
              );
              Navigator.pop(context, inbound);
            } catch (_) {
              setState(() => invalid = true);
            }
          },
          child: Text(l.vpnSave),
        ),
      ],
    );
  }
}
