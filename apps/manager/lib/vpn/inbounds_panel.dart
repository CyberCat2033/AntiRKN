import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../network/network_controller.dart';
import '../network/server_address_picker.dart';
import 'vpn_controller.dart';
import 'vpn_plan_view.dart';

class InboundsPanel extends StatelessWidget {
  const InboundsPanel({
    required this.controller,
    required this.serverId,
    required this.serverName,
    required this.network,
    required this.motion,
    super.key,
  });
  final VpnController controller;
  final String serverId;
  final String Function(String) serverName;
  final NetworkController network;
  final MotionPreference motion;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
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
            Text(l.vpnInboundHelp),
            Wrap(
              spacing: AppLayout.smallGap,
              children: [
                FilledButton.icon(
                  key: const ValueKey('vpn-inbound-add'),
                  onPressed: c.busy || !c.loaded ? null : () => _edit(context),
                  icon: const Icon(Icons.add),
                  label: Text(l.vpnAddInbound),
                ),
                TextButton(
                  onPressed: c.busy || c.remote(serverId) == null
                      ? null
                      : () => c.refreshServer(serverId),
                  child: Text(l.sshRefresh),
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
            if (inbounds.isEmpty) Text(l.vpnNoInbounds),
            for (final r in inbounds)
              Padding(
                padding: const EdgeInsets.only(top: AppLayout.gap),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(inboundSummary(r.spec)),
                    Text(r.enabled ? l.vpnEnabled : l.vpnDisabled),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        onPressed: c.busy ? null : () => _edit(context, r),
                        child: Text(l.vpnEdit),
                      ),
                    ),
                  ],
                ),
              ),
            VpnJobView(controller: c, serverId: serverId),
            VpnPlanView(controller: c, serverName: serverName),
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
    super.key,
  });
  final String serverId;
  final NetworkController network;
  final MotionPreference motion;
  final VlessInbound? inbound;
  @override
  State<InboundForm> createState() => _InboundFormState();
}

class _InboundFormState extends State<InboundForm> {
  late final Map<String, Object?> spec = {
    ...(widget.inbound?.spec ?? VlessInbound.defaults()),
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
  bool invalid = false;
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
      keyboardType: number ? TextInputType.number : null,
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
                  if (v == 'raw') {
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
              for (final role in AddressRole.values)
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
              field('endpoint', l.vpnEndpoint),
              field('externalPort', l.vpnExternalPort, number: true),
              field('sni', l.vpnSni),
              if (!tls) field('target', l.vpnTarget),
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
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.vpnRegion),
                value: spec['region'] == 'RU',
                onChanged: (v) =>
                    setState(() => spec['region'] = v == true ? 'RU' : ''),
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
