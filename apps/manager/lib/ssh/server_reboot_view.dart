import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'ssh_controller.dart';

class ServerRebootView extends StatefulWidget {
  const ServerRebootView({required this.controller, super.key});
  final SshController controller;
  @override
  State<ServerRebootView> createState() => _ServerRebootViewState();
}

class _ServerRebootViewState extends State<ServerRebootView>
    with WidgetsBindingObserver {
  Timer? timer;
  bool checking = false, foreground = true, attempted = false;
  String? watched;
  DateTime? until;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(observe()),
    );
  }

  String? get pendingId {
    final runner = widget.controller.runner;
    if (runner.pending?.json['kind'] == 'server_reboot') {
      return runner.pending!.id;
    }
    final job = runner.selected;
    return job?.kind == 'server_reboot' && job?.terminal == false
        ? job!.id
        : null;
  }

  bool get expired => until != null && DateTime.now().isAfter(until!);
  Future<void> observe() async {
    final c = widget.controller;
    if (!mounted ||
        !foreground ||
        checking ||
        pendingId == null ||
        c.busy ||
        c.runner.busy) {
      return;
    }
    final id = pendingId!;
    if (watched != id) {
      watched = id;
      until = DateTime.now().add(const Duration(minutes: 3));
    }
    if (expired) {
      setState(() {});
      return;
    }
    checking = true;
    try {
      if (c.stage != SshStage.connected &&
          await c.connectForDeletion() != true) {
        return;
      }
      await c.runner.waitUntilIdle();
      if (!mounted || !foreground) return;
      await c.runner.refresh();
      if (c.runner.selected?.kind == 'server_reboot' &&
          c.runner.selected?.status == 'succeeded') {
        await c.refresh();
      }
    } finally {
      checking = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller,
        l = AppLocalizations.of(context),
        job = c.runner.selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('server-reboot'),
          onPressed: c.busy || !c.runner.canRequestAction
              ? null
              : () async {
                  final accepted = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(l.serverReboot),
                      content: Text(l.serverRebootConfirm),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(l.runnerNotNow),
                        ),
                        FilledButton(
                          key: const ValueKey('server-reboot-confirm'),
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(l.serverReboot),
                        ),
                      ],
                    ),
                  );
                  if (accepted != true || !mounted) return;
                  attempted = true;
                  await c.runner.rebootServer();
                  if (!mounted) return;
                  setState(() {});
                  if (pendingId != null) {
                    // Let the durable submit reply arrive before closing the old SSH.
                    await Future<void>.delayed(const Duration(seconds: 4));
                    if (!mounted || !foreground) return;
                    c.disconnect();
                    await observe();
                  }
                },
          icon: const Icon(Icons.restart_alt),
          label: Text(l.serverReboot),
        ),
        if (job?.kind == 'server_reboot' || pendingId != null || attempted)
          Text(
            job?.kind == 'server_reboot' && job?.status == 'succeeded'
                ? l.serverRebootDone
                : expired || pendingId == null
                ? l.serverRebootFailed
                : l.serverRebootWaiting,
          ),
      ],
    );
  }
}
