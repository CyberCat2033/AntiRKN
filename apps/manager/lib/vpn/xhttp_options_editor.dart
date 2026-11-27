import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Field types and names come from the same contract used by the runner/export.
class XhttpOptionsEditor extends StatefulWidget {
  const XhttpOptionsEditor({
    required this.initial,
    required this.onChanged,
    this.motion = MotionPreference.system,
    super.key,
  });
  final Map<String, Object?> initial;
  final MotionPreference motion;
  final void Function(Map<String, Object?>) onChanged;
  @override
  State<XhttpOptionsEditor> createState() => _XhttpOptionsEditorState();
}

class _XhttpOptionsEditorState extends State<XhttpOptionsEditor> {
  late final values = xhttpFormDefaults(widget.initial);
  final fields = <String, TextEditingController>{};
  void changed() {
    final result = Map<String, Object?>.from(values);
    if ((result['xmux'] as Map).isEmpty) result.remove('xmux');
    widget.onChanged(result);
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget field(
    String key,
    Map rule,
    Map<String, Object?> target, {
    String prefix = '',
  }) {
    final l = AppLocalizations.of(context);
    final id = '$prefix$key';
    if (rule['type'] == 'boolean') {
      return CheckboxListTile(
        key: ValueKey('xhttp-$id'),
        contentPadding: EdgeInsets.zero,
        title: Text(key),
        tristate: false,
        value: target[key] as bool? ?? false,
        onChanged: (value) => setState(() {
          if (value == null) {
            target.remove(key);
          } else {
            target[key] = value;
          }
          changed();
        }),
      );
    }
    if (rule['enum'] case final List choices) {
      final current = target[key]?.toString() ?? '';
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AppSelectField<String>(
          key: ValueKey('xhttp-$id'),
          value: current,
          label: key,
          motion: widget.motion,
          options: [
            ('', l.xhttpDefault),
            for (final value in choices)
              if (value != '') (value as String, value),
            if (current.isNotEmpty && !choices.contains(current))
              (current, current),
          ],
          onChanged: (value) => setState(() {
            if (value.isEmpty) {
              target.remove(key);
            } else {
              target[key] = value;
            }
            changed();
          }),
        ),
      );
    }
    final controller = fields.putIfAbsent(
      id,
      () => TextEditingController(text: '${target[key] ?? ''}'),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: ValueKey('xhttp-$id'),
        controller: controller,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: key,
          hintText: rule['hint'] as String? ?? l.xhttpDefault,
        ),
        onChanged: (value) {
          if (value.trim().isEmpty) {
            target.remove(key);
          } else {
            target[key] = rule['type'] == 'integer'
                ? int.tryParse(value.trim()) ?? value
                : value.trim();
          }
          changed();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final duration = AppMotion.duration(context, widget.motion);
    final animation = AnimationStyle(
      duration: duration,
      reverseDuration: duration,
    );
    final properties = xhttpOptionsSchema['properties'] as Map;
    final xmux = (properties['xmux'] as Map)['properties'] as Map;
    final headers = fields.putIfAbsent(
      'headers',
      () => TextEditingController(
        text: values['headers'] is String
            ? values['headers'] as String
            : (values['headers'] as Map? ?? {}).entries
                  .map((e) => '${e.key}: ${e.value}')
                  .join('\n'),
      ),
    );
    return Column(
      children: [
        AppFormDisclosure(
          expansionAnimationStyle: animation,
          key: const ValueKey('xhttp-xmux'),
          title: 'XMUX',
          children: [
            AppFormHint(l.xmuxHelp),
            const SizedBox(height: 12),
            for (final entry in xmux.entries)
              field(
                entry.key as String,
                entry.value as Map,
                values['xmux'] as Map<String, Object?>,
                prefix: 'xmux-',
              ),
          ],
        ),
        AppFormDisclosure(
          expansionAnimationStyle: animation,
          key: const ValueKey('xhttp-extra'),
          title: l.xhttpAdvanced,
          children: [
            AppFormHint(l.xhttpDefault),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('xhttp-headers'),
              controller: headers,
              minLines: 2,
              maxLines: 6,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l.xhttpHeaders,
                hintText: 'X-Example: value',
              ),
              onChanged: (value) {
                if (value.trim().isEmpty) {
                  values.remove('headers');
                } else {
                  final result = <String, String>{};
                  for (final line
                      in value.split('\n').where((v) => v.trim().isNotEmpty)) {
                    final split = line.indexOf(':');
                    if (split <= 0) {
                      values['headers'] = value;
                      changed();
                      return;
                    }
                    final name = line.substring(0, split).trim();
                    if (result.keys.any(
                      (k) => k.toLowerCase() == name.toLowerCase(),
                    )) {
                      values['headers'] = value;
                      changed();
                      return;
                    }
                    result[name] = line.substring(split + 1).trim();
                  }
                  values['headers'] = result;
                }
                changed();
              },
            ),
            const SizedBox(height: 12),
            for (final entry in properties.entries)
              if (!['xmux', 'headers'].contains(entry.key))
                field(entry.key as String, entry.value as Map, values),
          ],
        ),
      ],
    );
  }
}
