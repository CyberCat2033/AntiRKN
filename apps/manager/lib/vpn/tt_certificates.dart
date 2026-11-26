import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../app_strings.dart';
import '../network/network_controller.dart';
import '../runner/runner_controller.dart';
import 'tt_dialog.dart';
import 'vpn_strings.dart';

/// The TLS certificates of a server: one compact row per certificate with
/// its state, technical details in a sheet, and the section's actions.
class TtCertificates extends StatelessWidget {
  const TtCertificates({
    required this.runner,
    required this.picker,
    required this.network,
    required this.motion,
    super.key,
  });
  final RunnerController runner;
  final PrivateKeyFilePicker picker;
  final NetworkController network;
  final MotionPreference motion;

  Future<void> _edit(BuildContext context, [Map? certificate]) =>
      showDialog<bool>(
        context: context,
        builder: (_) => TtCertificateDialog(
          runner: runner,
          picker: picker,
          network: network,
          motion: motion,
          certificate: certificate == null
              ? null
              : Map<String, dynamic>.from(certificate),
        ),
        animationStyle: AnimationStyle(
          duration: AppMotion.duration(context, motion),
        ),
      );

  /// Problems of [c] the person has to act on: an error of the last check
  /// or an expiry that renewal has not moved yet.
  static List<String> issues(AppLocalizations l, Map c) => [
    if (c['error'] case final String error) vpnMessage(l, error),
    if ((c['expiresAt'] as num) <
        DateTime.now().millisecondsSinceEpoch / 1000 + 21 * 86400)
      l.ttExpirySoon,
  ];

  void _details(BuildContext context, Map c) {
    final l = AppLocalizations.of(context);
    final problems = issues(l, c);
    Widget row(IconData icon, String title, [String? value]) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: value == null ? null : Text(value),
    );
    showAppDetails(
      context,
      title: '${c['domain']}',
      children: [
        if (problems.isNotEmpty)
          AppNotice(
            message: problems.join('\n'),
            error: c['error'] is String,
            margin: EdgeInsets.zero,
          ),
        row(
          Icons.event_outlined,
          l.ttExpiry,
          l.formatEpochSeconds(c['expiresAt'] as num),
        ),
        row(
          Icons.autorenew,
          c['mode'] == 'acme'
              ? l.ttRenewAcme
              : c['mode'] == 'import'
              ? l.ttRenewImport
              : l.ttRenewExternal,
        ),
        if (c['lastSuccess'] case final num at)
          row(Icons.task_alt, l.ttLastSuccess, l.formatEpochSeconds(at)),
        if (c['nextCheck'] case final num at)
          row(Icons.schedule, l.ttNextCheck, l.formatEpochSeconds(at)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: runner,
    builder: (context, _) {
      final l = AppLocalizations.of(context),
          colors = Theme.of(context).colorScheme;
      final certificates =
          (runner.ttCertificates?['certificates'] as List? ?? [])
              .whereType<Map>()
              .toList();
      return AppSettingsSection(
        title: l.ttCertificates,
        count: certificates.isEmpty ? null : certificates.length,
        action: IconButton(
          key: const ValueKey('tt-certificates-refresh'),
          tooltip: l.awgRefresh,
          onPressed: runner.busy
              ? null
              : () => runner.ttRequest('tt_certificates'),
          icon: const Icon(Icons.refresh),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in certificates)
              if (issues(l, c) case final problems)
                ListTile(
                  key: ValueKey('tt-certificate-row-${c['id']}'),
                  leading: Icon(
                    problems.isEmpty
                        ? Icons.verified_outlined
                        : Icons.error_outline,
                    color: problems.isEmpty ? null : colors.error,
                  ),
                  title: Text('${c['domain']}'),
                  subtitle: Text(
                    problems.isEmpty
                        ? '${l.ttExpiry}: ${l.formatEpochSeconds(c['expiresAt'] as num)}'
                        : problems.join('\n'),
                    style: problems.isEmpty
                        ? null
                        : TextStyle(color: colors.error),
                  ),
                  onTap: () => _details(context, c),
                  trailing: IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: l.vpnEdit,
                    onPressed: runner.busy ? null : () => _edit(context, c),
                  ),
                ),
            if (certificates.isNotEmpty) const Divider(),
            ListTile(
              key: const ValueKey('tt-certificate-add'),
              leading: const Icon(Icons.add),
              title: Text(l.ttAddCertificate),
              enabled: !runner.busy && runner.installed,
              onTap: () => _edit(context),
            ),
          ],
        ),
      );
    },
  );
}

class TtCertificateDialog extends StatefulWidget {
  const TtCertificateDialog({
    required this.runner,
    required this.picker,
    required this.network,
    required this.motion,
    this.certificate,
    this.newCertificateId,
    this.initialMode = 'files',
    this.initialDomain = '',
    this.initialListen = '0.0.0.0',
    this.initialExpectedIps = const [],
    super.key,
  });
  final Map<String, dynamic>? certificate;
  final String? newCertificateId;
  final String initialMode, initialDomain, initialListen;
  final List<String> initialExpectedIps;
  final RunnerController runner;
  final PrivateKeyFilePicker picker;
  final NetworkController network;
  final MotionPreference motion;
  @override
  State<TtCertificateDialog> createState() => _TtCertificateState();
}

