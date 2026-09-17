import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../runner/panel_login_view.dart';
import '../runner/runner_controller.dart';
import 'vpn_controller.dart';
import 'vpn_strings.dart';

Map<String, Object?> adoptionSpec(String protocol, Map snapshot, String host) {
  final row = protocol == 'vless' ? snapshot['row'] as Map : snapshot;
  final values = row['values'] as Map? ?? {};
  final port = protocol == 'vless'
      ? row['port'] as int
      : protocol == 'awg'
      ? int.parse('${values['ListenPort']}')
      : values['port'] as int;
  final name = '${row[protocol == 'vless' ? 'remark' : 'name'] ?? ''}'.trim();
  final spec = <String, Object?>{
    'id': newVpnId(),
    'name': name.isEmpty ? '${protocol.toUpperCase()} · $port' : name,
    'enabled': row[protocol == 'vless' ? 'enable' : 'active'] == true,
    'deleted': false,
    'port': port,
    'externalPort': row['externalPort'] as int? ?? port,
    'endpoint': host,
    'adoption': {
      'sourceId': '${row['id']}',
      'observedHash': snapshot['fingerprint'],
    },
  };
  if (protocol == 'vless') {
    final raw = row['streamSettings'];
    final stream = (raw is String ? jsonDecode(raw) : raw) as Map? ?? {};
    spec.addAll({
      'transport': stream['network'] ?? 'tcp',
      'security': stream['security'] ?? 'none',
    });
  } else if (protocol == 'awg') {
    spec.addAll({
      'pool': row['pool'] ?? '',
      'pool6': row['pool6'] ?? '',
      'mtu': int.tryParse('${values['MTU']}') ?? 1280,
      'keepalive': 25,
    });
  } else {
    final hosts = (row['hosts'] as List).whereType<Map>();
    if (hosts.isEmpty) throw const FormatException('vpn_adoption_unsupported');
    spec.addAll({
      'domain': hosts.first['domain'],
      'endpoint': hosts.first['domain'],
      for (final key in ['listen', 'quic', 'outbound', 'socksAddress'])
        key: values[key],
    });
  }
  return spec;
}

bool hasAdoptedSource(
  Iterable<Map<String, Object?>> resources,
  Object source,
) => resources.any(
  (spec) => (spec['adoption'] as Map?)?['sourceId'] == '$source',
);

Future<void> adoptExistingResource(
  BuildContext context, {
  required VpnController controller,
  required RunnerController runner,
  required String serverId,
  required String protocol,
  required Object sourceId,
  required MotionPreference motion,
  String host = '',
  int? panelPort,
}) async {
  final l = AppLocalizations.of(context);
  final target = protocol == 'awg'
      ? awgTarget(serverId)
      : protocol == 'tt'
      ? ttTarget(serverId)
      : serverId;
  try {
    if (protocol == 'vless') {
      if (!await showPanelLogin(context, runner, port: panelPort) ||
          !context.mounted) {
        return;
      }
    } else if (!await runner.ensureReady() || !context.mounted) {
      return;
    }
    final identity = controller.remote(target)?.identity;
    if (identity == null) throw const FormatException('vpn_connection');
    final snapshot = protocol == 'vless'
        ? await runner.readInbound(sourceId as int)
        : protocol == 'awg'
        ? await runner.awgRequest('awg_external_read', id: '$sourceId')
        : await runner.ttRequest('tt_external_read', id: '$sourceId');
    if (!context.mounted) return;
    if (snapshot == null) {
      throw FormatException(runner.responseCode ?? 'vpn_adoption_failed');
    }
    final spec = adoptionSpec(protocol, snapshot, host);
    if (protocol == 'vless') {
      spec['adoption'] = <String, Object?>{
        ...Map<String, Object?>.from(spec['adoption'] as Map),
        'panelId': runner.panelAccess!.id,
        'panelPort': panelPort ?? runner.panelAccess!.port,
      };
    }
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => AdoptedResourceDialog(spec: spec, consent: true),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, motion),
      ),
    );
    if (result == null || !context.mounted) return;
    await controller.adoptResource(
      target: target,
      expectedIdentity: identity,
      spec: result,
    );
    if (controller.error != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(vpnMessage(l, controller.error!))));
    }
  } on FormatException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(vpnMessage(l, error.message))));
    }
  }
}

Future<Map<String, Object?>?> editAdoptedResource(
  BuildContext context,
  Map<String, Object?> spec,
) => showDialog<Map<String, Object?>>(
  context: context,
  builder: (_) => AdoptedResourceDialog(spec: spec),
);

class AdoptedResourceDialog extends StatefulWidget {
  const AdoptedResourceDialog({
    required this.spec,
    this.consent = false,
    super.key,
  });
  final Map<String, Object?> spec;
  final bool consent;
  @override
  State<AdoptedResourceDialog> createState() => _AdoptedResourceDialogState();
}

class _AdoptedResourceDialogState extends State<AdoptedResourceDialog> {
  late final name = TextEditingController(text: widget.spec['name'] as String);
  late final endpoint = TextEditingController(
    text: widget.spec['endpoint'] as String,
  );
  late final port = TextEditingController(
    text: '${widget.spec['externalPort']}',
  );
  bool invalid = false;
  @override
  void dispose() {
    name.dispose();
    endpoint.dispose();
    port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (widget.consent) {
      return AlertDialog(
        title: Text(l.vpnAdopt),
        content: Text(l.vpnAdoptWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.sshCancel),
          ),
          FilledButton(
            key: const ValueKey('adopt-confirm'),
            onPressed: () =>
                Navigator.pop(context, Map<String, Object?>.from(widget.spec)),
            child: Text(l.vpnAdopt),
          ),
        ],
      );
    }
    return AppFormDialog(
      title: Text(l.vpnEdit),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('adopt-name'),
                controller: name,
                decoration: InputDecoration(labelText: l.vpnName),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('adopt-endpoint'),
                controller: endpoint,
                autocorrect: false,
                decoration: InputDecoration(labelText: l.vpnEndpoint),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('adopt-port'),
                controller: port,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l.vpnExternalPort),
              ),
              if (invalid) Text(l.vpnInvalid),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.sshCancel),
        ),
        FilledButton(
          key: const ValueKey('adopt-confirm'),
          onPressed: () {
            final value = int.tryParse(port.text.trim());
            if (value == null ||
                value < 1 ||
                value > 65535 ||
                name.text.trim().isEmpty ||
                name.text.trim().length > 80 ||
                !RegExp(r'^[A-Za-z0-9:.\-]+$').hasMatch(endpoint.text.trim()) ||
                ['', '0.0.0.0', '::'].contains(endpoint.text.trim())) {
              setState(() => invalid = true);
              return;
            }
            Navigator.pop(context, <String, Object?>{
              ...widget.spec,
              'name': name.text.trim(),
              'endpoint': endpoint.text.trim(),
              'externalPort': value,
            });
          },
          child: Text(l.vpnSave),
        ),
      ],
    );
  }
}
