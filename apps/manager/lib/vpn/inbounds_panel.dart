import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../network/network_controller.dart';
import '../network/server_address_field.dart';
import 'vpn_controller.dart';
import 'observed_inbound_dialog.dart';
import 'xhttp_options_editor.dart';
import '../runner/runner_controller.dart';
import '../runner/panel_login_view.dart';
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppPageIntro(l.uiVlessIntro),
          if (runner != null &&
              (runner!.panelAccess == null || runner!.panelLoginRequired)) ...[
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
            onPressed: c.busy || !c.loaded ? null : () => _edit(context),
            icon: const Icon(Icons.add),
            label: Text(l.vpnAddInbound),
          ),
          const SizedBox(height: 20),
          AppSectionHeading(title: l.vpnInbounds),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (runner?.panelDetected == true &&
                  (runner?.panels.isEmpty ?? true))
                Text(l.panelDiscoveryFailed),
              if (inbounds.isEmpty &&
                  runner?.panelDiscovery?['failed'] != true &&
                  !(runner?.panelDetected == true &&
                      (runner?.panels.isEmpty ?? true)) &&
                  (runner?.panels.every(
                        (p) => (p['inbounds'] as List).isEmpty,
                      ) ??
                      true))
                AppEmptyState(title: l.vpnNoInbounds, icon: Icons.hub_outlined),
              for (final panel in runner?.panels ?? <Map<String, dynamic>>[])
                for (final observed in panel['inbounds'] as List)
                  if (!inbounds.any(
                    (r) =>
                        observed['name'] == 'AntiRKN:${c.workspace.id}:${r.id}',
                  ))
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: AppLayout.smallGap,
                      ),
                      child: ResourceTile(
                        storageId:
                            'observed-$serverId-${panel['port']}-${observed['id']}',
                        title: '${observed['name'] ?? ''}'.trim().isEmpty
                            ? "${'${observed['protocol']}'.toUpperCase()} · ${observed['port']}"
                            : '${observed['name']}',
                        subtitle:
                            '${observed['transport']} · ${observed['security']}',
                        badge: observed['enabled'] == true
                            ? l.vpnEnabled
                            : l.vpnDisabled,
                        note: l.vpnObserved,
                        detailsLabel: l.componentsDetails,
                        details: const [],
                        badgeBusy:
                            runner?.actionPending == true ||
                            runner?.selected?.kind == 'inbound_update' &&
                                runner?.selected?.terminal == false,
                        onBadgeTap: runner == null
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
                                await runner!.setInboundEnabled(
                                  observed['id'] as int,
                                  observed['enabled'] != true,
                                );
                              },
                        actions: IconButton(
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
                                        port: panel['port'] as int,
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
                                    builder: (context) => ObservedInboundDialog(
                                      controller: runner!,
                                      network: network,
                                      inboundId: observed['id'] as int,
                                      port: panel['port'] as int,
                                      motion: motion,
                                    ),
                                  );
                                },
                        ),
                      ),
                    ),
              for (final r in inbounds)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
                  child: ResourceTile(
                    key: ValueKey('inbound-summary-${r.id}'),
                    storageId: r.id,
                    title: r.spec['name'] as String,
                    subtitle:
                        '${r.spec['transport'].toString().toUpperCase()} · ${r.spec['security'].toString().toUpperCase()}',
                    badge: r.enabled ? l.vpnEnabled : l.vpnDisabled,
                    note: r.internal ? l.vpnInternal : l.vpnClientAccess,
                    detailsLabel: l.componentsDetails,
                    details: const [],
                    badgeBusy: c.busy,
                    onBadgeTap: c.busy
                        ? null
                        : () async {
                            if (runner != null &&
                                (!await showPanelLogin(context, runner!) ||
                                    !context.mounted)) {
                              return;
                            }
                            await c.saveInbound(
                              VlessInbound(
                                serverId: r.serverId,
                                spec: {...r.spec, 'enabled': !r.enabled},
                              ),
                            );
                            if (c.error == null) {
                              await c.prepareAndApply(serverIds: {r.serverId});
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
                                  if (c.error == null) {
                                    await c.prepareAndApply(
                                      serverIds: {r.serverId},
                                    );
                                  }
                                },
                        ),
                        IconButton(
                          tooltip: l.vpnEdit,
                          onPressed: c.busy ? null : () => _edit(context, r),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                      ],
                    ),
                  ),
                ),
              VpnJobView(
                showSnapshot: false,
                controller: c,
                serverId: serverId,
              ),
              if (showPlan) VpnPlanView(controller: c, serverName: serverName),
            ],
          ),
        ],
      );
    },
  );
  Future<void> _edit(BuildContext context, [VlessInbound? inbound]) async {
    if (runner != null &&
        (!await showPanelLogin(context, runner!) || !context.mounted)) {
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
              AppExpansionTile(
                key: const ValueKey('inbound-connection-address'),
                title: Text(l.vpnConnectionAddress),
                children: [
                  Text(l.vpnConnectionAddressHelp),
                  const SizedBox(height: AppLayout.gap),
                  field('endpoint', l.vpnEndpoint),
                  field('externalPort', l.vpnExternalPort, number: true),
                ],
              ),
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
