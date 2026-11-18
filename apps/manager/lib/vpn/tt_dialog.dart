import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../runner/runner_controller.dart';
import 'vpn_strings.dart';

/// Shared preflight -> durable submit flow for TT certificates/edits.
mixin TtPlannedState<T extends StatefulWidget> on State<T> {
  RunnerController get runner;
  String get planAction;
  String get jobKind;
  int get steps;
  Map<String, Object?> buildPayload();
  Future<Map<String, Object?>> preparePayload() async => buildPayload();
  bool busy = false;
  String? error;
  Map<String, dynamic>? preview;
  Map<String, Object?>? payload;
  void changed() => setState(() {
    preview = null;
    payload = null;
    error = null;
  });
  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!await runner.ensureReady()) {
        throw const FormatException('vpn_connection');
      }
      if (preview == null) {
        final p = await preparePayload();
        final result = await runner.ttRequest(planAction, payload: p);
        if (!mounted) return;
        if (result == null) {
          throw FormatException(runner.responseCode ?? 'tt_failed');
        }
        setState(() {
          preview = result;
          payload = p;
        });
      }
      {
        final ok = await runner.applyTtJob(
          payload!,
          preview!['fingerprint'] as String,
          kind: jobKind,
          count: steps,
        );
        if (!mounted) return;
        if (ok) {
          Navigator.pop(context, true);
        } else {
          throw FormatException(runner.responseCode ?? 'tt_failed');
        }
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'tt_failed');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<Widget> status(AppLocalizations l) => [
    if (busy) const LinearProgressIndicator(),
    if (error != null)
      Semantics(liveRegion: true, child: Text(vpnMessage(l, error!))),
    if (preview != null) ...[
      const Divider(),
      Text(l.vpnPlan, style: Theme.of(context).textTheme.titleMedium),
      Text(l.ttRestartPlan),
      if (preview!['dns'] case final Map dns)
        Text('${l.ttDnsChecked}: ${(dns['addresses'] as List).join(', ')}'),
      if (preview!['package'] case final Map package)
        Text(
          [
            package['installed'] == true
                ? l.ttCertbotPresent
                : l.ttCertbotInstall,
            if (package['version'] case final Object version) '$version',
          ].join(': '),
        ),
      if (preview!['preserveUsers'] == true) Text(l.ttPreserveUsers),
    ],
  ];
  List<Widget> actions(AppLocalizations l) => [
    TextButton(
      onPressed: busy ? null : () => Navigator.pop(context),
      child: Text(l.runnerNotNow),
    ),
    if (preview != null)
      TextButton(onPressed: busy ? null : changed, child: Text(l.vpnEdit)),
    FilledButton(onPressed: busy ? null : submit, child: Text(l.vpnSave)),
  ];
}
