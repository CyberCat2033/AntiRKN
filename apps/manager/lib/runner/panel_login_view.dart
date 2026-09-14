import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'runner_controller.dart';
import 'runner_panel.dart';

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
  final username = TextEditingController(), password = TextEditingController();
  bool revealed = false, invalid = false;
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
