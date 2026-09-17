import 'external_connection_check.dart';
import 'connection_check_view.dart';
import 'dart:async';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../network/network_controller.dart';
import '../network/server_address_picker.dart';
import '../runner/runner_controller.dart';
import 'tt_certificates.dart';
import 'tt_dialog.dart';
import 'vpn_controller.dart';
import 'adopt_resource.dart';
import 'vpn_plan_view.dart';
import 'vpn_strings.dart';

class TtPanel extends StatefulWidget {
  const TtPanel({
    required this.controller,
    required this.serverId,
    required this.runner,
    required this.picker,
    required this.network,
    required this.motion,
    super.key,
  });
  final VpnController controller;
  final String serverId;
  final RunnerController runner;
  final PrivateKeyFilePicker picker;
  final NetworkController network;
  final MotionPreference motion;
  @override
  State<TtPanel> createState() => _TtPanelState();
}

class _TtPanelState extends State<TtPanel> {
  String? queried;
  bool querying = false;
  @override
  void initState() {
    super.initState();
    widget.runner.addListener(changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => changed());
  }

  @override
  void dispose() {
    widget.runner.removeListener(changed);
    super.dispose();
  }

  void changed() {
    final r = widget.runner;
    final key =
        '${r.identity()}|${r.selected?.terminal == true ? r.selected?.id : ''}';
    if (mounted &&
        !querying &&
        r.installed &&
        r.connected &&
        !r.busy &&
        queried != key) {
      queried = key;
      unawaited(refresh());
    }
  }

  Future<void> refresh() async {
    querying = true;
    try {
      await widget.runner.ttRequest('tt_discover');
      if (mounted) await widget.runner.ttRequest('tt_certificates');
    } finally {
      querying = false;
    }
  }

