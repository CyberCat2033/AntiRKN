import 'dart:async';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'ssh_controller.dart';
import 'ssh_harden_controller.dart';

Future<bool> showSshHardenWizard(
  BuildContext context,
  SshController session,
) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _SshHardenDialog(session: session),
      ) ==
      true;
}

class _SshHardenDialog extends StatefulWidget {
  const _SshHardenDialog({required this.session});
  final SshController session;
  @override
  State<_SshHardenDialog> createState() => _SshHardenDialogState();
}

class _SshHardenDialogState extends State<_SshHardenDialog> {
  late final SshHardenController _flow;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _portCtrl;
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _disableRootLogin = true;
  String? _inputError;
  bool _closing = false;
  SshHardenStage get _stage => _flow.stage;
  int get _remainingSeconds => _flow.remainingSeconds;
  bool get _testInProgress => _flow.busy;
  String? get _error {
    final l = AppLocalizations.of(context);
    return _inputError ??
        switch (_flow.errorCode) {
          null => null,
          'ssh_harden_recovery_failed' => l.sshHardenRecoveryFailed,
          'ssh_harden_sudo_required' => l.sshHardenSudoRequired,
          'storage' => l.sshHardenStorageFailed,
          _ => l.sshHardenFailed,
        };
  }

  String get _statusMessage => AppLocalizations.of(context).sshHardenPreparing;

  @override
  void initState() {
    super.initState();
    final recovery = widget.session.profile?.hardenRecovery;
    _usernameCtrl = TextEditingController(
      text: recovery?['user'] as String? ?? randomFmaUsername(),
    );
    _portCtrl = TextEditingController(text: '${recovery?['port'] ?? 2222}');
    _flow = SshHardenController(widget.session)..addListener(_changed);
    if (recovery != null) unawaited(_flow.poll());
  }

