import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../runner/panel_login_view.dart';
import '../runner/egress_strings.dart';
import '../runner/runner_controller.dart';
import '../runner/runner_panel.dart';
import '../vpn/vpn_controller.dart';
import 'server_catalog_controller.dart';

class ClientEgressCard extends StatefulWidget {
  const ClientEgressCard({
    required this.controller,
    this.catalog,
    this.vpn,
    this.motion = MotionPreference.system,
    super.key,
  });
  final RunnerController controller;
  final ServerCatalogController? catalog;
  final VpnController? vpn;
  final MotionPreference motion;

  @override
  State<ClientEgressCard> createState() => _ClientEgressCardState();
}

class _ClientEgressCardState extends State<ClientEgressCard> {
  bool opening = false;
  bool dialogOpen = false;
  String? issue;

  Future<void> configure() async {
    setState(() {
      opening = true;
      issue = null;
    });
    final c = widget.controller;
    try {
      if (!await c.ensureReady() || !mounted) {
        if (mounted) setState(() => issue = c.responseCode ?? 'egress_failed');
        return;
      }
      if (!c.panelDetected) {
        setState(() => issue = 'egress_panel_required');
        return;
      }
      if (!await showPanelLogin(context, c) || !mounted) return;
      await c.refreshEgress();
      if (!mounted) return;
      if (c.egress == null) {
        setState(() => issue = c.responseCode ?? 'egress_failed');
        return;
      }
      if (mounted) {
        setState(() {
          opening = false;
          dialogOpen = true;
        });
      }
      await showDialog<void>(
        context: context,
        builder: (_) => ClientEgressForm(
          controller: c,
          catalog: widget.catalog,
          vpn: widget.vpn,
          motion: widget.motion,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          opening = false;
          dialogOpen = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, l = AppLocalizations.of(context);
      final info = c.egress;
      final enabled = info?['enabled'] == true;
      final job = c.jobs.where((j) => j.kind == 'egress_apply').firstOrNull;
      final busy =
          opening || dialogOpen || c.busy || c.actionPending || job?.terminal == false;
      final check = info?['lastCheck'] as Map?;
      final failure =
          issue ??
          (c.responseCode?.startsWith('egress_') == true
              ? c.responseCode
              : null);
      return Card.filled(
        key: const ValueKey('client-egress-card'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.alt_route),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l.egressTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Switch(
                    key: const ValueKey('client-egress-switch'),
                    value: enabled,
                    onChanged: busy || !c.canRequestAction
                        ? null
                        : (value) async {
                            if (value) {
                              await configure();
                              return;
                            }
                            final ok = await c.applyEgress(
                              enabled: false,
                              uri: '',
                            );
                            if (!ok && mounted) {
                              setState(
                                () => issue = c.responseCode ?? 'egress_failed',
                              );
                            }
                          },
                  ),
                ],
              ),
              Text(
                info == null
                    ? l.egressUnknown
                    : enabled
                    ? '${info['name']} · ${info['host']}:${info['port']}'
                    : l.egressDirect,
              ),
              const SizedBox(height: 4),
              Text(
                l.egressClientTraffic,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (check != null && enabled)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${l.egressChecked} · ${check['tcpMs']} ms · '
                    '${DateTime.fromMillisecondsSinceEpoch(((check['checkedAt'] as num) * 1000).round()).toLocal()}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (job != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    job.events.isNotEmpty && job.status != 'succeeded'
                        ? runnerEventLabel(l, job.events.last.code)
                        : runnerStateLabel(l, job.status),
                  ),
                ),
              if (busy && !dialogOpen)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(),
                ),
              if (failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(egressIssue(l, failure)),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    key: const ValueKey('client-egress-configure'),
                    onPressed: busy || !c.canRequestAction ? null : configure,
                    icon: const Icon(Icons.settings_outlined),
                    label: Text(l.egressConfigure),
                  ),
                  if (enabled)
                    TextButton.icon(
                      key: const ValueKey('client-egress-check'),
                      onPressed: busy || !c.canRequestAction
                          ? null
                          : () async {
                              setState(() => issue = null);
                              await c.checkEgress();
                              if (mounted) setState(() {});
                            },
                      icon: const Icon(Icons.network_check),
                      label: Text(l.egressCheck),
                    ),
                  if (issue == 'egress_panel_required')
                    TextButton(
                      onPressed: busy ? null : () => c.installOrUpdate('panel'),
                      child: Text(l.egressInstallPanel),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class ClientEgressForm extends StatefulWidget {
  const ClientEgressForm({
    required this.controller,
    this.catalog,
    this.vpn,
    this.motion = MotionPreference.system,
    super.key,
  });
  final RunnerController controller;
  final ServerCatalogController? catalog;
  final VpnController? vpn;
  final MotionPreference motion;
  @override
  State<ClientEgressForm> createState() => _ClientEgressFormState();
}

class _ClientEgressFormState extends State<ClientEgressForm> {
  final uri = TextEditingController(), socks = TextEditingController();
  static const externalChoice = 'vless://';
  bool visible = false, busy = false, fromCatalog = false;
  String? target, issue;
  int? inbound;
  late final String observedHash;
  List<Map> inbounds = [];

  @override
  void initState() {
    super.initState();
    observedHash = widget.controller.egress!['observedHash'] as String;
    uri.text = widget.controller.egress?['uri'] as String? ?? '';
    final savedPort = widget.controller.egress?['socksPort'] as int?;
    socks.text = '${savedPort != null && savedPort > 0 ? savedPort : 1080}';
    fromCatalog =
        uri.text.isEmpty &&
        (widget.catalog?.servers.any(
              (s) => s.id != widget.controller.serverId,
            ) ??
            false);
  }

  @override
  void dispose() {
    for (final field in [uri, socks]) {
      field.dispose();
    }
    super.dispose();
  }

  VlessInbound? inboundResource(Map row) {
    final vpn = widget.vpn;
    return vpn?.workspace.inbounds
        .where(
          (r) =>
              r.serverId == target &&
              !r.deleted &&
              ((r.spec['adoption'] as Map?)?['sourceId'] == '${row['id']}' ||
                  row['name'] ==
                      'AntiRKN:${vpn.workspace.resourceWorkspaceId(r.serverId)}:${r.id}'),
        )
        .firstOrNull;
  }

  String inboundLabel(Map row) {
    final resource = inboundResource(row);
    return resource?.name ??
        ((row['name'] as String?)?.isNotEmpty == true
            ? row['name'] as String
            : 'VLESS');
  }

  Future<void> selectServer(String? id) async {
    setState(() {
      fromCatalog = id != externalChoice;
      target = fromCatalog ? id : null;
      inbound = null;
      inbounds = [];
      busy = true;
      issue = null;
    });
    try {
      if (!fromCatalog ||
          id == null ||
          !await widget.catalog!.connectForAction(id) ||
          !mounted) {
        return;
      }
      final session = widget.catalog!.sessionFor(id)!;
      if (!await showPanelLogin(context, session.runner) || !mounted) return;
      inbounds = [
        for (final panel in session.runner.panels)
          if (panel['port'] == session.runner.panelAccess?.port)
            for (final row in panel['inbounds'] as List)
              if (row['protocol'] == 'vless' && row['enabled'] == true)
                row as Map,
      ];
      if (inbounds.isNotEmpty) {
        inbound = inbounds.first['id'] as int;
      } else {
        issue = 'egress_unsupported';
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> apply() async {
    setState(() {
      busy = true;
      issue = null;
    });
    try {
      var link = uri.text.trim();
      final port = int.tryParse(socks.text.trim());
      if (port == null || port != 0 && (port < 1024 || port > 65535)) {
        setState(() => issue = 'egress_port_busy');
        return;
      }
      if (fromCatalog) {
        final remote = target == null
            ? null
            : widget.catalog?.sessionFor(target!)?.runner;
        final row = inbounds.where((r) => r['id'] == inbound).firstOrNull;
        if (remote == null || row == null) {
          setState(() => issue = 'egress_invalid');
          return;
        }
        final destination = clientEgressDestination(
          row: row,
          resource: inboundResource(row),
          sshHost: widget.catalog!.sessionFor(target!)!.host.text.trim(),
        );
        final issued = await remote.createEgressAccess(
          source: widget.controller.serverId,
          inboundId: inbound!,
          endpoint: destination.host,
          externalPort: destination.port,
        );
        if (!mounted) return;
        if (issued == null) {
          setState(() => issue = remote.responseCode ?? 'egress_failed');
          return;
        }
        final label =
            '${widget.catalog!.serverDisplayName(target!)} · ${inboundLabel(inbounds.firstWhere((r) => r['id'] == inbound))}';
        link = Uri.parse(issued)
            .replace(fragment: String.fromCharCodes(label.runes.take(128)))
            .toString();
        uri.text = link;
      }
      if (!validEgressLink(link)) {
        setState(() => issue = 'egress_invalid');
        return;
      }
      final ok = await widget.controller.applyEgress(
        enabled: true,
        uri: link,
        socksPort: port,
        observedHash: observedHash,
      );
      if (!mounted) return;
      if (ok || widget.controller.pending?.json['kind'] == 'egress_apply') {
        Navigator.pop(context);
      } else {
        setState(
          () => issue = widget.controller.responseCode ?? 'egress_failed',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final servers =
        widget.catalog?.servers
            .where((s) => s.id != widget.controller.serverId)
            .toList() ??
        <SavedServer>[];
    final parsed = Uri.tryParse(uri.text.trim());
    return PopScope(
      canPop: !busy,
      child: AppFormDialog(
        title: Text(l.egressTitle),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (servers.isNotEmpty) ...[
              AppSelectField<String>(
                key: const ValueKey('client-egress-server'),
                value: fromCatalog ? target ?? '' : externalChoice,
                label: l.egressTarget,
                motion: widget.motion,
                options: [
                  for (final server in servers)
                    (server.id, widget.catalog!.serverDisplayName(server.id)),
                  (externalChoice, l.egressLink),
                ],
                onChanged: busy ? null : selectServer,
              ),
              const SizedBox(height: 16),
            ],
            if (fromCatalog) ...[
              AppSelectField<int?>(
                key: const ValueKey('client-egress-inbound'),
                value: inbound,
                label: 'VLESS inbound',
                motion: widget.motion,
                options: [
                  for (final row in inbounds)
                    (row['id'] as int, '${inboundLabel(row)} · ${row['port']}'),
                ],
                onChanged: busy || inbounds.isEmpty
                    ? null
                    : (v) => setState(() => inbound = v),
              ),
            ] else ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('client-egress-uri'),
                controller: uri,
                enabled: !busy,
                obscureText: !visible,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.egressLink,
                  hintText: 'vless://…',
                  suffixIcon: IconButton(
                    tooltip: l.egressReveal,
                    icon: Icon(
                      visible ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => visible = !visible),
                  ),
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          final data = await Clipboard.getData(
                            Clipboard.kTextPlain,
                          );
                          if (mounted && data?.text != null) {
                            setState(() => uri.text = data!.text!.trim());
                          }
                        },
                  icon: const Icon(Icons.content_paste),
                  label: Text(l.egressPaste),
                ),
              ),
              if (parsed != null && validEgressLink(uri.text.trim()))
                Text(
                  '${parsed.host}:${parsed.port} · ${parsed.queryParameters['type'] ?? 'tcp'} · ${parsed.queryParameters['security'] ?? ''}',
                ),
            ],
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('client-egress-port'),
              controller: socks,
              enabled: !busy && widget.controller.egress?['enabled'] != true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l.egressSocksPort,
                helperText: l.egressSocksHelp,
                helperMaxLines: 3,
              ),
            ),
            if (issue != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(egressIssue(l, issue!)),
              ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: Text(l.sshCancel),
          ),
          FilledButton(
            key: const ValueKey('client-egress-apply'),
            onPressed: busy ? null : apply,
            child: Text(l.egressApply),
          ),
        ],
      ),
    );
  }
}

({String host, int port}) clientEgressDestination({
  required Map row,
  required String sshHost,
  VlessInbound? resource,
}) {
  // A saved endpoint may describe NAT or a public hostname. Otherwise use
  // the selected listener; the SSH host can be a different server address.
  final savedHost = (resource?.spec['endpoint'] as String?)?.trim() ?? '';
  if (savedHost.isNotEmpty) {
    return (host: savedHost, port: resource!.spec['externalPort'] as int);
  }
  final listen = (row['listen'] as String?)?.trim() ?? '';
  final ip = IpAddress.tryParse(listen);
  final concrete =
      ip != null &&
      !const {
        IpCategory.unspecified,
        IpCategory.loopback,
        IpCategory.linkLocal,
        IpCategory.multicast,
      }.contains(ip.category);
  return (host: concrete ? listen : sshHost, port: row['port'] as int);
}

bool validEgressLink(String value) {
  try {
    final uri = Uri.parse(value);
    return value.length <= 16384 &&
        uri.scheme == 'vless' &&
        uri.host.isNotEmpty &&
        uri.hasPort &&
        uri.port > 0 &&
        uri.port <= 65535 &&
        RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(uri.userInfo);
  } on FormatException {
    return false;
  }
}
