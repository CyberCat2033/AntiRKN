import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../runner/runner_controller.dart';
import '../runner/runner_panel.dart';
import 'xhttp_options_editor.dart';

class ObservedInboundDialog extends StatefulWidget {
  const ObservedInboundDialog({
    required this.controller,
    required this.inboundId,
    required this.port,
    required this.motion,
    super.key,
  });
  final RunnerController controller;
  final int inboundId, port;
  final MotionPreference motion;
  @override
  State<ObservedInboundDialog> createState() => _ObservedInboundDialogState();
}

class _ObservedInboundDialogState extends State<ObservedInboundDialog> {
  final fields = <String, TextEditingController>{};
  Map<String, dynamic>? snapshot, plan;
  Map<String, Object?>? payload;
  Map<String, Object?> stream = {};
  bool loading = true, failed = false, invalid = false, enabled = true;
  bool streamInvalid = false;
  bool passwordVisible = false;
  bool get needsAccess => widget.controller.panelAccess?.port != widget.port;
  TextEditingController fieldController(String key, [String initial = '']) =>
      fields.putIfAbsent(key, () => TextEditingController(text: initial));
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (needsAccess) {
      setState(() => loading = false);
      return;
    }
    final result = await widget.controller.readInbound(widget.inboundId);
    if (!mounted) return;
    setState(() {
      loading = false;
      failed = result == null;
      snapshot = result;
      if (result != null) {
        final row = result['row'] as Map;
        for (final key in ['remark', 'listen', 'port']) {
          fieldController(key).text = '${row[key]}';
        }
        enabled = row['enable'] as bool;
        stream = Map<String, Object?>.from(
          jsonDecode(row['streamSettings'] as String) as Map,
        );
      }
    });
  }

  Future<void> connect() async {
    setState(() {
      loading = true;
      failed = false;
    });
    final ok = await widget.controller.connectPanel(
      widget.port,
      fieldController('username').text,
      fieldController('password').text,
    );
    if (!mounted) return;
    if (ok) {
      fieldController('password').clear();
      await load();
    } else {
      setState(() {
        loading = false;
        failed = true;
      });
    }
  }

  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  Widget input(
    String key,
    String label, {
    String initial = '',
    bool secret = false,
    ValueChanged<String>? onChanged,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: AppLayout.gap),
    child: TextField(
      key: ValueKey('observed-$key'),
      controller: fieldController(key, initial),
      obscureText: secret && !passwordVisible,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: number ? TextInputType.number : null,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: secret
            ? IconButton(
                tooltip: passwordVisible
                    ? AppLocalizations.of(context).hidePassword
                    : AppLocalizations.of(context).showPassword,
                onPressed: () =>
                    setState(() => passwordVisible = !passwordVisible),
                icon: Icon(
                  passwordVisible ? Icons.visibility_off : Icons.visibility,
                ),
              )
            : null,
      ),
    ),
  );
  Future<void> prepare() async {
    final row = snapshot!['row'] as Map;
    final port = int.tryParse(fieldController('port').text);
    if (streamInvalid || port == null || port < 1 || port > 65535) {
      setState(() => invalid = true);
      return;
    }
    final patch = <String, Object?>{
      'remark': fieldController('remark').text.trim(),
      'listen': fieldController('listen').text.trim(),
      'port': port,
      'enable': enabled,
      'streamSettings': stream,
    };
    // Only changed fields leave the dialog; untouched settings remain on the server.
    final original = {
      ...row,
      'streamSettings': jsonDecode(row['streamSettings'] as String),
    };
    final delta = changedFields({
      for (final key in patch.keys) key: original[key],
    }, patch);
    if (delta.isEmpty) {
      Navigator.pop(context);
      return;
    }
    payload = {
      'inboundId': widget.inboundId,
      'observedHash': snapshot!['fingerprint'],
      'patch': delta,
    };
    setState(() {
      loading = true;
      invalid = false;
      failed = false;
    });
    final result = await widget.controller.planInbound(payload!);
    if (!mounted) return;
    setState(() {
      loading = false;
      plan = result;
      failed = result == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), c = widget.controller;
    final xhttp = stream['network'] == 'xhttp';
    final reality = stream['realitySettings'] as Map?;
    final xsettings = Map<String, Object?>.from(
      stream['xhttpSettings'] as Map? ?? {},
    );
    final currentMode = xsettings['mode']?.toString() ?? '';
    final modes = <String>{'auto', 'packet-up', 'stream-up', 'stream-one'};
    if (currentMode.isNotEmpty) modes.add(currentMode);
    return AlertDialog(
      title: Text(needsAccess ? l.panelConnectTitle : l.vpnEdit),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (loading) const LinearProgressIndicator(),
              if (failed)
                Text(
                  c.responseCode != null && c.responseCode != 'ok'
                      ? runnerCodeLabel(l, c.responseCode!)
                      : l.vpnFailed,
                ),
              if (needsAccess) ...[
                Text(l.panelConnectHelp),
                input('username', l.panelUsername),
                input('password', l.componentsPassword, secret: true),
              ] else if (snapshot != null && plan == null) ...[
                input('remark', l.vpnName),
                Text(
                  '${(snapshot!['row'] as Map)['protocol']} · ${stream['network']} / ${stream['security']}',
                ),
                const SizedBox(height: AppLayout.gap),
                input('listen', l.vpnListen),
                input('port', l.vpnPort, number: true),
                if (reality != null) ...[
                  input(
                    'target',
                    l.vpnTarget,
                    initial: '${reality['target'] ?? reality['dest'] ?? ''}',
                    onChanged: (v) {
                      stream['realitySettings'] = {
                        ...stream['realitySettings'] as Map,
                        'target': v,
                      };
                    },
                  ),
                  input(
                    'sni',
                    l.vpnSni,
                    initial: (reality['serverNames'] as List? ?? []).join(', '),
                    onChanged: (v) {
                      stream['realitySettings'] = {
                        ...stream['realitySettings'] as Map,
                        'serverNames': v
                            .split(',')
                            .map((s) => s.trim())
                            .where((s) => s.isNotEmpty)
                            .toList(),
                      };
                    },
                  ),
                ],
                if (xhttp) ...[
                  input(
                    'path',
                    l.vpnPath,
                    initial: '${xsettings['path'] ?? '/'}',
                    onChanged: (v) {
                      stream['xhttpSettings'] = {
                        ...stream['xhttpSettings'] as Map? ?? {},
                        'path': v,
                      };
                    },
                  ),
                  input(
                    'host',
                    l.vpnHost,
                    initial: '${xsettings['host'] ?? ''}',
                    onChanged: (v) {
                      stream['xhttpSettings'] = {
                        ...stream['xhttpSettings'] as Map? ?? {},
                        'host': v,
                      };
                    },
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: currentMode.isEmpty ? 'auto' : currentMode,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: l.vpnMode),
                    items: [
                      for (final mode in modes)
                        DropdownMenuItem(value: mode, child: Text(mode)),
                    ],
                    onChanged: (v) {
                      stream['xhttpSettings'] = {
                        ...stream['xhttpSettings'] as Map? ?? {},
                        'mode': v,
                      };
                    },
                  ),
                  XhttpOptionsEditor(
                    initial: {...xsettings}
                      ..removeWhere(
                        (k, _) => ['path', 'host', 'mode'].contains(k),
                      ),
                    motion: widget.motion,
                    onChanged: (values) {
                      final retained = Map<String, Object?>.from(
                        stream['xhttpSettings'] as Map? ?? {},
                      );
                      retained.removeWhere(
                        (key, _) => (xhttpOptionsSchema['properties'] as Map)
                            .containsKey(key),
                      );
                      stream['xhttpSettings'] = {...retained, ...values};
                    },
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.vpnEnabled),
                  value: enabled,
                  onChanged: (v) => setState(() => enabled = v),
                ),
                ExpansionTile(
                  title: Text(l.observedTransportJson),
                  onExpansionChanged: (open) {
                    if (open && !streamInvalid) {
                      fieldController('streamJson').text =
                          const JsonEncoder.withIndent('  ').convert(stream);
                    }
                  },
                  children: [
                    TextField(
                      key: const ValueKey('observed-stream-json'),
                      controller: fieldController('streamJson'),
                      minLines: 5,
                      maxLines: 14,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (value) {
                        try {
                          stream = Map<String, Object?>.from(
                            jsonDecode(value) as Map,
                          );
                          streamInvalid = false;
                        } catch (_) {
                          streamInvalid = true;
                        }
                      },
                    ),
                  ],
                ),
                Text(l.observedClientsKept),
                ExpansionTile(
                  key: const ValueKey('observed-details'),
                  title: Text(l.observedFullConfig),
                  children: [
                    SelectableText(
                      const JsonEncoder.withIndent(
                        '  ',
                      ).convert(snapshot!['row']),
                    ),
                  ],
                ),
                if (invalid) Text(l.vpnInvalid),
              ],
              if (plan != null) ...[
                Text(l.observedEditPlan),
                Text('${plan!['name']} · #${plan!['inboundId']}'),
                Text(l.observedClientsKept),
                ExpansionTile(
                  title: Text(l.componentsDetails),
                  children: [
                    SelectableText(
                      const JsonEncoder.withIndent(
                        '  ',
                      ).convert(payload!['patch']),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: loading ? null : () => Navigator.pop(context),
          child: Text(l.networkClose),
        ),
        if (failed && !needsAccess)
          TextButton(
            onPressed: loading
                ? null
                : () {
                    setState(() => loading = true);
                    load();
                  },
            child: Text(l.sshRefresh),
          ),
        if (plan != null)
          TextButton(
            onPressed: loading ? null : () => setState(() => plan = null),
            child: Text(l.vpnEdit),
          ),
        FilledButton(
          key: const ValueKey('observed-save'),
          onPressed: loading
              ? null
              : needsAccess
              ? connect
              : snapshot == null
              ? null
              : plan == null
              ? prepare
              : () async {
                  setState(() => loading = true);
                  final ok = await c.applyInbound(
                    payload!,
                    plan!['fingerprint'] as String,
                  );
                  if (!context.mounted) return;
                  if (ok) {
                    Navigator.pop(context);
                  } else {
                    setState(() {
                      loading = false;
                      failed = true;
                    });
                  }
                },
          child: Text(
            needsAccess
                ? l.sshConnect
                : plan == null
                ? l.componentsPrepare
                : l.runnerApply,
          ),
        ),
      ],
    );
  }
}

Map<String, Object?> changedFields(Map original, Map modified) {
  final result = <String, Object?>{};
  for (final key in {...original.keys, ...modified.keys}) {
    if (!modified.containsKey(key)) {
      result[key as String] = null;
      continue;
    }
    final value = modified[key];
    if (value is Map && original[key] is Map) {
      final nested = changedFields(original[key] as Map, value);
      if (nested.isNotEmpty) result[key as String] = nested;
    } else if (jsonEncode(original[key]) != jsonEncode(value)) {
      result[key as String] = value;
    }
  }
  return result;
}
