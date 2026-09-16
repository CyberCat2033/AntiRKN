import 'dart:async';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../runner/runner_panel.dart';
import 'ssh_controller.dart';

enum _HardenStage {
  input,
  preparing,
  staging,
  testing,
  tested,
  testFailed,
  confirming,
  aborting,
}

Future<bool> showSshHardenWizard(
  BuildContext context,
  SshController session,
) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _SshHardenDialog(session: session),
  );
  return result == true;
}

class _SshHardenDialog extends StatefulWidget {
  const _SshHardenDialog({required this.session});
  final SshController session;

  @override
  State<_SshHardenDialog> createState() => _SshHardenDialogState();
}

class _SshHardenDialogState extends State<_SshHardenDialog> {
  _HardenStage _stage = _HardenStage.input;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _passwordCtrl;
  late final TextEditingController _confirmCtrl;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  String? _jobId;
  String? _error;
  String? _statusMessage;
  Timer? _countdownTimer;
  int _remainingSeconds = 300;
  bool _testInProgress = false;

  @override
  void initState() {
    super.initState();
    _usernameCtrl = TextEditingController(text: randomFmaUsername());
    _portCtrl = TextEditingController(text: '2222');
    _passwordCtrl = TextEditingController();
    _confirmCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _usernameCtrl.dispose();
    _portCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _pickRandomUsername() {
    setState(() {
      _usernameCtrl.text = randomFmaUsername();
    });
  }

  Future<void> _startHardening() async {
    final l = AppLocalizations.of(context);
    final username = _usernameCtrl.text.trim();
    final portText = _portCtrl.text.trim();
    final password = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;

    if (!RegExp(r'^[a-z_][a-z0-9_-]{1,31}$').hasMatch(username)) {
      setState(() => _error = l.sshHardenInvalid);
      return;
    }
    final port = int.tryParse(portText);
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _error = l.sshHardenInvalid);
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = l.sshHardenPasswordRequired);
      return;
    }
    if (password != confirm) {
      setState(() => _error = l.sshHardenPasswordMismatch);
      return;
    }

    setState(() {
      _stage = _HardenStage.preparing;
      _error = null;
      _statusMessage = l.sshHardenPreparing;
    });

    final runner = widget.session.runner;
    final plan = await runner.prepareSshHarden(username: username, port: port);

    if (!mounted) return;
    if (plan == null || !plan.supported) {
      setState(() {
        _stage = _HardenStage.input;
        _error = runnerCodeLabel(l, runner.responseCode ?? 'ssh_harden_failed');
      });
      return;
    }
    if (!plan.portAvailable) {
      setState(() {
        _stage = _HardenStage.input;
        _error = l.sshHardenPortBusy;
      });
      return;
    }
    if (!plan.userAvailable) {
      setState(() {
        _stage = _HardenStage.input;
        _error = l.sshHardenConflict;
      });
      return;
    }

    setState(() {
      _stage = _HardenStage.staging;
      _statusMessage = l.sshHardenUserCreated;
    });

    final jobId = await runner.submitSshHarden(
      plan: plan,
      username: username,
      port: port,
      sudoPassword: password,
      deadlineSeconds: 300,
    );

    if (!mounted) return;
    if (jobId == null) {
      setState(() {
        _stage = _HardenStage.input;
        _error = runnerCodeLabel(l, runner.responseCode ?? 'ssh_harden_failed');
      });
      return;
    }

    _jobId = jobId;
    _pollStaging(jobId, port, username, password);
  }

  void _pollStaging(String jobId, int port, String username, String password) {
    final runner = widget.session.runner;
    void check() {
      if (!mounted || _stage != _HardenStage.staging) return;
      final job =
          runner.jobs.where((j) => j.id == jobId).firstOrNull ??
          runner.selected;
      if (job == null) {
        Future.delayed(const Duration(milliseconds: 500), check);
        return;
      }

      final l = AppLocalizations.of(context);
      final lastEvent = job.events.lastOrNull;
      if (lastEvent != null) {
        setState(() {
          _statusMessage = runnerEventLabel(l, lastEvent.code);
        });
      }

      if (job.status == 'failed') {
        setState(() {
          _stage = _HardenStage.input;
          _error = runnerCodeLabel(l, lastEvent?.code ?? 'ssh_harden_failed');
        });
        return;
      }

      if (job.checkpoint >= 6) {
        _startTestingCountdown(port, username, password);
        return;
      }

      Future.delayed(const Duration(milliseconds: 500), check);
    }

    check();
  }

  void _startTestingCountdown(int port, String username, String password) {
    setState(() {
      _stage = _HardenStage.testing;
      _remainingSeconds = 300;
    });

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _remainingSeconds--;
        if (_remainingSeconds <= 0) {
          timer.cancel();
          _stage = _HardenStage.testFailed;
          _error = AppLocalizations.of(context).sshHardenAborted;
        }
      });
    });

    _runClientTest(port, username, password);
  }

  Future<void> _runClientTest(
    int port,
    String username,
    String password,
  ) async {
    if (_testInProgress) return;
    final l = AppLocalizations.of(context);
    setState(() {
      _testInProgress = true;
      _error = null;
    });

    final currentProfile = widget.session.profile;
    if (currentProfile == null) {
      setState(() {
        _testInProgress = false;
        _stage = _HardenStage.testFailed;
        _error = l.sshHardenFailed;
      });
      return;
    }

    final testProfile = currentProfile.withHardenedAccess(
      user: username,
      port: port,
      sudoPassword: password,
    );

    final token = CancellationToken();
    try {
      final conn = await widget.session.connector.connect(
        testProfile,
        verifyHostKey: (key) async {
          return currentProfile.hostKey == null ||
              currentProfile.hostKey!.matches(key);
        },
        cancellation: token,
      );

      final priv = await conn.checkPrivileges(token, sudoPassword: password);
      conn.close();

      if (!mounted) return;
      if (priv.granted) {
        AppHaptics.added();
        setState(() {
          _testInProgress = false;
          _stage = _HardenStage.tested;
          _error = null;
        });
      } else {
        setState(() {
          _testInProgress = false;
          _stage = _HardenStage.testFailed;
          _error = l.privilegesAuthentication;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testInProgress = false;
        _stage = _HardenStage.testFailed;
        _error = l.sshHardenTestFailed(port);
      });
    }
  }

  Future<void> _confirmHardening() async {
    final l = AppLocalizations.of(context);
    if (_jobId == null) return;
    setState(() {
      _stage = _HardenStage.confirming;
      _error = null;
    });
    _countdownTimer?.cancel();

    final runner = widget.session.runner;
    final result = await runner.confirmSshHarden(_jobId!);

    if (!mounted) return;
    if (result == null || !result.confirmed) {
      setState(() {
        _stage = _HardenStage.testFailed;
        _error = runnerCodeLabel(l, runner.responseCode ?? 'ssh_harden_failed');
      });
      return;
    }

    final saved = await widget.session.applyHardenedCredentials(
      username: _usernameCtrl.text.trim(),
      port: int.parse(_portCtrl.text.trim()),
      sudoPasswordText: _passwordCtrl.text,
    );

    if (!mounted) return;
    if (saved) {
      AppHaptics.added();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.sshHardenConfirmed)));
      Navigator.pop(context, true);
      unawaited(widget.session.connect());
    } else {
      setState(() {
        _stage = _HardenStage.testFailed;
        _error = l.sshHardenFailed;
      });
    }
  }

  Future<void> _abortHardening() async {
    final l = AppLocalizations.of(context);
    if (_jobId != null) {
      setState(() {
        _stage = _HardenStage.aborting;
      });
      _countdownTimer?.cancel();
      await widget.session.runner.abortSshHarden(_jobId!);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.sshHardenAborted)));
    Navigator.pop(context, false);
  }

  String _formatTimer(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return AppFormDialog(
      title: Text(l.sshHardenDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_stage == _HardenStage.input) ...[
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
                      _obscureConfirm ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                ),
              ),
            ],
            if (_stage == _HardenStage.preparing ||
                _stage == _HardenStage.staging) ...[
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: CircularProgressIndicator(),
                ),
              ),
              if (_statusMessage != null)
                Text(
                  _statusMessage!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
            ],
            if (_stage == _HardenStage.testing ||
                _stage == _HardenStage.testFailed) ...[
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
            if (_stage == _HardenStage.tested) ...[
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
            if (_stage == _HardenStage.confirming ||
                _stage == _HardenStage.aborting) ...[
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
        if (_stage == _HardenStage.input) ...[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.sshCancel),
          ),
          FilledButton(
            onPressed: _startHardening,
            child: Text(l.sshHardenStartAction),
          ),
        ],
        if (_stage == _HardenStage.testing ||
            _stage == _HardenStage.testFailed) ...[
          TextButton(
            onPressed: _abortHardening,
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
        if (_stage == _HardenStage.tested) ...[
          TextButton(
            onPressed: _abortHardening,
            child: Text(l.sshHardenAbortAction),
          ),
          FilledButton(
            onPressed: _confirmHardening,
            child: Text(l.sshHardenConfirmAction),
          ),
        ],
      ],
    );
  }
}
