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
import 'reality_search_controller.dart';
import 'reality_target_page.dart';
import 'relay_inbound_view.dart';
import '../protocol_icon.dart';

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

  /// Guards a deletion while its sign-ins and consent are still open; the
  /// list and its bar stay idle until the person confirms (UI-62).
  bool _preparingDeletion = false;
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

  RealitySearchController? _search;

  /// One search per server while this panel lives; null without an engine.
  RealitySearchController? get realitySearch {
    final scanner = controller.tlsScanner;
    final network = controller.connections.engine?.network;
    if (scanner == null || network == null) return null;
    if (_search?.serverId != serverId) {
      _search?.dispose();
      _search = RealitySearchController(
        serverId: serverId,
        store: controller.connections.store,
        // A finalist check only; the runner refuses it while busy.
        checkFromServer: (target, sni) async =>
            await runner?.scanReality(target, sni),
        search: RealityTargetSearch(
          transport: scanner,
          network: network.network,
        ),
      );
    }
    return _search;
  }

  /// The server's public IPv4 whose neighbours are searched; '' if unknown.
  String get serverIpv4 {
    final inventory = network.inventory;
    if (inventory?.serverId == serverId) {
      for (final a in inventory!.addresses) {
        if (a.address.family == IpFamily.ipv4 &&
            a.address.category == IpCategory.publicUnicast) {
          return a.address.canonical;
        }
      }
    }
    final host = IpAddress.tryParse(serverHost);
    return host != null &&
            host.family == IpFamily.ipv4 &&
            host.category == IpCategory.publicUnicast
        ? host.canonical
        : '';
  }

  @override
  void dispose() {
    _search?.dispose();
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
      return;
    }
    // Relay state once per page and panel: the journal copy may predate a
    // panel edit that left a relay rule stale.
    final relayKey = '${r.identity()}|${r.panelAccess?.id}';
    if (r.installed &&
        r.connected &&
        r.canRequestAction &&
        r.panelAccess != null &&
        !r.panelLoginRequired &&
        _relayQueried != relayKey) {
      _relayQueried = relayKey;
      unawaited(r.refreshRelay());
    }
  }

  String? _relayQueried;

  /// True when [row] of [panel] is the server copy of [r].
  bool _matches(VlessInbound r, Map panel, Map row) =>
      (r.spec['adoption'] as Map?)?['sourceId'] == '${row['id']}' &&
          (r.spec['adoption'] as Map?)?['panelPort'] == panel['port'] ||
      row['name'] ==
          'AntiRKN:${controller.workspace.resourceWorkspaceId(r.serverId)}:${r.id}';

  /// The direct exit candidate of a VLESS row of the connected panel; null
  /// for other protocols, other panels, before the panel login and while
  /// the client egress is off (a direct exit only bypasses it), unless the
  /// row already is a direct exit: it can always be turned off.
  RelayTarget? relayTarget(Map panel, Map row, [VlessInbound? resource]) {
    final r = runner, id = row['id'];
    if (r == null ||
        r.panelAccess == null ||
        panel['port'] != r.panelAccess!.port ||
        row['protocol'] != 'vless' ||
        id is! int ||
        r.egress?['enabled'] != true && r.relayEntry(id) == null) {
      return null;
    }
    final name = '${row['name'] ?? ''}'.trim();
    final title =
        resource?.name ?? (name.isEmpty ? 'VLESS · ${row['port']}' : name);
    return RelayTarget(
      inboundId: id,
      title: title,
      linkName: '${widget.serverName(serverId)} · $title',
      row: row,
      resource: resource,
      clientFacing: resource != null && !resource.internal,
      makeInternal: resource == null
          ? null
          : () async {
              final c = controller;
              if (!c.canMutate) return false;
              await c.saveInbound(
                VlessInbound(
                  serverId: resource.serverId,
                  spec: {...resource.spec, 'internal': true},
                ),
              );
              if (c.error != null) return false;
              await c.prepareAndApply(serverIds: {resource.serverId});
              return c.error == null;
            },
    );
  }

  /// The relay candidate of a managed or adopted inbound, once the server
  /// reports its row.
  RelayTarget? managedRelayTarget(VlessInbound r) {
    for (final panel in runner?.panels ?? <Map<String, dynamic>>[]) {
      for (final row in panel['inbounds'] as List? ?? const []) {
        if (row is Map && _matches(r, panel, row)) {
          return relayTarget(panel, row, r);
        }
      }
    }
    return null;
  }

  /// True when a panel row belongs to one of this device's resources,
  /// including a resource whose deletion is still waiting for the server.
  /// Such a row must never be presented as a foreign inbound.
  bool ownsRow(Map panel, Map row) => controller.workspace.inbounds.any(
    (r) => r.serverId == serverId && _matches(r, panel, row),
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

  /// The card draws its own selection and ripple (UI-58). Outside selection
  /// mode a tap on the card runs [onOpen], its edit action, which is null
  /// exactly when that action is unavailable.
  Widget selectable(
    String id,
    ResourceTile Function(bool selected, bool selecting, VoidCallback? onTap)
    tile, {
    VoidCallback? onOpen,
  }) => Row(
    children: [
      CatalogSelectionLeading(
        active: selection.active,
        selected: selection.ids.contains(id),
        onChanged: deleting ? null : (_) => selection.toggle(id),
        child: const SizedBox.shrink(),
      ),
      Expanded(
        child: tile(
          selection.ids.contains(id),
          selection.active || deleting,
          deleting
              ? null
              : selection.active
              ? () => selection.toggle(id)
              : onOpen,
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
    if (managed.isEmpty && external.isEmpty || deleting || _preparingDeletion) {
      return;
    }
    _preparingDeletion = true;
    setState(() => deletionIssue = null);
    // Before consent nothing has changed: a failure then is a read failure,
    // not an incomplete deletion.
    var started = false;
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
      setState(() => deleting = true);
      started = true;
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
      if (mounted) {
        setState(
          () => deletionIssue =
              runner?.responseCode == 'relay_disable_first' ||
                  controller.error == 'relay_disable_first'
              ? l.relayDisableFirst
              : started
              ? l.inboundDeleteIncomplete
              : l.inboundDeleteReadFailed,
        );
      }
    } finally {
      _preparingDeletion = false;
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
          // Rows come from the server panel: skip ones that cannot be
          // addressed.
          checkableExternal = [
            for (final e in externalInbounds)
              if (e.panel['port'] is int && e.row['id'] is int) e,
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
            if (deletionIssue != null)
              AppNotice(message: deletionIssue!, error: true),
            CatalogNormalContent(
              selection: selection,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConnectionCheckAll(
                    controller: c,
                    actions: [
                      if (runner != null &&
                          (runner!.panelAccess == null ||
                              runner!.panelLoginRequired))
                        FilledButton.icon(
                          key: const ValueKey('vless-panel-login'),
                          onPressed: runner!.busy || runner!.actionPending
                              ? null
                              : () => showPanelLogin(context, runner!),
                          icon: const Icon(Icons.login),
                          label: Text(l.panelConnectTitle),
                        ),
                      FilledButton.icon(
                        key: const ValueKey('vpn-inbound-add'),
                        onPressed: !c.canMutate ? null : () => _edit(context),
                        icon: const Icon(Icons.add),
                        label: Text(l.vpnAddInbound),
                      ),
                    ],
                    others: checkableExternal.length,
                    readOthers: runner == null
                        ? null
                        : () async {
                            final keys = <({String target, String resource})>[];
                            for (final (:panel, :row) in checkableExternal) {
                              if (!context.mounted) break;
                              final id = row['id'] as int,
                                  port = panel['port'] as int;
                              final key = row['protocol'] != 'vless'
                                  ? null
                                  : await prepareExternalConnection(
                                      context,
                                      controller: c,
                                      runner: runner!,
                                      serverId: serverId,
                                      protocol: 'vless',
                                      source: id,
                                      panelPort: port,
                                      host: serverHost,
                                    );
                              keys.add(
                                key ??
                                    externalConnectionTarget(
                                      serverId,
                                      'vless',
                                      id,
                                      port,
                                    ),
                              );
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
                        onOpen: editObserved(context, entry.panel, entry.row),
                        (selected, selecting, onTap) => ResourceTile(
                          selected: selected,
                          selecting: selecting,
                          onTap: onTap,
                          tapHint: l.vpnEdit,
                          tags: [
                            if (relayTarget(entry.panel, entry.row)
                                case final target?)
                              if (runner!.relayEntry(target.inboundId)
                                  case final relay?)
                                RelayInboundBadge(
                                  stale: relay['stale'] == true,
                                ),
                          ],
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
                          badge: l.vpnEnabled,
                          switchValue: entry.row['enabled'] == true,
                          note: l.vpnObserved,
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
                              if (relayTarget(entry.panel, entry.row)
                                  case final target?)
                                RelayInboundButton(
                                  controller: runner!,
                                  target: target,
                                  sshHost: serverHost,
                                ),
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
                                onPressed: editObserved(
                                  context,
                                  entry.panel,
                                  entry.row,
                                ),
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
                    ),
                  ),
                for (final r in inbounds)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
                    child: item(
                      r.id,
                      selectable(
                        r.id,
                        onOpen: !c.canMutate ? null : () => _edit(context, r),
                        (selected, selecting, onTap) => ResourceTile(
                          selected: selected,
                          selecting: selecting,
                          onTap: onTap,
                          tapHint: l.vpnEdit,
                          key: ValueKey('inbound-summary-${r.id}'),
                          tags: [
                            if (relayOf(r) case final relay?)
                              RelayInboundBadge(stale: relay['stale'] == true),
                          ],
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
                          badge: l.vpnEnabled,
                          switchValue: r.enabled,
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
                              // Client access is the default and goes
                              // unlabelled; only internal use is named.
                              : r.internal
                              ? l.vpnInternal
                              : null,
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
                              if (managedRelayTarget(r) case final target?)
                                RelayInboundButton(
                                  controller: runner!,
                                  target: target,
                                  sshHost: serverHost,
                                ),
                              IconButton(
                                key: ValueKey('vpn-internal-${r.id}'),
                                // A relay inbound stays internal until its
                                // direct exit is off (the runner refuses too).
                                tooltip: relayOf(r) != null
                                    ? l.relayInternalLocked
                                    : r.internal
                                    ? l.vpnInternal
                                    : l.vpnClientAccess,
                                // A toggle: "internal" is its on state (UI-73).
                                isSelected: r.internal,
                                icon: const Icon(Icons.people_outline),
                                selectedIcon: const Icon(Icons.lock_outline),
                                onPressed: !c.canMutate || relayOf(r) != null
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

  /// Opens the editor of an inbound observed on a panel; null while the
  /// runner cannot take it. Its edit button and its card share it.
  VoidCallback? editObserved(BuildContext context, Map panel, Map row) =>
      runner == null || runner!.busy || runner!.actionPending
      ? null
      : () async {
          if (!await showPanelLogin(
                context,
                runner!,
                port: panel['port'] as int,
              ) ||
              !context.mounted) {
            return;
          }
          await showDialog<void>(
            context: context,
            animationStyle: AnimationStyle(
              duration: AppMotion.duration(context, motion),
            ),
            builder: (context) => ObservedInboundDialog(
              controller: runner!,
              network: network,
              inboundId: row['id'] as int,
              port: panel['port'] as int,
              motion: motion,
            ),
          );
        };

  /// The relay state of [r] on the connected panel, or null.
  Map<String, dynamic>? relayOf(VlessInbound r) =>
      switch (managedRelayTarget(r)) {
        final target? => runner!.relayEntry(target.inboundId),
        null => null,
      };

  Future<void> _edit(BuildContext context, [VlessInbound? inbound]) async {
    if (runner != null &&
        (!await showPanelLogin(context, runner!) || !context.mounted)) {
      return;
    }
    if (inbound?.spec.containsKey('adoption') == true) {
      final spec = await editAdoptedResource(context, inbound!.spec);
      if (spec == null) return;
      return saveAndApply(
        controller,
        target: serverId,
        save: () => controller.saveInbound(
          VlessInbound(serverId: serverId, spec: spec),
        ),
      );
    }
    final search = realitySearch;
    await search?.ready;
    if (!context.mounted) return;
    final result = await showDialog<VlessInbound>(
      context: context,
      builder: (context) => InboundForm(
        serverId: serverId,
        network: network,
        motion: motion,
        inbound: inbound,
        defaultEndpoint: serverHost,
        scanReality: runner?.scanReality,
        findTarget: search == null
            ? null
            : (context) => showRealityTargetSearch(
                context,
                controller: search,
                serverAddress: serverIpv4,
                motion: motion,
              ),
        suggested: search?.best,
      ),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, motion),
      ),
    );
    if (result == null) return;
    await saveAndApply(
      controller,
      target: serverId,
      save: () => controller.saveInbound(result),
      added: inbound == null && !result.deleted,
      deleted: result.deleted && inbound != null && !inbound.deleted,
    );
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
    this.findTarget,
    this.suggested,
    super.key,
  });
  final String serverId;
  final NetworkController network;
  final MotionPreference motion;
  final VlessInbound? inbound;

  final String defaultEndpoint;
  final Future<Map<String, dynamic>?> Function(String target, String sni)?
  scanReality;

  /// Opens the REALITY target search; the form keeps its draft meanwhile.
  final Future<RealityTargetChoice?> Function(BuildContext context)? findTarget;

  /// The best result of a finished search on this server, offered to a new
  /// inbound.
  final RealityCandidate? suggested;
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

  /// An XHTTP inbound with the generic `/` path gets a generated one when
  /// its target is checked or chosen; a path of the person's own is kept.
  void _fillXhttpPath() {
    if (spec['transport'] == 'xhttp' &&
        isDefaultXhttpPath(fields['path']!.text)) {
      fields['path']!.text = newXhttpPath();
    }
  }

  /// Fills Target and SNI with a verified pair; SNI no longer follows Target.
  void useTarget(RealityTargetChoice choice) => setState(() {
    fields['target']!.text = choice.target;
    fields['sni']!.text = choice.sni;
    automaticSni = false;
    scanResult = null;
    scanFailed = false;
    _fillXhttpPath();
  });

  Future<void> findTarget() async {
    final choice = await widget.findTarget?.call(context);
    if (choice != null && mounted) useTarget(choice);
  }

  Future<void> scan() async {
    final target = normalizeRealityTarget(fields['target']!.text.trim());
    final sni = fields['sni']!.text.trim();
    setState(() {
      _fillXhttpPath();
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

  Widget field(
    String key,
    String label, {
    bool number = false,
    String? error,
  }) => TextField(
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
    decoration: InputDecoration(
      labelText: label,
      errorText: error,
      errorMaxLines: 4,
    ),
  );
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context),
        xhttp = spec['transport'] == 'xhttp',
        tls = spec['security'] == 'tls',
        reality = spec['security'] == 'reality',
        fingerprint = spec['fingerprint'] as String? ?? 'chrome';
    return AppFormDialog(
      title: const Text('VLESS'),
      icon: protocolIcon('xray'),
      subtitle: widget.inbound == null ? l.vpnAddInbound : l.vpnEdit,
      fullscreenOnCompact: true,
      content: AppFormFields(
        children: [
          AppFormSection(
            title: l.uiConnection,
            children: [
              field('name', l.vpnName),
              ServerAddressField(
                label: l.vpnListen,
                fieldKey: const ValueKey('vpn-inbound-listen'),
                network: widget.network,
                controller: fields['listen']!,
                motion: widget.motion,
              ),
              field('port', l.vpnPort, number: true),
            ],
          ),
          AppFormSection(
            title: l.vpnTransport,
            children: [
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
              if (xhttp)
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
              AppSelectField<String>(
                key: const ValueKey('vpn-inbound-utls'),
                value: fingerprint,
                label: 'uTLS',
                motion: widget.motion,
                options: [
                  for (final name in vlessFingerprints)
                    if (!reality ||
                        realityFingerprints.contains(name) ||
                        name == fingerprint)
                      (name, name),
                ],
                onChanged: (value) {
                  setState(() => spec['fingerprint'] = value);
                },
              ),
              if (reality && !realityFingerprints.contains(fingerprint))
                AppNotice(
                  key: const ValueKey('vpn-inbound-utls-reality'),
                  message: l.vpnRealityFingerprint,
                  error: true,
                ),
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
              ],
            ],
          ),
          AppFormSection(
            title: tls ? 'TLS' : 'REALITY',
            children: [
              if (!tls) ...[
                // A failed scan is a quiet field error, not the loudest
                // element of the form.
                field(
                  'target',
                  l.vpnTarget,
                  error: scanFailed ? l.realityScanFailed : null,
                ),
                AppFormActionRow(
                  actions: [
                    if (widget.findTarget != null)
                      AppFormAction(
                        buttonKey: const ValueKey('vpn-reality-find'),
                        icon: Icons.travel_explore,
                        label: l.realitySearchFind,
                        tooltip: l.realitySearchFindHelp,
                        onPressed: scanning ? null : findTarget,
                      ),
                    AppFormAction(
                      buttonKey: const ValueKey('vpn-reality-scan'),
                      icon: Icons.radar,
                      label: l.realityScan,
                      tooltip: l.realityScanHelp,
                      busy: scanning,
                      onPressed:
                          widget.scanReality == null ||
                              fields['target']!.text.trim().isEmpty
                          ? null
                          : scan,
                    ),
                  ],
                ),
                if (widget.suggested case final best?
                    when widget.inbound == null &&
                        fields['target']!.text != realityChoice(best).target)
                  Row(
                    children: [
                      Expanded(
                        child: AppFormHint(
                          l.realitySearchSuggested(best.target.sni, best.score),
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('vpn-reality-suggested'),
                        onPressed: () => useTarget(realityChoice(best)),
                        child: Text(l.realitySearchUse),
                      ),
                    ],
                  ),
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
                AppFormAction(
                  buttonKey: const ValueKey('vpn-reality-regenerate'),
                  icon: Icons.refresh,
                  label: l.vpnRegenerateReality,
                  onPressed: () => setState(() {
                    spec['realitySeed'] = newVpnId();
                    regenerated = true;
                  }),
                ),
                if (regenerated) AppFormHint(l.vpnRealityRegenerated),
              ],
              if (tls) ...[
                field('certificate', l.vpnCertificate),
                field('certificateKey', l.vpnCertificateKey),
                AppFormHint(l.vpnTlsHelp),
              ],
            ],
          ),
          if (xhttp)
            AppFormSection(
              rows: true,
              children: [
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
              ],
            ),
          if (invalid)
            AppNotice(
              message: l.vpnInvalid,
              error: true,
              margin: EdgeInsets.zero,
            ),
        ],
      ),
      actions: [
        // Deleting is its own confirmed action, not a form field applied by
        // "Save" (UI-54).
        if (widget.inbound case final inbound?)
          AppDangerButton.text(
            key: const ValueKey('vpn-inbound-delete'),
            onPressed: () async {
              final confirmed = await confirmAppDanger(
                context,
                title: l.vpnDeleteInbound,
                message: l.vpnDeleteHelp,
                confirmLabel: l.vpnDelete,
                cancelLabel: l.sshCancel,
                confirmKey: const ValueKey('vpn-inbound-delete-confirm'),
              );
              if (!confirmed || !context.mounted) return;
              Navigator.pop(
                context,
                VlessInbound(
                  serverId: widget.serverId,
                  spec: {...inbound.spec, 'deleted': true, 'enabled': false},
                ),
              );
            },
            icon: const Icon(Icons.delete_outline),
            child: Text(l.vpnDelete),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.sshCancel),
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