  Future<void> edit([TrustTunnelEndpoint? current]) async {
    if (!await widget.runner.ensureReady() || !mounted) return;
    if (current?.spec.containsKey('adoption') == true) {
      final spec = await editAdoptedResource(context, current!.spec);
      if (spec == null) return;
      await widget.controller.saveTt(
        TrustTunnelEndpoint(serverId: widget.serverId, spec: spec),
      );
      if (widget.controller.error == null) {
        await widget.controller.prepareAndApply(
          serverIds: {ttTarget(widget.serverId)},
        );
      }
      return;
    }
    final spec =
        current?.spec ?? await widget.controller.ttDefaults(widget.serverId);
    if (spec == null || !mounted) return;
    final value = await showDialog<TrustTunnelEndpoint>(
      context: context,
      builder: (_) => ManagedTtDialog(
        serverId: widget.serverId,
        spec: spec,
        runner: widget.runner,
        picker: widget.picker,
        network: widget.network,
        motion: widget.motion,
      ),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, widget.motion),
      ),
    );
    if (value == null) return;
    await widget.controller.saveTt(value);
    if (widget.controller.error == null) {
      if (value.deleted && current != null && !current.deleted) {
        AppHaptics.deleted();
      } else if (current == null && !value.deleted) {
        AppHaptics.added();
      }
    }
    if (widget.controller.error == null) {
      await widget.controller.prepareAndApply(
        serverIds: {ttTarget(widget.serverId)},
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, widget.runner]),
    builder: (context, _) {
      final l = AppLocalizations.of(context),
          c = widget.controller,
          r = widget.runner;
      final target = ttTarget(widget.serverId);
      final endpoints = c.workspace.ttEndpoints.where(
        (e) => e.serverId == widget.serverId && !e.deleted,
      );
      final external = (r.ttDiscovery?['resources'] as List? ?? [])
          .whereType<Map>()
          .where(
            (item) => !hasAdoptedSource(
              endpoints.map((r) => r.spec),
              item['id'] as String,
            ),
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppPageIntro(l.uiTtIntro),
          FilledButton.icon(
            onPressed: c.busy || !c.loaded || r.busy ? null : () => edit(),
            icon: const Icon(Icons.add),
            label: Text(l.ttAdd),
          ),
          ConnectionCheckAll(
            controller: c,
            readOthers: external.isEmpty
                ? null
                : () async {
                    final keys = <({String target, String resource})>[];
                    for (final item in external) {
                      if (!context.mounted) break;
                      final key = await prepareExternalConnection(
                        context,
                        controller: c,
                        runner: r,
                        serverId: widget.serverId,
                        protocol: 'tt',
                        source: item['id'] as String,
                      );
                      keys.add(
                        key ??
                            externalConnectionTarget(
                              widget.serverId,
                              'tt',
                              item['id'] as String,
                              null,
                            ),
                      );
                    }
                    return keys;
                  },
            targets: [
              for (final e in endpoints) (target: target, resource: e.id),
            ],
          ),
          const SizedBox(height: 20),
          AppSectionHeading(
            title: l.uiConnections,
            count: endpoints.length,
            action: IconButton(
              tooltip: l.awgRefresh,
              onPressed: c.busy || r.busy
                  ? null
                  : () async {
                      await c.refreshServer(target);
                      await refresh();
                    },
              icon: const Icon(Icons.refresh),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (endpoints.isEmpty)
                AppEmptyState(
                  title: l.uiTtSetup,
                  message: l.ttEmpty,
                  icon: Icons.shield_outlined,
                ),
              for (final e in endpoints)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
                  child: ResourceTile(
                    storageId: 'tt-${e.id}',
                    footer: ConnectionCheckView(
                      controller: c,
                      target: (target: target, resource: e.id),
                      onEdit: () => edit(e),
                    ),
                    title: e.name,
                    subtitle: '${e.spec['domain']}',
                    note: e.spec.containsKey('adoption')
                        ? c.adoptionConfirmed(target, e.id)
                              ? l.vpnClientAccess
                              : l.vpnAdopting
                        : null,
                    badge: e.enabled ? l.vpnEnabled : l.vpnDisabled,
                    detailsLabel: l.componentsDetails,
                    actions: IconButton(
                      onPressed: c.busy || r.busy ? null : () => edit(e),
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: l.vpnEdit,
                    ),
                    details: const [],
                  ),
                ),
              VpnJobView(showSnapshot: false, controller: c, serverId: target),
              for (final cert
                  in (r.ttCertificates?['certificates'] as List? ?? [])
                      .whereType<Map>()) ...[
                if (cert['error'] case final String issue)
                  Text('${cert['domain']}: ${vpnMessage(l, issue)}'),
                if ((cert['expiresAt'] as num) <
                    DateTime.now().millisecondsSinceEpoch / 1000 + 21 * 86400)
                  Text('${cert['domain']}: ${l.ttExpirySoon}'),
              ],
              const SizedBox(height: 20),
              AppSettingsSection(
                title: l.ttCertificates,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TtCertificates(
                    runner: r,
                    picker: widget.picker,
                    network: widget.network,
                    motion: widget.motion,
                    showTitle: false,
                  ),
                ),
              ),
              if ((r.ttDiscovery?['issues'] as List? ?? []).isNotEmpty ||
                  external.isNotEmpty) ...[
                const Divider(),
                Text(
                  l.awgObserved,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
              for (final issue
                  in (r.ttDiscovery?['issues'] as List? ?? []).whereType<Map>())
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${issue['name']}'),
                  subtitle: Text(vpnMessage(l, issue['code'] as String)),
                  leading: const Icon(Icons.info_outline),
                ),
              for (final item in external)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ResourceTile(
                    storageId: 'tt-existing-${item['id']}',
                    footer: ExternalConnectionCheck(
                      controller: c,
                      runner: r,
                      serverId: widget.serverId,
                      protocol: 'tt',
                      source: item['id'] as String,
                    ),
                    title: '${item['name']}',
                    subtitle: (item['hosts'] as List)
                        .map((h) => (h as Map)['domain'])
                        .join(', '),
                    note: l.uiPeerCount((item['users'] as List).length),
                    detailsLabel: l.componentsDetails,
                    details: const [],
                    actions: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: ValueKey('adopt-tt-${item['id']}'),
                          tooltip: l.vpnAdopt,
                          icon: const Icon(Icons.people_outline),
                          onPressed:
                              c.busy ||
                                  c.hasRunning ||
                                  r.busy ||
                                  r.actionPending
                              ? null
                              : () => adoptExistingResource(
                                  context,
                                  controller: c,
                                  runner: r,
                                  serverId: widget.serverId,
                                  protocol: 'tt',
                                  sourceId: item['id'] as String,
                                  motion: widget.motion,
                                ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: l.vpnEdit,
                          onPressed: r.busy
                              ? null
                              : () async {
                                  final snapshot = await r.ttRequest(
                                    'tt_external_read',
                                    id: item['id'] as String,
                                  );
                                  if (snapshot == null || !context.mounted) {
                                    return;
                                  }
                                  await showDialog<bool>(
                                    context: context,
                                    builder: (_) => _ExistingTtDialog(
                                      runner: r,
                                      snapshot: snapshot,
                                      network: widget.network,
                                      motion: widget.motion,
                                    ),
                                    animationStyle: AnimationStyle(
                                      duration: AppMotion.duration(
                                        context,
                                        widget.motion,
                                      ),
                                    ),
                                  );
                                },
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );
}

/// The listener, outbound and TLS controls are shared by both endpoint editors.
class TtSettingsEditor extends StatelessWidget {
  const TtSettingsEditor({
    required this.fields,
    required this.spec,
    required this.certificates,
    required this.network,
    required this.motion,
    required this.onChanged,
    this.external = false,
    this.enabled = true,
    this.onIssueCertificate,
    super.key,
  });
  final Map<String, TextEditingController> fields;
  final Map<String, Object?> spec;
  final List<Map> certificates;
  final NetworkController network;
  final MotionPreference motion;
  final VoidCallback onChanged;
  final VoidCallback? onIssueCertificate;
  final bool external, enabled;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Widget field(String k, String label, {bool number = false}) => Padding(
      padding: const EdgeInsets.only(bottom: AppLayout.gap),
      child: TextField(
        key: ValueKey('tt-$k'),
        controller: fields[k],
        enabled: enabled,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => onChanged(),
      ),
    );
    Widget picker(AddressRole role, String key) {
      final choices = network.choices(role);
      return ServerAddressPicker(
        role: role,
        choices: choices,
        selected: choices.where((c) => c.host == fields[key]!.text).firstOrNull,
        selectionIssue: null,
        motion: motion,
        enabled: enabled,
        onSelected: (c) {
          fields[key]!.text = c?.host ?? '';
          onChanged();
        },
      );
    }

    final id = spec['certificateId'] as String? ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!external) field('name', l.vpnNodeName),
        picker(AddressRole.listener, 'listen'),
        field('listen', l.networkListener),
        field('port', l.ttPort, number: true),
        field('domain', l.ttDomain),
        DropdownButtonFormField<String>(
          key: ValueKey('tt-certificate-$id-${certificates.length}'),
          initialValue: certificates.any((c) => c['id'] == id) ? id : '',
          isExpanded: true,
          decoration: InputDecoration(labelText: l.ttCertificates),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(
                external ? l.ttKeepCertificate : l.ttChooseCertificate,
              ),
            ),
            for (final c in certificates)
              DropdownMenuItem(
                value: c['id'] as String,
                child: Text('${c['domain']}'),
              ),
          ],
          onChanged: enabled
              ? (v) {
                  spec['certificateId'] = v!;
                  final c = certificates.where((c) => c['id'] == v).firstOrNull;
                  if (c != null) fields['domain']!.text = c['domain'] as String;
                  onChanged();
                }
              : null,
        ),
        if (certificates.isEmpty && !external) Text(l.ttNeedCertificate),
        if (onIssueCertificate != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const ValueKey('tt-issue-certificate'),
              onPressed: enabled && fields['domain']!.text.trim().isNotEmpty
                  ? onIssueCertificate
                  : null,
              icon: const Icon(Icons.add_moderator_outlined),
              label: Text(l.ttIssueAcme),
            ),
          ),
        const SizedBox(height: AppLayout.gap),
        DropdownButtonFormField<String>(
          initialValue: spec['outbound'] == 'socks5' ? 'socks5' : 'direct',
          isExpanded: true,
          decoration: InputDecoration(labelText: l.ttOutbound),
          items: [
            DropdownMenuItem(value: 'direct', child: Text(l.ttDirect)),
            const DropdownMenuItem(value: 'socks5', child: Text('SOCKS5')),
          ],
          onChanged: enabled
              ? (v) {
                  spec['outbound'] = v!;
                  onChanged();
                }
              : null,
        ),
        if (spec['outbound'] == 'socks5') ...[
          field('socksAddress', l.ttSocksAddress),
          Text(l.ttSocksHelp),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.ttQuic),
          value: spec['quic'] == true,
          onChanged: enabled
              ? (v) {
                  spec['quic'] = v;
                  onChanged();
                }
              : null,
        ),
        AppExpansionTile(
          key: ValueKey('tt-options-$external'),
          title: Text(l.awgAdvanced),
          children: [
            SwitchListTile(
              title: Text(l.ttIpv6),
              value: spec['ipv6'] == true,
              onChanged: enabled
                  ? (v) {
                      spec['ipv6'] = v;
                      onChanged();
                    }
                  : null,
            ),
            SwitchListTile(
              title: Text(l.ttAllowPrivate),
              value: spec['allowPrivate'] == true,
              onChanged: enabled
                  ? (v) {
                      spec['allowPrivate'] = v;
                      onChanged();
                    }
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

class ManagedTtDialog extends StatefulWidget {
  const ManagedTtDialog({
    required this.serverId,
    required this.spec,
    required this.runner,
    required this.picker,
    required this.network,
    required this.motion,
    super.key,
  });
  final String serverId;
  final Map<String, Object?> spec;
  final RunnerController runner;
  final PrivateKeyFilePicker picker;
  final NetworkController network;
  final MotionPreference motion;
  @override
  State<ManagedTtDialog> createState() => _ManagedTtState();
}

class _ManagedTtState extends State<ManagedTtDialog> {
  late final spec = Map<String, Object?>.from(widget.spec);
  late final fields = {
    for (final k in ['name', 'listen', 'port', 'domain', 'socksAddress'])
      k: TextEditingController(text: '${spec[k]}'),
  };
  bool invalid = false, rotate = false;
  String? pendingCertificateId;
  bool certificateDialogOpen = false;
  @override
  void initState() {
    super.initState();
    widget.runner.addListener(certificateChanged);
  }

  void certificateChanged() {
    if (!mounted) return;
    final certificates =
        (widget.runner.ttCertificates?['certificates'] as List? ?? [])
            .whereType<Map>();
    final certificate = certificates
        .where((c) => c['id'] == pendingCertificateId)
        .firstOrNull;
    setState(() {
      if (certificate != null) {
        if (certificate['domain'] ==
            fields['domain']!.text.trim().toLowerCase()) {
          spec['certificateId'] = certificate['id'];
        }
        pendingCertificateId = null;
      }
    });
  }

  Future<void> issueCertificate() async {
    final domain = fields['domain']!.text.trim().toLowerCase();
    final listen = fields['listen']!.text.trim();
    final id = newVpnId();
    final expectedIps = ['0.0.0.0', '::'].contains(listen)
        ? <String>[]
        : [listen];
    setState(() => certificateDialogOpen = true);
    final applied = await showDialog<bool>(
      context: context,
      builder: (_) => TtCertificateDialog(
        runner: widget.runner,
        picker: widget.picker,
        network: widget.network,
        motion: widget.motion,
        newCertificateId: id,
        initialMode: 'acme',
        initialDomain: domain,
        initialListen: listen,
        initialExpectedIps: expectedIps,
      ),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, widget.motion),
      ),
    );
    if (!mounted) return;
    setState(() {
      certificateDialogOpen = false;
      if (applied == true) pendingCertificateId = id;
    });
    if (applied == true) {
      await widget.runner.ttRequest('tt_certificates');
      certificateChanged();
    }
  }

  @override
  void dispose() {
    widget.runner.removeListener(certificateChanged);
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AppFormDialog(
      title: const Text('TrustTunnel'),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TtSettingsEditor(
                fields: fields,
                spec: spec,
                certificates:
                    (widget.runner.ttCertificates?['certificates'] as List? ??
                            [])
                        .whereType<Map>()
                        .toList(),
                network: widget.network,
                motion: widget.motion,
                enabled: !certificateDialogOpen && !widget.runner.busy,
                onIssueCertificate:
                    widget.runner.canStart && widget.runner.installed
                    ? issueCertificate
                    : null,
                onChanged: () => setState(() => invalid = false),
              ),
              if (pendingCertificateId != null) ...[
                Text(l.ttCertificatePending),
                if (widget.runner.selected case final job?) ...[
                  Text(vpnMessage(l, job.status)),
                  if (job.events.lastOrNull case final event?)
                    Text(vpnMessage(l, event.code)),
                ],
                TextButton(
                  onPressed: widget.runner.busy
                      ? null
                      : () async {
                          await widget.runner.refresh();
                          await widget.runner.ttRequest('tt_certificates');
                        },
                  child: Text(l.awgRefresh),
                ),
              ],
              SwitchListTile(
                title: Text(l.vpnEnabled),
                value: spec['enabled'] as bool,
                onChanged: (v) => setState(() {
                  spec['enabled'] = v;
                  if (v) spec['deleted'] = false;
                }),
              ),
              CheckboxListTile(
                title: Text(l.ttRotate),
                value: rotate,
                onChanged: (v) => setState(() => rotate = v!),
              ),
              CheckboxListTile(
                title: Text(l.vpnDeleteHelp),
                value: spec['deleted'] as bool,
                onChanged: (v) => setState(() {
                  spec['deleted'] = v!;
                  if (v) spec['enabled'] = false;
                }),
              ),
              if (invalid) Text(l.vpnInvalid),
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
          onPressed: certificateDialogOpen || widget.runner.busy
              ? null
              : () {
                  try {
                    for (final e in fields.entries) {
                      spec[e.key] = e.key == 'port'
                          ? int.parse(e.value.text)
                          : e.value.text.trim();
                    }
                    spec['domain'] = (spec['domain'] as String).toLowerCase();
                    spec['endpoint'] = spec['domain'];
                    spec['externalPort'] = spec['port'];
                    spec['rotation'] =
                        (widget.spec['rotation'] as int) + (rotate ? 1 : 0);
                    Navigator.pop(
                      context,
                      TrustTunnelEndpoint(
                        serverId: widget.serverId,
                        spec: spec,
                      ),
                    );
                  } on FormatException {
                    setState(() => invalid = true);
                  }
                },
          child: Text(l.vpnSave),
        ),
      ],
    );
  }
}

