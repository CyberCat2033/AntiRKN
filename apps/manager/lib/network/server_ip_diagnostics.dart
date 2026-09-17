import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'ip_diagnostics_controller.dart';

Future<void> showServerIpDiagnostics(
  BuildContext context,
  IpDiagnosticsController controller,
  ServerIpDiagnostics server,
) async {
  final l = AppLocalizations.of(context);
  var method = IpProbeKind.tcp;
  final chosen = await showDialog<IpProbeKind>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AppFormDialog(
        title: Text(l.diagTitle),
        content: RadioGroup<IpProbeKind>(
          groupValue: method,
          onChanged: (value) => setState(() => method = value!),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.diagProtocol),
              const SizedBox(height: 8),
              RadioListTile<IpProbeKind>(
                key: const ValueKey('diagnostics-method-tcp'),
                contentPadding: EdgeInsets.zero,
                title: const Text('TCP'),
                subtitle: Text('${l.diagPort} 443'),
                value: IpProbeKind.tcp,
              ),
              RadioListTile<IpProbeKind>(
                key: const ValueKey('diagnostics-method-ssh'),
                contentPadding: EdgeInsets.zero,
                title: const Text('SSH'),
                subtitle: Text('${l.diagPort} ${server.sshPort}'),
                value: IpProbeKind.ssh,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.sshCancel),
          ),
          FilledButton(
            key: const ValueKey('diagnostics-start'),
            onPressed: () => Navigator.pop(context, method),
            child: Text(l.diagStart),
          ),
        ],
      ),
    ),
  );
  if (chosen == null || !context.mounted || controller.busy) return;
  await controller.start(server, chosen);
  if (context.mounted && controller.issue != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(controller.issue == 'busy' ? l.diagBusy : l.diagFailed),
      ),
    );
  }
}

String diagnosticAddressLabel(AppLocalizations l, IpAddressDiagnostic result) {
  final prefix =
      '${result.target.kind.name.toUpperCase()} :${result.target.port}';
  String state;
  if (result.current &&
      result.running &&
      [
        IpDiagnosticStage.controls,
        IpDiagnosticStage.recovery,
      ].contains(result.stage)) {
    state = result.stage == IpDiagnosticStage.controls
        ? l.diagControls
        : l.diagRecovery;
  } else if (result.connectionLost) {
    state = result.strong ? l.diagSuspectedBlocking : l.diagConnectionLost;
    if (result.recovered) state = '$state · ${l.diagConnectionRestored}';
  } else if (result.status != null) {
    state = switch (result.status!) {
      IpProbeStatus.reachable => l.diagReachable,
      IpProbeStatus.refused => l.diagRefused,
      IpProbeStatus.tlsError => l.diagTlsError,
      IpProbeStatus.protocolError => l.diagProtocolError,
      IpProbeStatus.timeout || IpProbeStatus.unavailable => l.diagUnreachable,
    };
  } else if (result.running) {
    state = result.stage == IpDiagnosticStage.baseline
        ? l.diagBaseline
        : result.current
        ? l.diagTarget
        : l.diagQueued;
  } else {
    state = switch (result.stage) {
      IpDiagnosticStage.cancelled => l.diagCancelled,
      IpDiagnosticStage.networkChanged => l.diagNetworkChanged,
      IpDiagnosticStage.insufficient => l.diagInsufficient,
      IpDiagnosticStage.failed => l.diagFailed,
      _ => l.diagNotTested,
    };
  }
  return '$prefix · $state';
}
