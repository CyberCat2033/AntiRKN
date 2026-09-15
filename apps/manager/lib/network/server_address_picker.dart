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
            const SizedBox(height: AppLayout.smallGap),
            Semantics(
              liveRegion: true,
              child: Text(
                '${l.networkSelectedUnavailable} ${issueLabel(l, issue)}',
                key: ValueKey('selection-issue-${role.name}'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
    final duration = AppMotion.duration(context, motion);
    final result = await showModalBottomSheet<AddressChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
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
        return FractionallySizedBox(
          heightFactor: 0.85,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 8, 8),
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
              Expanded(
                child: ListView.builder(
                  key: ValueKey('address-options-${role.name}'),
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
                    return ListTile(
                      key: ValueKey('option-${choice.id}'),
                      enabled: choice.enabled,
                      selected: choice.id == selected?.id,
                      leading: Icon(
                        choice.id == selected?.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(choice.host),
                      subtitle: Text(choiceDescription(l, choice)),
                      onTap: choice.enabled
                          ? () => Navigator.pop(context, choice)
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (result != null && context.mounted) onSelected(result);
  }
}