  void _changed() {
    if (!mounted || _closing) return;
    if (_flow.terminal) {
      _closing = true;
      final success = _stage == SshHardenStage.done;
      if (success) AppHaptics.added();
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? l.sshHardenConfirmed : l.sshHardenAborted),
        ),
      );
      Navigator.pop(context, success);
      widget.session.disconnect();
      unawaited(widget.session.connect());
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _flow.removeListener(_changed);
    _flow.dispose();
    _usernameCtrl.dispose();
    _portCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _pickRandomUsername() =>
      setState(() => _usernameCtrl.text = randomFmaUsername());

  Future<void> _startHardening() async {
    final l = AppLocalizations.of(context);
    final username = _usernameCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    final password = _passwordCtrl.text;
    String? issue;
    if (!RegExp(r'^[a-z_][a-z0-9_-]{1,31}$').hasMatch(username) ||
        port == null ||
        port < 1024 ||
        port > 65535) {
      issue = l.sshHardenInvalid;
    } else if (password.isEmpty ||
        !validSudoPassword(password) ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(password)) {
      issue = l.sshHardenPasswordRequired;
    } else if (password != _confirmCtrl.text) {
      issue = l.sshHardenPasswordMismatch;
    }
    setState(() => _inputError = issue);
    if (issue != null) return;
    await _flow.start(
      username: username,
      port: port!,
      password: password,
      disableRootLogin: _disableRootLogin,
    );
  }

  Future<void> _runClientTest(int port, String username, String password) =>
      _flow.retry();
  Future<void> _confirmHardening() => _flow.confirm();
  Future<void> _abortHardening() => _flow.abort();

  String _formatTimer(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return PopScope(
      canPop: _stage == SshHardenStage.input || _flow.terminal,
      child: AppFormDialog(
        title: Text(l.sshHardenDialogTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_stage == SshHardenStage.input) ...[
                Text(
                  l.sshHardenDialogDescription,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Card(
                  color: theme.colorScheme.tertiaryContainer.withAlpha(80),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          color: theme.colorScheme.tertiary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l.sshHardenFirewallWarning(
                              int.tryParse(_portCtrl.text) ?? 2222,
                            ),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _usernameCtrl,
                        decoration: InputDecoration(
                          labelText: l.sshHardenUsername,
                          prefixIcon: const Icon(Icons.person_outline),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: l.sshHardenRandomUser,
                      onPressed: _pickRandomUsername,
                      icon: const Icon(Icons.casino_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _portCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l.sshHardenPort,
                    prefixIcon: const Icon(Icons.tag),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordCtrl,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: l.sshHardenSudoPassword,
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirmCtrl,
                  obscureText: _obscureConfirm,
                  decoration: InputDecoration(
                    labelText: l.sshHardenSudoPasswordConfirm,
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirm
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                    ),
                  ),
                ),
                CheckboxListTile(
                  value: _disableRootLogin,
                  onChanged: (value) =>
                      setState(() => _disableRootLogin = value ?? true),
                  title: Text(l.sshHardenDisableRoot),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
              if (_stage == SshHardenStage.preparing ||
                  _stage == SshHardenStage.staging) ...[
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: CircularProgressIndicator(),
                  ),
                ),
                Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              if (_stage == SshHardenStage.testing ||
                  _stage == SshHardenStage.testFailed) ...[
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      children: [
                        if (_testInProgress)
                          const CircularProgressIndicator()
                        else
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 48,
                            color: theme.colorScheme.error,
                          ),
                        const SizedBox(height: 12),
                        Text(
                          l.sshHardenTesting,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Chip(
                          avatar: const Icon(Icons.timer_outlined, size: 18),
                          label: Text(
                            l.sshHardenTestingCountdown(
                              _formatTimer(_remainingSeconds),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_stage == SshHardenStage.tested) ...[
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: 56,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l.sshHardenTestSuccess(
                            _usernameCtrl.text.trim(),
                            int.tryParse(_portCtrl.text) ?? 2222,
                          ),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_stage == SshHardenStage.confirming ||
                  _stage == SshHardenStage.aborting) ...[
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: CircularProgressIndicator(),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                AppNotice(message: _error!, error: true),
              ],
            ],
          ),
        ),
        actions: [
          if (_stage == SshHardenStage.input) ...[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.sshCancel),
            ),
            FilledButton(
              onPressed: _flow.busy ? null : _startHardening,
              child: Text(l.sshHardenStartAction),
            ),
          ],
          if (_stage == SshHardenStage.preparing) ...[
            TextButton(
              key: const ValueKey('ssh-harden-cancel-preparing'),
              onPressed: _flow.canCancelPreparation
                  ? _flow.cancelPreparation
                  : null,
              child: Text(l.sshCancel),
            ),
          ],
          if (_stage == SshHardenStage.staging) ...[
            TextButton(
              onPressed: _flow.busy ? null : _abortHardening,
              child: Text(l.sshHardenAbortAction),
            ),
          ],
          if (_stage == SshHardenStage.testing ||
              _stage == SshHardenStage.testFailed) ...[
            TextButton(
              onPressed: _flow.busy ? null : _abortHardening,
              child: Text(l.sshHardenAbortAction),
            ),
            FilledButton(
              onPressed: _testInProgress
                  ? null
                  : () => _runClientTest(
                      int.tryParse(_portCtrl.text) ?? 2222,
                      _usernameCtrl.text.trim(),
                      _passwordCtrl.text,
                    ),
              child: Text(l.sshHardenRetryAction),
            ),
          ],
          if (_stage == SshHardenStage.tested) ...[
            TextButton(
              onPressed: _flow.busy ? null : _abortHardening,
              child: Text(l.sshHardenAbortAction),
            ),
            FilledButton(
              onPressed: _flow.busy ? null : _confirmHardening,
              child: Text(l.sshHardenConfirmAction),
            ),
          ],
        ],
      ),
    );
  }
}
