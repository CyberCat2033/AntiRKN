import 'dart:async';
import 'package:antirkn_design_system/antirkn_design_system.dart';
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
  int backoffSeconds = minBackoffSeconds;
  static const int minBackoffSeconds = 2;
  static const int maxBackoffSeconds = 15;

  void _scheduleNext([int? delaySeconds]) {
    timer?.cancel();
    if (!mounted) return;
    final delay = delaySeconds ?? backoffSeconds;
    timer = Timer(Duration(seconds: delay), () {
      unawaited(observe());
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleNext(minBackoffSeconds);
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
      if (mounted && pendingId != null && !expired) {
        _scheduleNext();
      } else if (mounted) {
        _scheduleNext(minBackoffSeconds);
      }
      return;
    }
    final id = pendingId!;
    if (watched != id) {
      watched = id;
      until = DateTime.now().add(const Duration(minutes: 3));
      backoffSeconds = minBackoffSeconds;
    }
    if (expired) {
      setState(() {});
      return;
    }
    checking = true;
    var completed = false;
    try {
      if (c.stage != SshStage.connected &&
          await c.connectForDeletion() != true) {
        backoffSeconds = (backoffSeconds * 2).clamp(
          minBackoffSeconds,
          maxBackoffSeconds,
        );
        return;
      }
      await c.runner.waitUntilIdle();
      if (!mounted || !foreground) return;
      await c.runner.refresh();
      if (c.runner.selected?.kind == 'server_reboot' &&
          c.runner.selected?.status == 'succeeded') {
        await c.refresh();
        completed = true;
        backoffSeconds = minBackoffSeconds;
      }
    } catch (_) {
      backoffSeconds = (backoffSeconds * 2).clamp(
        minBackoffSeconds,
        maxBackoffSeconds,
      );
    } finally {
      checking = false;
      if (mounted) {
        setState(() {});
        if (!completed && !expired && pendingId != null) {
          _scheduleNext();
        } else if (!completed) {
          _scheduleNext(minBackoffSeconds);
        }
      }
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
                  final accepted = await confirmAppDanger(
                    context,
                    title: l.serverReboot,
                    message: l.serverRebootConfirm,
                    confirmLabel: l.serverReboot,
                    cancelLabel: l.runnerNotNow,
                    confirmKey: const ValueKey('server-reboot-confirm'),
                  );
                  if (!accepted || !mounted) return;
                  attempted = true;
                  await c.runner.rebootServer();
                  if (!mounted) return;
                  setState(() {});
                  if (pendingId != null) {
                    backoffSeconds = minBackoffSeconds;
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
