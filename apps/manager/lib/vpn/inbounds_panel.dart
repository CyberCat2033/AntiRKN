import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../network/network_controller.dart';
import '../network/server_address_picker.dart';
import 'vpn_controller.dart';
import 'observed_inbound_dialog.dart';
import 'xhttp_options_editor.dart';
import '../runner/runner_controller.dart';
import 'vpn_plan_view.dart';
import 'reality_scan_result.dart';

class InboundsPanel extends StatelessWidget {
  const InboundsPanel({
    required this.controller,
    this.runner,
    this.showPlan = true,
    this.serverHost = '',
    required this.serverId,
    required this.serverName,
    required this.network,
    required this.motion,
    super.key,
  });
  final VpnController controller;
  final bool showPlan;
  final RunnerController? runner;
  final String serverHost;
  final String serverId;
  final String Function(String) serverName;
  final NetworkController network;
  final MotionPreference motion;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, runner]),
    builder: (context, _) {
      final c = controller,
          l = AppLocalizations.of(context),
          inbounds = c.workspace.inbounds.where(
            (r) => r.serverId == serverId && !r.deleted,
          );
      return SectionCard(
        title: l.vpnInbounds,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: AppLayout.smallGap,
              children: [
                FilledButton.icon(
                  key: const ValueKey('vpn-inbound-add'),
                  onPressed: c.busy || !c.loaded ? null : () => _edit(context),
                  icon: const Icon(Icons.add),
                  label: Text(l.vpnAddInbound),
                ),
                OutlinedButton(
                  onPressed: c.busy || c.workspace.inbounds.isEmpty
                      ? null
                      : c.prepare,
                  child: Text(l.vpnPrepare),
                ),
              ],
            ),
            if (c.remote(serverId) == null) Text(l.vpnPanelRequired),
            if (runner?.panelDetected == true &&
                (runner?.panels.isEmpty ?? true))
              Text(l.panelDiscoveryFailed),
            if (inbounds.isEmpty &&
                runner?.panelDiscovery?['failed'] != true &&
                !(runner?.panelDetected == true &&
                    (runner?.panels.isEmpty ?? true)) &&
                (runner?.panels.every((p) => (p['inbounds'] as List).isEmpty) ??
                    true))
              Text(l.vpnNoInbounds),
            for (final panel in runner?.panels ?? <Map<String, dynamic>>[])
              for (final observed in panel['inbounds'] as List)
                if (!inbounds.any(
                  (r) =>
                      observed['name'] == 'AntiRKN:${c.workspace.id}:${r.id}',
                ))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${observed['name']} · ${observed['protocol']}',
                    ),
                    subtitle: Text(
                      '${observed['listen']}:${observed['port']} · ${observed['transport']} / ${observed['security']}\n${observed['enabled'] == true ? l.vpnEnabled : l.vpnDisabled} · ${l.vpnObserved}',
                    ),
                    trailing: IconButton(
                      tooltip: l.vpnEdit,
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: runner?.canPlan != true
                          ? null
                          : () => showDialog<void>(
                              context: context,
                              builder: (context) => ObservedInboundDialog(
                                controller: runner!,
                                inboundId: observed['id'] as int,
                                port: panel['port'] as int,
                                motion: motion,
                              ),
                            ),
                    ),
                  ),
            for (final r in inbounds)
              Padding(
                padding: const EdgeInsets.only(top: AppLayout.gap),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(inboundSummary(r.spec)),
                    Text(r.enabled ? l.vpnEnabled : l.vpnDisabled),
                    Text(r.internal ? l.vpnInternal : l.vpnClientAccess),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Wrap(
                        children: [
                          IconButton(
                            key: ValueKey('vpn-internal-${r.id}'),
                            tooltip: r.internal
                                ? l.vpnInternal
                                : l.vpnClientAccess,
                            icon: Icon(
                              r.internal ? Icons.lock : Icons.lock_open,
                            ),
                            onPressed: c.busy
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
                                    if (c.error == null) await c.prepare();
                                  },
                          ),
                          TextButton(
                            onPressed: c.busy ? null : () => _edit(context, r),
                            child: Text(l.vpnEdit),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            VpnJobView(controller: c, serverId: serverId),
            if (showPlan) VpnPlanView(controller: c, serverName: serverName),
          ],
        ),
      );
    },
  );
  Future<void> _edit(BuildContext context, [VlessInbound? inbound]) async {
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
    if (controller.error == null) await controller.prepare();
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
      'endpoint',
      'externalPort',
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

  late bool automaticPort = spec['port'] == spec['externalPort'];
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
        if (key == 'port' && automaticPort) {
          fields['externalPort']!.text = value;
        }
        if (key == 'externalPort') {
          automaticPort = value == fields['port']!.text;
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
    return AlertDialog(
      title: Text(widget.inbound == null ? l.vpnAddInbound : l.vpnEdit),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field('name', l.vpnName),
              DropdownButtonFormField<String>(
                key: ValueKey('transport-${spec['transport']}'),
                initialValue: spec['transport'] as String,
                isExpanded: true,
                decoration: InputDecoration(labelText: l.vpnTransport),
                items: const [
                  DropdownMenuItem(
                    value: 'raw',
                    child: Text('RAW/TCP · Vision'),
                  ),
                  DropdownMenuItem(value: 'xhttp', child: Text('XHTTP')),
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
                DropdownButtonFormField<String>(
                  key: ValueKey('security-${spec['security']}'),
                  initialValue: spec['security'] as String,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l.vpnSecurity),
                  items: const [
                    DropdownMenuItem(value: 'reality', child: Text('REALITY')),
                    DropdownMenuItem(value: 'tls', child: Text('TLS')),
                  ],
                  onChanged: (v) => setState(() {
                    spec['security'] = v;
                    spec['mode'] = 'auto';
                  }),
                ),
                const SizedBox(height: AppLayout.gap),
              ],
              for (final role in [AddressRole.listener])
                Padding(
                  padding: const EdgeInsets.only(bottom: AppLayout.gap),
                  child: ServerAddressPicker(
                    role: role,
                    choices: widget.network.choices(role),
                    selected: widget.network
                        .choices(role)
                        .where(
                          (c) =>
                              c.host ==
                              fields[role == AddressRole.listener
                                      ? 'listen'
                                      : 'endpoint']!
                                  .text,
                        )
                        .firstOrNull,
                    selectionIssue: null,
                    onSelected: (choice) {
                      if (choice != null) {
                        setState(
                          () =>
                              fields[role == AddressRole.listener
                                          ? 'listen'
                                          : 'endpoint']!
                                      .text =
                                  choice.host,
                        );
                      }
                    },
                    motion: widget.motion,
                  ),
                ),
              field('listen', l.vpnListen),
              field('port', l.vpnPort, number: true),
              ExpansionTile(
                key: const ValueKey('inbound-connection-address'),
                title: Text(l.vpnConnectionAddress),
                children: [
                  Text(l.vpnConnectionAddressHelp),
                  const SizedBox(height: AppLayout.gap),
                  field('endpoint', l.vpnEndpoint),
                  field('externalPort', l.vpnExternalPort, number: true),
                ],
              ),
              DropdownButtonFormField<String>(
                key: const ValueKey('vpn-inbound-utls'),
                initialValue: spec['fingerprint'] as String? ?? 'chrome',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'uTLS'),
                items: [
                  for (final name in vlessFingerprints)
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: (value) {
                  if (value != null) spec['fingerprint'] = value;
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
                DropdownButtonFormField<String>(
                  key: ValueKey('mode-${spec['mode']}-$tls'),
                  initialValue: spec['mode'] as String,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l.vpnMode),
                  items: [
                    for (final mode in [
                      'auto',
                      'stream-one',
                      if (tls) 'packet-up',
                      if (tls) 'stream-up',
                    ])
                      DropdownMenuItem(value: mode, child: Text(mode)),
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
              final values = <String, Object?>{
                ...spec,
                for (final e in fields.entries)
                  e.key: ['port', 'externalPort'].contains(e.key)
                      ? int.tryParse(e.value.text.trim())
                      : e.value.text.trim(),
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
