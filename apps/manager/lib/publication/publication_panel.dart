import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'publication_controller.dart';

String publicationMessage(AppLocalizations l, String? issue) => switch (issue) {
  'unauthorized' || 'forbidden' => l.publicationAuthorizeHelp,
  'missing' => l.publicationMissing,
  'conflict' || 'readback' => l.publicationConflict,
  'accountChanged' => l.publicationAccountChanged,
  'linkUnavailable' => l.publicationLinkUnavailable,
  'network' || 'unavailable' || 'rateLimited' => l.publicationNetwork,
  'changed' => l.publicationWaiting,
  _ => l.publicationFailed,
};

class PublicationSettingsPanel extends StatefulWidget {
  const PublicationSettingsPanel({required this.controller, super.key});
  final PublicationController controller;
  @override
  State<PublicationSettingsPanel> createState() => _PublicationSettingsState();
}

class _PublicationSettingsState extends State<PublicationSettingsPanel> {
  PublicationAccess access = PublicationAccess.private;
  List<PublicationFile>? folders;
  PublicationFile? folder;
  bool loading = false;
  String? folderError;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller,
          l = AppLocalizations.of(context),
          settings = c.settings;
      return SectionCard(
        title: l.publicationTitle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.publicationHelp),
            if (c.needsAuthorization ||
                ['unauthorized', 'forbidden'].contains(folderError))
              FilledButton.icon(
                key: const ValueKey('publication-authorize'),
                onPressed: c.editing ? null : c.authorize,
                icon: const Icon(Icons.add_link),
                label: Text(l.publicationAuthorize),
              ),
            if (c.editing) const LinearProgressIndicator(),
            if (c.accountError != null) Text(l.publicationAuthorizeHelp),
            if (c.error != null) Text(publicationMessage(l, c.error!.name)),
            if (settings == null && c.authorized) ...[
              DropdownButtonFormField<PublicationAccess>(
                initialValue: access,
                decoration: InputDecoration(labelText: l.publicationAccess),
                items: [
                  DropdownMenuItem(
                    value: PublicationAccess.private,
                    child: Text(l.publicationPrivate),
                  ),
                  DropdownMenuItem(
                    value: PublicationAccess.link,
                    child: Text(l.publicationLink),
                  ),
                ],
                onChanged: c.editing
                    ? null
                    : (v) => setState(() => access = v!),
              ),
              Text(
                access == PublicationAccess.link
                    ? l.publicationLinkHelp
                    : l.publicationPrivateHelp,
              ),
              if (folders != null)
                DropdownButtonFormField<String>(
                  initialValue: folder?.id ?? '',
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l.publicationFolder),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(l.publicationNewFolder),
                    ),
                    for (final f in folders!)
                      DropdownMenuItem(value: f.id, child: Text(f.name)),
                  ],
                  onChanged: c.editing
                      ? null
                      : (id) => setState(
                          () => folder = folders!
                              .where((f) => f.id == id)
                              .firstOrNull,
                        ),
                ),
              if (folders == null) Text(l.publicationNewFolder),
              if (folderError != null) Text(publicationMessage(l, folderError)),
              TextButton(
                onPressed: c.editing || loading
                    ? null
                    : () async {
                        setState(() => loading = true);
                        try {
                          final result = await c.folders();
                          if (mounted) {
                            setState(() {
                              folders = result;
                              folderError = null;
                            });
                          }
                        } on PublicationFailure catch (e) {
                          if (mounted) {
                            setState(() => folderError = e.issue.name);
                          }
                        } catch (_) {
                          if (mounted) setState(() => folderError = 'network');
                        } finally {
                          if (mounted) setState(() => loading = false);
                        }
                      },
                child: Text(l.publicationChooseFolder),
              ),
              FilledButton(
                key: const ValueKey('publication-configure'),
                onPressed: c.editing
                    ? null
                    : () => c.configure(access, folder: folder),
                child: Text(l.publicationEnable),
              ),
            ],
            if (settings != null) ...[
              Text('${l.publicationFolder}: ${settings.folderName}'),
              TextButton.icon(
                key: const ValueKey('publication-picker-settings'),
                onPressed: c.editing
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        builder: (_) => _PickerSettingsDialog(controller: c),
                      ),
                icon: const Icon(Icons.folder_open),
                label: Text(l.publicationPickerSettings),
              ),
              Text(
                settings.access == PublicationAccess.link
                    ? l.publicationLink
                    : l.publicationPrivate,
              ),
              if (!settings.folderReady)
                FilledButton(
                  onPressed: c.editing ? null : c.completeSetup,
                  child: Text(l.publicationCompleteSetup),
                )
              else
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.publicationAuto),
                  value: settings.enabled,
                  onChanged: c.editing ? null : c.setEnabled,
                ),
              if (c.error != null ||
                  c.queues.values.any((q) => q['status'] == 'error'))
                TextButton(
                  onPressed: c.busy ? null : () => c.request(force: true),
                  child: Text(l.runnerRetry),
                ),
            ],
          ],
        ),
      );
    },
  );
}

class UserPublicationView extends StatelessWidget {
  const UserPublicationView({
    required this.controller,
    required this.userId,
    super.key,
  });
  final PublicationController controller;
  final String userId;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context),
          queue = controller.queues[userId],
          result = controller.results[userId];
      if (controller.settings == null) return const SizedBox.shrink();
      final currentHash = controller.vpn.results[userId]?.sha256Hash;
      final published =
          result != null &&
          result['hash'] == currentHash &&
          queue?['status'] != 'error';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (controller.bindingPending(userId)) Text(l.publicationBindPending),
          Text(
            published
                ? l.publicationPublished
                : queue?['status'] == 'error'
                ? publicationMessage(l, queue?['issue'] as String?)
                : l.publicationWaiting,
          ),
          if (queue?['status'] == 'error')
            TextButton(
              onPressed: controller.busy
                  ? null
                  : () => controller.request(force: true),
              child: Text(l.runnerRetry),
            ),
        ],
      );
    },
  );
}

class _PickerSettingsDialog extends StatefulWidget {
  const _PickerSettingsDialog({required this.controller});
  final PublicationController controller;
  @override
  State<_PickerSettingsDialog> createState() => _PickerSettingsDialogState();
}

class _PickerSettingsDialogState extends State<_PickerSettingsDialog> {
  late final apiKey = TextEditingController(
    text: widget.controller.pickerApiKey,
  );
  late final appId = TextEditingController(text: widget.controller.pickerAppId);
  bool busy = false, invalid = false;
  @override
  void dispose() {
    apiKey.dispose();
    appId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(l.publicationPickerSettings),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l.publicationPickerSetupHelp),
                TextField(
                  key: const ValueKey('picker-api-key'),
                  controller: apiKey,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: l.publicationPickerApiKey,
                  ),
                ),
                TextField(
                  key: const ValueKey('picker-project-number'),
                  controller: appId,
                  enabled: !busy,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l.publicationPickerProject,
                  ),
                ),
                if (invalid) Text(l.publicationFailed),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: Text(l.runnerNotNow),
          ),
          FilledButton(
            key: const ValueKey('picker-settings-save'),
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      invalid = false;
                    });
                    try {
                      await widget.controller.configurePicker(
                        apiKey.text,
                        appId.text,
                      );
                      if (context.mounted) Navigator.pop(context);
                    } catch (_) {
                      if (mounted) setState(() => invalid = true);
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: Text(l.vpnSave),
          ),
        ],
      ),
    );
  }
}