class _ExistingTtDialog extends StatefulWidget {
  const _ExistingTtDialog({
    required this.runner,
    required this.snapshot,
    required this.network,
    required this.motion,
  });
  final RunnerController runner;
  final Map<String, dynamic> snapshot;
  final NetworkController network;
  final MotionPreference motion;
  @override
  State<_ExistingTtDialog> createState() => _ExistingTtState();
}

class _ExistingTtState extends State<_ExistingTtDialog>
    with TtPlannedState<_ExistingTtDialog> {
  @override
  RunnerController get runner => widget.runner;
  @override
  String get planAction => 'tt_external_plan';
  @override
  String get jobKind => 'tt_external_edit';
  @override
  int get steps => 3;
  late final hosts = (widget.snapshot['hosts'] as List)
      .whereType<Map>()
      .toList();
  late final spec = <String, Object?>{
    ...Map<String, Object?>.from(widget.snapshot['values'] as Map),
    'hostIndex': 0,
    'domain': hosts.first['domain'],
    'certificateId': '',
  };
  late final fields = {
    for (final k in ['listen', 'port', 'domain', 'socksAddress'])
      k: TextEditingController(text: '${spec[k]}'),
  };
  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Map<String, Object?> buildPayload() {
    for (final e in fields.entries) {
      spec[e.key] = e.key == 'port'
          ? int.parse(e.value.text)
          : e.value.text.trim();
    }
    return {
      'resourceId': widget.snapshot['id'],
      'observedHash': widget.snapshot['fingerprint'],
      'changes': Map<String, Object?>.from(spec),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AppFormDialog(
      title: Text('${l.vpnEdit} · ${widget.snapshot['name']}'),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.ttPreserveUsers),
              Text((widget.snapshot['users'] as List).join(', ')),
              if (hosts.length > 1)
                DropdownButtonFormField<int>(
                  initialValue: 0,
                  isExpanded: true,
                  items: [
                    for (var i = 0; i < hosts.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text('${hosts[i]['domain']}'),
                      ),
                  ],
                  onChanged: busy || preview != null
                      ? null
                      : (v) {
                          spec['hostIndex'] = v!;
                          fields['domain']!.text = hosts[v]['domain'] as String;
                          spec['certificateId'] = '';
                          changed();
                        },
                ),
              TtSettingsEditor(
                fields: fields,
                spec: spec,
                certificates:
                    (runner.ttCertificates?['certificates'] as List? ?? [])
                        .whereType<Map>()
                        .toList(),
                network: widget.network,
                motion: widget.motion,
                external: true,
                enabled: !busy && preview == null,
                onChanged: changed,
              ),
              ...status(l),
            ],
          ),
        ),
      ),
      actions: actions(l),
    );
  }
}
