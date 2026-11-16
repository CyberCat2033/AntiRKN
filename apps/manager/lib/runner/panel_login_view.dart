import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'runner_controller.dart';
import 'runner_panel.dart';

Future<bool> showPanelLogin(
  BuildContext context,
  RunnerController controller, {
  int? port,
}) async {
  if (!await controller.ensureReady() || !context.mounted) return false;
  port ??=
      controller.panels
              .where((p) => p['source'] == 'systemd')
              .firstOrNull?['port']
          as int? ??
      controller.panelAccess?.port;
  if (port == null) return false;
  if (controller.panelAccess?.port == port) {
    if (!controller.panelLoginRequired) {
      return true;
    }
    final saved = controller.panelAccess;
    if (saved != null &&
        saved.username.isNotEmpty &&
        saved.password.isNotEmpty) {
      final reconnected = await controller.connectPanel(
        port,
        saved.username,
        saved.password,
      );
      if (reconnected && !controller.panelLoginRequired) {
        return true;
      }
    }
  }
  final selectedPort = port;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AppFormDialog(
          title: Text(AppLocalizations.of(context).panelConnectTitle),
          content: PanelLoginView(
            controller: controller,
            port: selectedPort,
            onConnected: () => Navigator.pop(context, true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppLocalizations.of(context).sshCancel),
            ),
          ],
        ),
      ) ??
      false;
}

/// Credentials are entered once; a successful login removes the form.
class PanelLoginView extends StatefulWidget {
  const PanelLoginView({
    required this.controller,
    required this.port,
    this.onConnected,
    super.key,
  });
  final RunnerController controller;
  final int port;
  final VoidCallback? onConnected;
  @override
  State<PanelLoginView> createState() => _PanelLoginViewState();
}

class _PanelLoginViewState extends State<PanelLoginView> {
  late final TextEditingController username;
  late final TextEditingController password;
  bool revealed = false, invalid = false;

  @override
  void initState() {
    super.initState();
    final saved = widget.controller.panelAccess;
    username = TextEditingController(text: saved?.username ?? '');
    password = TextEditingController();
  }
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> connect() async {
    if (username.text.isEmpty || password.text.isEmpty) {
      setState(() => invalid = true);
      return;
    }
    final ok = await widget.controller.connectPanel(
      widget.port,
      username.text,
      password.text,
    );
    if (!mounted) return;
    if (ok) {
      password.clear();
      widget.onConnected?.call();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, l = AppLocalizations.of(context);
      if (c.panelAccess?.port == widget.port && !c.panelLoginRequired) {
        return const SizedBox.shrink();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.panelLoginOnce),
          const SizedBox(height: AppLayout.smallGap),
          TextField(
            key: const ValueKey('panel-login-username'),
            controller: username,
            enabled: !c.busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: l.panelUsername),
          ),
          const SizedBox(height: AppLayout.smallGap),
          TextField(
            key: const ValueKey('panel-login-password'),
            controller: password,
            enabled: !c.busy,
            obscureText: !revealed,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) {
              if (!c.busy) connect();
            },
            decoration: InputDecoration(
              labelText: l.componentsPassword,
              suffixIcon: IconButton(
                tooltip: revealed ? l.hidePassword : l.showPassword,
                onPressed: () => setState(() => revealed = !revealed),
                icon: Icon(revealed ? Icons.visibility_off : Icons.visibility),
              ),
            ),
          ),
          if (invalid) Text(l.panelLoginRequiredFields),
          if (c.responseCode != null && c.responseCode != 'ok')
            Text(runnerCodeLabel(l, c.responseCode!)),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton(
              key: const ValueKey('panel-login-connect'),
              onPressed: c.connected && !c.busy ? connect : null,
              child: Text(l.sshConnect),
            ),
          ),
        ],
      );
    },
  );
}
