import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'network_controller.dart';
import 'server_address_picker.dart';

/// Suggestions follow live inventory and manual edits without changing a draft.
class ServerAddressField extends StatelessWidget {
  const ServerAddressField({
    required this.label,
    required this.fieldKey,
    required this.network,
    required this.controller,
    required this.motion,
    this.role = AddressRole.listener,
    this.enabled = true,
    this.onChanged,
    super.key,
  });
  final String label;
  final Key fieldKey;
  final NetworkController network;
  final TextEditingController controller;
  final MotionPreference motion;
  final AddressRole role;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([network, controller]),
    builder: (context, _) {
      final choices = network.choices(role);
      final l = AppLocalizations.of(context);
      return TextField(
        key: fieldKey,
        controller: controller,
        enabled: enabled,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: IconButton(
            key: ValueKey('pick-${role.name}'),
            tooltip: l.networkChoose,
            icon: const Icon(Icons.format_list_bulleted),
            onPressed: !enabled
                ? null
                : () async {
                    FocusScope.of(context).unfocus();
                    final choice = await showServerAddressChoice(
                      context,
                      title: role == AddressRole.listener
                          ? l.networkListener
                          : l.networkEndpoint,
                      role: role,
                      choices: choices,
                      selected: choices
                          .where(
                            (choice) => choice.host == controller.text.trim(),
                          )
                          .firstOrNull,
                      motion: motion,
                    );
                    if (context.mounted && choice != null) {
                      controller.text = choice.host;
                      onChanged?.call(choice.host);
                    }
                  },
          ),
        ),
      );
    },
  );
}
