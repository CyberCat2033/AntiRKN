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
  const PublicationSettingsPanel({
    required this.controller,
    this.showTitle = true,
    this.configuration = false,
    super.key,
  });
  final bool showTitle, configuration;
  final PublicationController controller;
  @override
  State<PublicationSettingsPanel> createState() => _PublicationSettingsState();
}

class _PublicationSettingsState extends State<PublicationSettingsPanel> {
  static const access = PublicationAccess.link;
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
      if (settings == null && !widget.configuration) {
        final setup = ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(l.publicationTitle),
          subtitle: Text(l.publicationHelp),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => AppFormDialog(
              title: Text(l.publicationTitle),
              content: PublicationSettingsPanel(
                controller: c,
                showTitle: false,
                configuration: true,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l.networkClose),
                ),
              ],
            ),
          ),
        );
        return widget.showTitle
            ? AppSettingsSection(title: l.uiClientProfiles, child: setup)
            : setup;
      }

      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (settings == null) Text(l.publicationHelp),
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
            Text(l.publicationLinkHelp),
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
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(l.publicationFolder),
              subtitle: Text(settings.folderName),
              onTap: () => showAppDetails(
                context,
                title: l.publicationFolder,
                children: [SelectableText(settings.folderName)],
              ),
            ),
            if (!c.pickerReady)
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
            const Divider(indent: 17, endIndent: 17),
            if (!settings.folderReady)
              FilledButton(
                onPressed: c.editing ? null : c.completeSetup,
                child: Text(l.publicationCompleteSetup),
              )
            else
              SwitchListTile(
                title: Text(l.publicationAuto),
                subtitle: Text(l.uiPublicationAutoHelp),
                value: settings.enabled,
                onChanged: c.editing
                    ? null
                    : (value) {
                        AppHaptics.selection();
                        c.setEnabled(value);
                      },
              ),
            if (c.error != null ||
                c.queues.values.any((q) => q['status'] == 'error'))
              TextButton(
                onPressed: c.busy ? null : () => c.request(force: true),
                child: Text(l.runnerRetry),
              ),
          ],
        ],
      );
      return widget.showTitle
          ? AppSettingsSection(title: l.publicationTitle, child: content)
          : content;
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
      child: AppFormDialog(
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
