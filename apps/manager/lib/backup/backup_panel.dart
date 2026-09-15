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
    super.key,
  });
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
    return SectionCard(
      title: l.backupTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.backupHelp),
          const SizedBox(height: AppLayout.smallGap),
          Wrap(
            spacing: AppLayout.smallGap,
            runSpacing: AppLayout.smallGap,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('backup-export'),
                onPressed: () => _open(context, false),
                icon: const Icon(Icons.save_alt),
                label: Text(l.backupExport),
              ),
              OutlinedButton.icon(
                key: const ValueKey('backup-import'),
                onPressed: () => _open(context, true),
                icon: const Icon(Icons.restore),
                label: Text(l.backupImport),
              ),
            ],
          ),
        ],
      ),
    );
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
        child: AlertDialog(
          title: Text(widget.importing ? l.backupImport : l.backupExport),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (c.busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: AppLayout.smallGap),
                    Text(l.backupWorking),
                  ],
                  if (c.completed)
                    Text(l.backupSaved)
                  else if (summary != null) ...[
                    Text(
                      l.backupSummary(
                        summary.createdAt.toLocal().toString(),
                        summary.servers,
                        summary.users,
                        summary.changes,
                        summary.pending,
                      ),
                    ),
                    const SizedBox(height: AppLayout.gap),
                    Text(l.backupReplaceHelp),
                  ] else ...[
                    Text(l.backupPasswordHelp),
                    TextField(
                      key: const ValueKey('backup-password'),
                      controller: _password,
                      enabled: !c.busy,
                      obscureText: !_visible,
                      autocorrect: false,
                      enableSuggestions: false,
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
                    if (!widget.importing)
                      TextField(
                        key: const ValueKey('backup-repeat'),
                        controller: _repeat,
                        enabled: !c.busy,
                        obscureText: !_visible,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(labelText: l.backupRepeat),
                      ),
                    if (_invalid) Text(l.backupPasswordMismatch),
                  ],
                  if (_activeWork) Text(l.backupActiveWork),
                  if (error != null)
                    Semantics(liveRegion: true, child: Text(error)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: c.busy ? null : () => Navigator.of(context).pop(false),
              child: Text(c.completed ? l.backupClose : l.backupCancel),
            ),
            if (!c.completed)
              FilledButton(
                key: const ValueKey('backup-proceed'),
                onPressed: c.busy
                    ? null
                    : summary != null
                    ? _restore
                    : _start,
                child: Text(
                  summary != null
                      ? l.backupReplace
                      : widget.importing
                      ? l.backupSelect
                      : l.backupExport,
                ),
              ),
          ],
        ),
      );
    },
  );
}
