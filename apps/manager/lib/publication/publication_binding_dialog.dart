import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'publication_controller.dart';
import 'publication_panel.dart';

class PublicationBindingDialog extends StatefulWidget {
  const PublicationBindingDialog({
    required this.controller,
    required this.user,
    super.key,
  });
  final PublicationController controller;
  final VpnUser user;
  @override
  State<PublicationBindingDialog> createState() =>
      _PublicationBindingDialogState();
}

class _PublicationBindingDialogState extends State<PublicationBindingDialog> {
  final link = TextEditingController();
  PublicationBindingPreview? preview;
  bool busy = false, picking = false;
  String? issue;
  @override
  void initState() {
    super.initState();
    final pending = widget.controller.bindings[widget.user.id];
    if (widget.controller.bindingPending(widget.user.id) && pending != null) {
      link.text = targetText(
        PublicationTarget(
          pending['fileId'] as String,
          resourceKey: pending['resourceKey'] as String?,
        ),
      );
    }
  }

  @override
  void dispose() {
    link.dispose();
    super.dispose();
  }

  Future<PublicationBindingPreview?> inspect({bool pick = false}) async {
    setState(() {
      busy = true;
      picking = pick;
      issue = null;
      preview = null;
    });
    try {
      final target = pick
          ? await widget.controller.pickFile()
          : PublicationTarget.parse(link.text);
      if (target == null || !mounted) return null;
      link.text = targetText(target);
      final value = await widget.controller.inspectFile(widget.user.id, target);
      if (mounted) setState(() => preview = value);
      return value;
    } on PublicationFailure catch (e) {
      if (mounted) setState(() => issue = e.issue.name);
      return null;
    } on GoogleAccountFailure {
      if (mounted) setState(() => issue = 'picker');
      return null;
    } catch (_) {
      if (mounted) setState(() => issue = 'invalid');
      return null;
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          picking = false;
        });
      }
    }
  }

  Future<void> submit() async {
    if (busy) return;
    var target = preview;
    if (target == null) {
      target = await inspect();
      if (!mounted || target == null) return;
    }
    setState(() {
      busy = true;
      issue = null;
    });
    try {
      await widget.controller.bindFile(target);
      if (mounted) Navigator.pop(context);
    } on PublicationFailure catch (e) {
      if (mounted) {
        setState(() {
          issue = e.issue.name;
          preview = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          issue = 'conflict';
          preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String targetText(PublicationTarget target) => target.resourceKey == null
      ? target.fileId
      : Uri.https('drive.google.com', '/uc', {
          'id': target.fileId,
          'resourcekey': target.resourceKey!,
        }).toString();

  String excerpt(String value) =>
      value.length > 32000 ? '${value.substring(0, 32000)}\n…' : value;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context),
        c = widget.controller,
        value = preview;
    return PopScope(
      canPop: !busy,
      child: AppFormDialog(
        title: Text(l.publicationBindTitle),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.user.name),
                Text(l.publicationBindHelp),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('publication-file-link'),
                  controller: link,
                  enabled: !busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: l.publicationFileLink),
                  onSubmitted: busy ? null : (_) => submit(),
                  onChanged: (_) => setState(() {
                    preview = null;
                    issue = null;
                  }),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: busy ? null : inspect,
                      child: Text(l.publicationInspect),
                    ),
                    TextButton.icon(
                      key: const ValueKey('publication-pick-file'),
                      onPressed: busy || !c.pickerReady
                          ? null
                          : () => inspect(pick: true),
                      icon: const Icon(Icons.folder_open),
                      label: Text(l.publicationPickFile),
                    ),
                  ],
                ),
                if (!c.pickerReady) Text(l.publicationPickerSetupHelp),
                if (busy) const LinearProgressIndicator(),
                if (picking) Text(l.publicationPickerWaiting),
                if (issue != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      ['missing', 'forbidden', 'unauthorized'].contains(issue)
                          ? l.publicationFileAccessHelp
                          : issue == 'picker'
                          ? l.publicationPickerSetupHelp
                          : issue == 'invalid'
                          ? l.publicationBindInvalid
                          : publicationMessage(l, issue),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (value != null) ...[
                  const Divider(),
                  Text(
                    value.file.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SelectableText(value.file.id),
                  Text(l.publicationBindReplace),
                  Text(
                    c.settings?.access == PublicationAccess.link
                        ? l.publicationLinkHelp
                        : l.publicationPrivateHelp,
                  ),
                  AppExpansionTile(
                    key: const PageStorageKey('binding-old-preview'),
                    title: Text(l.publicationOldContent),
                    children: [SelectableText(excerpt(value.content))],
                  ),
                  AppExpansionTile(
                    key: const PageStorageKey('binding-new-preview'),
                    title: Text(l.publicationNewContent),
                    children: [
                      SelectableText(excerpt(utf8.decode(value.draft.bytes))),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy
                ? (picking ? () => c.picker?.cancel() : null)
                : () => Navigator.pop(context),
            child: Text(l.runnerNotNow),
          ),
          FilledButton(
            key: const ValueKey('publication-bind-confirm'),
            onPressed: busy || (value == null && link.text.trim().isEmpty)
                ? null
                : submit,
            child: Text(l.publicationBindConfirm),
          ),
        ],
      ),
    );
  }
}
