import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../network/network_controller.dart';
import '../network/server_address_picker.dart';
import '../runner/runner_controller.dart';
import 'tt_dialog.dart';
import 'vpn_strings.dart';

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
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: runner,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.ttCertificates,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final c
              in (runner.ttCertificates?['certificates'] as List? ?? [])
                  .whereType<Map>()) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${c['domain']}'),
              trailing: IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: l.vpnEdit,
                onPressed: runner.busy
                    ? null
                    : () => showDialog<bool>(
                        context: context,
                        builder: (_) => TtCertificateDialog(
                          runner: runner,
                          picker: picker,
                          network: network,
                          motion: motion,
                          certificate: Map<String, dynamic>.from(c),
                        ),
                        animationStyle: AnimationStyle(
                          duration: AppMotion.duration(context, motion),
                        ),
                      ),
              ),
              subtitle: Text(
                '${l.ttExpiry}: ${DateTime.fromMillisecondsSinceEpoch(((c['expiresAt'] as num) * 1000).toInt()).toLocal()}\n${c['mode'] == 'acme'
                    ? l.ttRenewAcme
                    : c['mode'] == 'import'
                    ? l.ttRenewImport
                    : l.ttRenewExternal}',
              ),
            ),
            if (c['lastSuccess'] case final num at)
              Text(
                '${l.ttLastSuccess}: ${DateTime.fromMillisecondsSinceEpoch((at * 1000).toInt()).toLocal()}',
              ),
            if (c['nextCheck'] case final num at)
              Text(
                '${l.ttNextCheck}: ${DateTime.fromMillisecondsSinceEpoch((at * 1000).toInt()).toLocal()}',
              ),
            if (c['error'] case final String error) Text(vpnMessage(l, error)),
            if ((c['expiresAt'] as num) <
                DateTime.now().millisecondsSinceEpoch / 1000 + 21 * 86400)
              Text(l.ttExpirySoon),
          ],
          Wrap(
            spacing: AppLayout.smallGap,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: Text(l.ttAddCertificate),
                onPressed: runner.busy || !runner.installed
                    ? null
                    : () => showDialog<bool>(
                        context: context,
                        builder: (_) => TtCertificateDialog(
                          runner: runner,
                          picker: picker,
                          network: network,
                          motion: motion,
                        ),
                        animationStyle: AnimationStyle(
                          duration: AppMotion.duration(context, motion),
                        ),
                      ),
              ),
              TextButton(
                onPressed: runner.busy
                    ? null
                    : () => runner.ttRequest('tt_certificates'),
                child: Text(l.awgRefresh),
              ),
            ],
          ),
        ],
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
    for (final k in [
      'domain',
      'listen',
      'expectedIps',
      'email',
      'certificate',
      'privateKey',
    ])
      k: TextEditingController(
        text: k == 'expectedIps'
            ? (configuration[k] as List? ?? []).join(', ')
            : configuration[k] as String? ?? (k == 'listen' ? '0.0.0.0' : ''),
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
      onChanged: (_) {
        if (k == 'listen' &&
            !['0.0.0.0', '::'].contains(fields[k]!.text.trim())) {
          fields['expectedIps']!.text = fields[k]!.text.trim();
        }
        changed();
      },
    ),
  );
  @override
  Map<String, Object?> buildPayload() => {
    'id': id,
    'mode': mode,
    'domain': fields['domain']!.text.trim().toLowerCase(),
    'listen': fields['listen']!.text.trim(),
    'expectedIps': fields['expectedIps']!.text
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList(),
    'email': fields['email']!.text.trim(),
    'certificate': fields['certificate']!.text.trim(),
    'privateKey': fields['privateKey']!.text.trim(),
    'certificatePem': mode == 'import' ? pem['certificate'] ?? '' : '',
    'privateKeyPem': mode == 'import' ? pem['privateKey'] ?? '' : '',
  };
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final choices = widget.network.choices(AddressRole.listener);
    return AlertDialog(
      title: Text(widget.certificate == null ? l.ttAddCertificate : l.vpnEdit),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                initialValue: mode,
                isExpanded: true,
                decoration: InputDecoration(labelText: l.ttCertificateSource),
                items: [
                  DropdownMenuItem(
                    value: 'files',
                    child: Text(l.ttServerFiles),
                  ),
                  DropdownMenuItem(value: 'import', child: Text(l.ttImportPem)),
                  DropdownMenuItem(value: 'acme', child: Text(l.ttIssueAcme)),
                ],
                onChanged: busy || preview != null || widget.certificate != null
                    ? null
                    : (v) {
                        mode = v!;
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
              if (mode == 'acme') ...[
                ServerAddressPicker(
                  role: AddressRole.listener,
                  choices: choices,
                  selected: choices
                      .where((c) => c.host == fields['listen']!.text)
                      .firstOrNull,
                  selectionIssue: null,
                  motion: widget.motion,
                  enabled: !busy && preview == null,
                  onSelected: (c) {
                    fields['listen']!.text = c?.host ?? '';
                    if (c != null && !['0.0.0.0', '::'].contains(c.host)) {
                      fields['expectedIps']!.text = c.host;
                    }
                    changed();
                  },
                ),
                field('listen', l.networkListener),
                if ([
                  '0.0.0.0',
                  '::',
                ].contains(fields['listen']!.text.trim())) ...[
                  ServerAddressPicker(
                    role: AddressRole.endpoint,
                    choices: widget.network.choices(AddressRole.endpoint),
                    selected: widget.network
                        .choices(AddressRole.endpoint)
                        .where((c) => c.host == fields['expectedIps']!.text)
                        .firstOrNull,
                    selectionIssue: null,
                    motion: widget.motion,
                    enabled: !busy && preview == null,
                    onSelected: (c) {
                      fields['expectedIps']!.text = c?.host ?? '';
                      changed();
                    },
                  ),
                ],
                field('expectedIps', l.ttExpectedIps),
                field('email', l.ttAcmeEmail),
                Text(l.ttAcmeHelp),
              ],
              ...status(l),
            ],
          ),
        ),
      ),
      actions: actions(l),
    );
  }
}
