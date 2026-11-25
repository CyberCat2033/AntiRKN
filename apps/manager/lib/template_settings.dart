import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';

import 'app_strings.dart';
import 'l10n/app_localizations.dart';
import 'template_controller.dart';

class TemplateSettings extends StatelessWidget {
  const TemplateSettings({
    required this.controller,
    this.showTitle = true,
    this.emptyMessage,
    super.key,
  });

  final TemplateController controller;
  final bool showTitle;
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final hasSource = controller.source.trim().isNotEmpty;
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: const ValueKey('import-template'),
            leading: const Icon(Icons.description_outlined),
            title: Text(l.source),
            subtitle: Text(
              controller.importing
                  ? l.templateLoading
                  : controller.importedName ??
                        (hasSource
                            ? l.templateReady
                            : emptyMessage ?? l.vpnEmptyTemplate),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap:
                controller.importing ||
                    controller.busy ||
                    controller.pickTemplate == null
                ? null
                : () {
                    controller.importFile();
                  },
          ),
          if (hasSource &&
              controller.draftStore != null &&
              controller.draftSaveFailed)
            AppNotice(
              message: l.draftSaveError,
              error: true,
              action: OutlinedButton(
                onPressed: controller.persistDraft,
                child: Text(l.vaultRetry),
              ),
            )
          else if (hasSource &&
              controller.draftStore != null &&
              controller.savingDraft)
            Text(l.draftSaving),
          if (controller.importError != null)
            AppNotice(
              error: true,
              message: controller.importError == 'template_size_limit'
                  ? l.diagnostic('template_size_limit')
                  : l.templateReadError,
            ),
          if (controller.failed)
            AppNotice(message: l.unexpectedError, error: true),
          if (!controller.stale && controller.result?.hasBlockingErrors == true)
            for (final d in controller.result!.diagnostics)
              AppNotice(message: l.diagnostic(d.code), error: true),
        ],
      );
      return showTitle
          ? AppSettingsSection(title: l.uiClientProfiles, child: content)
          : content;
    },
  );
}
