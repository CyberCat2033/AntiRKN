import 'dart:async';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'vpn_controller.dart';

String coreCheckLabel(AppLocalizations l, CoreConfigCheck? check) =>
    switch (check?.status) {
      null => l.coreNotChecked,
      CoreConfigStatus.valid => l.coreValid,
      CoreConfigStatus.invalid => l.coreInvalid,
      CoreConfigStatus.incomplete => l.coreIncomplete,
      CoreConfigStatus.cancelled => l.coreCancelled,
      CoreConfigStatus.unavailable => l.coreUnavailable,
    };

String _explanation(AppLocalizations l, CoreConfigCheck? check) =>
    switch (check?.code) {
      'provider_content' || 'external_dependency' => l.coreMissingResources,
      'provider_rejected' => l.coreProviderInvalid,
      'input_limit' => l.coreInputLimit,
      'core_rejected' || 'invalid_yaml' || 'unsupported_yaml' => l.coreRejected,
      'valid' => l.coreValidationScope,
      'cancelled' => l.coreCancelledHelp,
      _ => l.coreUnavailableHelp,
    };

class CoreConfigCheckAction extends StatelessWidget {
  const CoreConfigCheckAction({
    required this.controller,
    required this.userId,
    super.key,
  });
  final VpnController controller;
  final String userId;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context),
          check = controller.coreCheckFor(userId);
      final checking = controller.coreCheckingUser == userId;
      final usable =
          controller.results[userId]?.yaml != null &&
          controller.results[userId]?.hasBlockingErrors == false &&
          controller.workspace.users.any(
            (u) => u.id == userId && u.enabled && !u.deleted,
          );
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                checking ? l.coreChecking : coreCheckLabel(l, check),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: check?.status == CoreConfigStatus.invalid
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              key: ValueKey('core-check-$userId'),
              onPressed:
                  !usable || controller.busy || controller.coreValidationBusy
                  ? null
                  : () => _showCheck(context, controller, userId),
              icon: const Icon(Icons.fact_check_outlined, size: 19),
              label: Text(l.coreCheckConfig),
            ),
          ],
        ),
      );
    },
  );
}

Future<void> _showCheck(
  BuildContext context,
  VpnController controller,
  String userId,
) async {
  final run = controller.validateCoreProfile(userId);
  unawaited(run);
  await showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final l = AppLocalizations.of(context);
        final checking = controller.coreCheckingUser == userId;
        final result = controller.coreCheckFor(userId);
        return AlertDialog(
          title: Text(checking ? l.coreChecking : coreCheckLabel(l, result)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (checking) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 18),
                  Text(l.coreCheckingHelp),
                ] else ...[
                  Text(_explanation(l, result)),
                  if (result?.path case final path?) ...[
                    const SizedBox(height: 12),
                    Text(path),
                  ],
                  if (result?.version.isNotEmpty == true) ...[
                    const SizedBox(height: 12),
                    Text('Mihomo ${result!.version}'),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (checking) controller.cancelCoreValidation();
                Navigator.pop(context);
              },
              child: Text(checking ? l.coreStop : l.networkClose),
            ),
          ],
        );
      },
    ),
  );
  if (controller.coreCheckingUser == userId) controller.cancelCoreValidation();
}
