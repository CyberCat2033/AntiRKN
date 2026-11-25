import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../runner/panel_login_view.dart';
import '../runner/runner_controller.dart';
import 'adopt_resource.dart';
import 'connection_check_view.dart';
import 'connection_checks.dart';
import 'vpn_controller.dart';

ConnectionTarget externalConnectionTarget(
  String serverId,
  String protocol,
  Object source,
  int? panelPort,
) => (
  target: protocol == 'awg'
      ? awgTarget(serverId)
      : protocol == 'tt'
      ? ttTarget(serverId)
      : serverId,
  resource: sha256
      .convert(utf8.encode('$serverId/$protocol/$panelPort/$source'))
      .toString()
      .substring(0, 32),
);

Future<ConnectionTarget?> prepareExternalConnection(
  BuildContext context, {
  required VpnController controller,
  required RunnerController runner,
  required String serverId,
  required String protocol,
  required Object source,
  String host = '',
  int? panelPort,
}) async {
  try {
    if (protocol == 'vless') {
      if (!await showPanelLogin(context, runner, port: panelPort) ||
          !context.mounted) {
        return null;
      }
    } else if (!await runner.ensureReady()) {
      return null;
    }
    final key = externalConnectionTarget(serverId, protocol, source, panelPort);
    final identity = controller.remote(key.target)?.identity;
    if (identity == null) return null;
    final snapshot = protocol == 'vless'
        ? await runner.readInbound(source as int)
        : protocol == 'awg'
        ? await runner.awgRequest('awg_external_read', id: '$source')
        : await runner.ttRequest('tt_external_read', id: '$source');
    if (snapshot == null) return null;
    final spec = adoptionSpec(protocol, snapshot, host)..['id'] = key.resource;
    if (protocol == 'vless') {
      spec['adoption'] = {
        ...Map<String, Object?>.from(spec['adoption'] as Map),
        'panelId': runner.panelAccess!.id,
        'panelPort': panelPort ?? runner.panelAccess!.port,
      };
    }
    return controller.connections.registerExternal(key.target, spec, identity);
  } catch (_) {
    return null;
  }
}

class ExternalConnectionCheck extends StatefulWidget {
  const ExternalConnectionCheck({
    required this.controller,
    required this.runner,
    required this.serverId,
    required this.protocol,
    required this.source,
    this.host = '',
    this.panelPort,
    this.onEdit,
    super.key,
  });
  final VpnController controller;
  final RunnerController runner;
  final String serverId, protocol, host;
  final Object source;
  final int? panelPort;
  final VoidCallback? onEdit;
  @override
  State<ExternalConnectionCheck> createState() =>
      _ExternalConnectionCheckState();
}

class _ExternalConnectionCheckState extends State<ExternalConnectionCheck> {
  bool reading = false, unavailable = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Check progress is not forwarded through the VPN controller.
    listenable: Listenable.merge([
      widget.controller,
      widget.controller.connections,
      widget.runner,
    ]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final l = AppLocalizations.of(context), c = widget.controller.connections;
    final key = externalConnectionTarget(
      widget.serverId,
      widget.protocol,
      widget.source,
      widget.panelPort,
    );
    final result = c.result(key), running = c.current == key;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reading || running) Text(l.connectionChecking),
        if (!running && result != null) Text(connectionCheckMessage(l, result)),
        if (unavailable) Text(l.connectionAccessRequired),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: running
                  ? c.cancel
                  : reading ||
                        c.busy ||
                        widget.controller.busy ||
                        widget.runner.busy ||
                        widget.runner.actionPending ||
                        widget.controller.coreValidationBusy
                  ? null
                  : () async {
                      setState(() {
                        reading = true;
                        unavailable = false;
                      });
                      final target = await prepareExternalConnection(
                        context,
                        controller: widget.controller,
                        runner: widget.runner,
                        serverId: widget.serverId,
                        protocol: widget.protocol,
                        source: widget.source,
                        host: widget.host,
                        panelPort: widget.panelPort,
                      );
                      if (!mounted) return;
                      setState(() {
                        reading = false;
                        unavailable = target == null;
                      });
                      if (target != null) await c.check(target);
                    },
              icon: Icon(
                running ? Icons.stop_circle_outlined : Icons.network_check,
              ),
              label: Text(running ? l.connectionStop : l.connectionCheck),
            ),
            if (result?.status == ConnectionCheckStatus.failed &&
                widget.onEdit != null)
              TextButton(
                onPressed: widget.controller.busy ? null : widget.onEdit,
                child: Text(l.connectionReconfigure),
              ),
          ],
        ),
      ],
    );
  }
}
