import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'network_strings.dart';

/// One component for listener/endpoint roles; policy decisions arrive from the
/// controller. Protocol forms can reuse it without duplicating address rules.
class ServerAddressPicker extends StatelessWidget {
  const ServerAddressPicker({
    required this.role,
    required this.choices,
    required this.selected,
    required this.selectionIssue,
    required this.onSelected,
    required this.motion,
    this.enabled = true,
    super.key,
  });
  final AddressRole role;
  final List<AddressChoice> choices;
  final AddressChoice? selected;
  final SelectionIssue? selectionIssue;
  final ValueChanged<AddressChoice?> onSelected;
  final MotionPreference motion;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final listener = role == AddressRole.listener;
    final title = listener ? l.networkListener : l.networkEndpoint;
    return SectionCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(listener ? l.networkListenerHelp : l.networkEndpointHelp),
          const SizedBox(height: AppLayout.gap),
          OutlinedButton(
            key: ValueKey('pick-${role.name}'),
            onPressed: enabled ? () => _open(context, title) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppLayout.smallGap),
              child: Column(
                children: [
                  Text(
                    selected?.host ?? l.networkChoose,
                    textAlign: TextAlign.center,
                  ),
                  if (selected case final choice?)
                    Text(
                      choiceDescription(l, choice),
                      textAlign: TextAlign.center,
                    ),
                ],
              ),
            ),
          ),
          if (selectionIssue case final issue?) ...[
            AppNotice(
              key: ValueKey('selection-issue-${role.name}'),
              message:
                  '${l.networkSelectedUnavailable} ${issueLabel(l, issue)}',
              error: true,
              margin: const EdgeInsets.only(top: AppLayout.smallGap),
            ),
          ],
          if (selected != null)
            TextButton(
              key: ValueKey('clear-${role.name}'),
              onPressed: enabled ? () => onSelected(null) : null,
              child: Text(l.networkClear),
            ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context, String title) async {
    final result = await showServerAddressChoice(
      context,
      title: title,
      role: role,
      choices: choices,
      selected: selected,
      motion: motion,
    );
    if (result != null && context.mounted) onSelected(result);
  }
}

/// Shared address sheet for full inventory cards and compact protocol fields.
Future<AddressChoice?> showServerAddressChoice(
  BuildContext context, {
  required String title,
  required AddressRole role,
  required List<AddressChoice> choices,
  required AddressChoice? selected,
  required MotionPreference motion,
}) {
  final duration = AppMotion.duration(context, motion);
  return showModalBottomSheet<AddressChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    sheetAnimationStyle: AnimationStyle(
      duration: duration,
      reverseDuration: duration,
    ),
    builder: (context) {
      final l = AppLocalizations.of(context);
      final rows = <Object>[
        for (final group in AddressClass.values)
          if (choices.any((c) => c.address.addressClass == group)) ...[
            group,
            ...choices.where((c) => c.address.addressClass == group),
          ],
      ];
      // Sized by its content, up to the screen: two or three addresses do
      // not open a mostly empty sheet (UI-69).
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: l.networkClose,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          if (!choices.any((choice) => choice.enabled))
            Padding(
              padding: AppLayout.screenPadding(context),
              child: Text(l.networkNoCandidates),
            ),
          Flexible(
            child: RadioGroup<String>(
              groupValue: selected?.id,
              onChanged: (id) => Navigator.pop(
                context,
                choices.firstWhere((choice) => choice.id == id),
              ),
              child: ListView.builder(
                key: ValueKey('address-options-${role.name}'),
                shrinkWrap: true,
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  if (row is AddressClass) {
                    return Padding(
                      padding: AppLayout.screenPadding(context),
                      child: Text(
                        row == AddressClass.external
                            ? l.networkExternal
                            : l.networkInternal,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    );
                  }
                  final choice = row as AddressChoice;
                  // A real radio: state and group are announced (UI-69).
                  // Its own clipped Material: the selected tile colour is ink
                  // and must not paint over the fixed header while scrolled.
                  return Material(
                    type: MaterialType.transparency,
                    clipBehavior: Clip.hardEdge,
                    child: RadioListTile<String>(
                      key: ValueKey('option-${choice.id}'),
                      value: choice.id,
                      enabled: choice.enabled,
                      selected: choice.id == selected?.id,
                      title: Text(choice.host),
                      subtitle: Text(choiceDescription(l, choice)),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      );
    },
  );
}