class _TtCertificateState extends State<TtCertificateDialog>
    with TtPlannedState<TtCertificateDialog> {
  @override
  RunnerController get runner => widget.runner;
  @override
  String get planAction => 'tt_certificate_plan';
  @override
  String get jobKind => 'tt_certificate';
  @override
  int get steps => 4;
  late final id =
      widget.certificate?['id'] as String? ??
      widget.newCertificateId ??
      newVpnId();
  late String mode =
      widget.certificate?['mode'] as String? ?? widget.initialMode;
  late final configuration = Map<String, dynamic>.from(
    widget.certificate?['configuration'] as Map? ??
        {
          'domain': widget.initialDomain,
          'listen': widget.initialListen,
          'expectedIps': widget.initialExpectedIps,
        },
  );
  late final fields = {
    for (final k in ['domain', 'listen', 'certificate', 'privateKey'])
      k: TextEditingController(
        text: configuration[k] as String? ?? (k == 'listen' ? '0.0.0.0' : ''),
      ),
  };
  final pem = <String, String>{};
  final names = <String, String>{};
  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    pem.clear();
    super.dispose();
  }

  Future<void> pick(String kind) async {
    setState(() => busy = true);
    ImportedPrivateKey? file;
    try {
      file = await widget.picker.pick();
      if (file == null || !mounted) return;
      final text = utf8.decode(file.bytes);
      if (!text.contains('-----BEGIN ')) {
        throw const FormatException('tt_certificate_invalid');
      }
      setState(() {
        pem[kind] = text;
        names[kind] = file!.name;
        preview = null;
        payload = null;
        error = null;
      });
    } catch (_) {
      if (mounted) setState(() => error = 'tt_certificate_invalid');
    } finally {
      file?.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(String k, String label, {bool secret = false}) => Padding(
    padding: const EdgeInsets.only(bottom: AppLayout.gap),
    child: TextField(
      key: ValueKey('tt-certificate-$k'),
      controller: fields[k],
      enabled:
          !busy &&
          preview == null &&
          !(k == 'domain' && widget.certificate != null),
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => changed(),
    ),
  );
  @override
  Map<String, Object?> buildPayload() => {
    'id': id,
    'mode': mode,
    'domain': fields['domain']!.text.trim().toLowerCase(),
    'listen': fields['listen']!.text.trim(),
    'autoDetectIps': mode == 'acme',
    'expectedIps': <String>{
      ...List<String>.from(configuration['expectedIps'] as List? ?? []),
      if (widget.network.inventory?.sshPeer case final IpAddress peer)
        peer.toString(),
    }.take(8).toList(),
    'email': configuration['email'] as String? ?? '',
    'certificate': fields['certificate']!.text.trim(),
    'privateKey': fields['privateKey']!.text.trim(),
    'certificatePem': mode == 'import' ? pem['certificate'] ?? '' : '',
    'privateKeyPem': mode == 'import' ? pem['privateKey'] ?? '' : '',
  };
  @override
  Future<Map<String, Object?>> preparePayload() async {
    if (mode == 'acme' && widget.network.inventory == null) {
      await widget.network.load();
    }
    return buildPayload();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AppFormDialog(
      title: Text(widget.certificate == null ? l.ttAddCertificate : l.vpnEdit),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSelectField<String>(
                key: const ValueKey('tt-certificate-mode'),
                value: mode,
                label: l.ttCertificateSource,
                options: [
                  ('files', l.ttServerFiles),
                  ('import', l.ttImportPem),
                  ('acme', l.ttIssueAcme),
                ],
                onChanged: busy || preview != null || widget.certificate != null
                    ? null
                    : (v) {
                        mode = v;
                        changed();
                      },
              ),
              const SizedBox(height: AppLayout.gap),
              field('domain', l.ttDomain),
              if (mode == 'files') ...[
                Text(l.ttFilesHelp),
                for (final c
                    in (runner.ttCertificates?['candidates'] as List? ?? [])
                        .whereType<Map>())
                  TextButton(
                    onPressed: busy || preview != null
                        ? null
                        : () {
                            fields['certificate']!.text =
                                c['certificate'] as String;
                            fields['privateKey']!.text =
                                c['privateKey'] as String;
                            if (widget.certificate == null) {
                              fields['domain']!.text =
                                  (c['domains'] as List).firstOrNull
                                      as String? ??
                                  '';
                            }
                            changed();
                          },
                    child: Text(
                      '${(c['domains'] as List).join(', ')} · ${c['certificate']}',
                    ),
                  ),
                field('certificate', l.vpnCertificate),
                field('privateKey', l.vpnCertificateKey),
              ],
              if (mode == 'import') ...[
                Text(l.ttImportHelp),
                for (final kind in ['certificate', 'privateKey'])
                  OutlinedButton(
                    onPressed: busy || preview != null
                        ? null
                        : () => pick(kind),
                    child: Text(
                      names[kind] ??
                          (kind == 'certificate'
                              ? l.vpnCertificate
                              : l.vpnCertificateKey),
                    ),
                  ),
              ],
              if (mode == 'acme') Text(l.ttAcmeHelp),
              ...status(l),
            ],
          ),
        ),
      ),
      actions: actions(l),
    );
  }
}
