import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'backup_controller.dart';

class BackupPanel extends StatelessWidget {
  const BackupPanel({
    required this.store,
    required this.files,
    required this.onRestored,
    required this.canRestore,
    this.showTitle = true,
    super.key,
  });
  final bool showTitle;
  final WorkspaceBackupStore store;
  final BackupFileStore files;
  final Future<void> Function() onRestored;
  final bool Function() canRestore;

  Future<void> _open(BuildContext context, bool importing) async {
    final restored = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BackupDialog(
        store: store,
        files: files,
        importing: importing,
        canRestore: canRestore,
      ),
    );
    if (restored == true) await onRestored();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final content = Column(
      children: [
        ListTile(
          key: const ValueKey('backup-export'),
          leading: const Icon(Icons.save_alt),
          title: Text(l.backupExport),
          subtitle: Text(l.uiBackupExportHelp),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            _open(context, false);
          },
        ),
        const Divider(indent: 17, endIndent: 17),
        ListTile(
          key: const ValueKey('backup-import'),
          leading: const Icon(Icons.history),
          title: Text(l.backupImport),
          subtitle: Text(l.uiBackupImportHelp),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            _open(context, true);
          },
        ),
      ],
    );
    return showTitle
        ? AppSettingsSection(title: l.uiApplicationData, child: content)
        : content;
  }
}

class _BackupDialog extends StatefulWidget {
  const _BackupDialog({
    required this.store,
    required this.files,
    required this.importing,
    required this.canRestore,
  });
  final WorkspaceBackupStore store;
  final BackupFileStore files;
  final bool importing;
  final bool Function() canRestore;
  @override
  State<_BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends State<_BackupDialog> {
  late final _controller = BackupController(
    store: widget.store,
    files: widget.files,
  );
  final _password = TextEditingController(), _repeat = TextEditingController();
  bool _visible = false, _invalid = false, _activeWork = false;

  @override
  void dispose() {
    _password.clear();
    _repeat.clear();
    _password.dispose();
    _repeat.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _invalid =
          _password.text.runes.length < 12 ||
          (!widget.importing && _password.text != _repeat.text);
      _activeWork = widget.importing && !widget.canRestore();
    });
    if (_invalid || _activeWork) return;
    if (widget.importing) {
      await _controller.prepare(_password.text);
    } else {
      await _controller.export(_password.text);
    }
    if (mounted && (_controller.summary != null || _controller.completed)) {
      _password.clear();
      _repeat.clear();
    }
  }

  Future<void> _restore() async {
    if (!widget.canRestore()) {
      setState(() => _activeWork = true);
      return;
    }
    await _controller.restore();
    if (mounted && _controller.completed) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context), c = _controller;
      final summary = c.summary;
      final error = switch (c.error) {
        BackupIssue.password => l.backupPasswordHelp,
        BackupIssue.invalid => l.backupInvalid,
        BackupIssue.version => l.backupVersion,
        BackupIssue.tooLarge => l.backupTooLarge,
        BackupIssue.changed => l.backupChanged,
        BackupIssue.storage => l.backupStorage,
        BackupIssue.file => l.backupFileError,
        null => null,
      };
      return PopScope(
        canPop: !c.busy,
        child: AppFormDialog(
          title: Text(widget.importing ? l.backupImport : l.backupExport),
          // AppFormDialog scrolls its content; a second scroll view here
          // nested two scrollables (UI-65).
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Fixed height: the bar appearing must not move the form.
                SizedBox(
                  height: 4,
                  child: c.busy ? const LinearProgressIndicator() : null,
                ),
                const SizedBox(height: AppLayout.smallGap),
                if (c.busy) Text(l.backupWorking),
                if (c.completed)
                  Text(l.backupSaved)
                else if (summary != null) ...[
                  Text(
                    l.backupSummary(
                      summary.createdAt.toLocal().toString(),
                      summary.servers,
                      summary.users,
                    ),
                  ),
                  const SizedBox(height: AppLayout.gap),
                  Text(l.backupReplaceHelp),
                ] else ...[
                  if (c.error == BackupIssue.password)
                    AppNotice(message: l.backupPasswordHelp, error: true)
                  else
                    Text(l.backupPasswordHelp),
                  const SizedBox(height: AppLayout.gap),
                  TextField(
                    key: const ValueKey('backup-password'),
                    controller: _password,
                    enabled: !c.busy,
                    obscureText: !_visible,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: widget.importing
                        ? TextInputAction.done
                        : TextInputAction.next,
                    onSubmitted: widget.importing && !c.busy
                        ? (_) => _start()
                        : null,
                    decoration: InputDecoration(
                      labelText: l.backupPassword,
                      suffixIcon: IconButton(
                        onPressed: c.busy
                            ? null
                            : () => setState(() => _visible = !_visible),
                        tooltip: _visible
                            ? l.backupHidePassword
                            : l.backupShowPassword,
                        icon: Icon(
                          _visible ? Icons.visibility_off : Icons.visibility,
                        ),
                      ),
                    ),
                  ),
                  if (!widget.importing) ...[
                    const SizedBox(height: AppLayout.gap),
                    TextField(
                      key: const ValueKey('backup-repeat'),
                      controller: _repeat,
                      enabled: !c.busy,
                      obscureText: !_visible,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: c.busy ? null : (_) => _start(),
                      decoration: InputDecoration(labelText: l.backupRepeat),
                    ),
                  ],
                  if (_invalid)
                    AppNotice(
                      message: l.backupPasswordMismatch,
                      error: true,
                      margin: const EdgeInsets.only(top: AppLayout.gap),
                    ),
                ],
                if (_activeWork) Text(l.backupActiveWork),
                // The password help above the field is that error's text;
                // it is shown once (UI-51).
                if (error != null &&
                    !(c.error == BackupIssue.password &&
                        !c.completed &&
                        summary == null))
                  AppNotice(
                    message: error,
                    error: true,
                    margin: const EdgeInsets.only(top: AppLayout.gap),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: c.busy ? null : () => Navigator.of(context).pop(false),
              child: Text(c.completed ? l.backupClose : l.backupCancel),
            ),
            if (!c.completed && summary != null)
              // Replacing the workspace cannot be undone: the confirming
              // action carries the error colours (UI-55).
              AppDangerButton(
                key: const ValueKey('backup-proceed'),
                onPressed: c.busy ? null : _restore,
                child: Text(l.backupReplace),
              )
            else if (!c.completed)
              FilledButton(
                key: const ValueKey('backup-proceed'),
                onPressed: c.busy ? null : _start,
                child: Text(widget.importing ? l.backupSelect : l.backupExport),
              ),
          ],
        ),
      );
    },
  );
}
