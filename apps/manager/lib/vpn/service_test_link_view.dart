import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'connection_checks.dart';
import 'secret_link_box.dart';
import 'vpn_controller.dart';

/// "Test link" of a resource on a server in service mode; nothing outside
/// the mode.
class ServiceTestLinkButton extends StatelessWidget {
  const ServiceTestLinkButton({
    required this.controller,
    required this.target,
    super.key,
  });
  final VpnController controller;
  final ConnectionTarget target;
  @override
  Widget build(BuildContext context) {
    if (controller.serviceTestClient(target.target) == null) {
      return const SizedBox.shrink();
    }
    return TextButton.icon(
      key: ValueKey('service-test-link-${target.target}-${target.resource}'),
      onPressed: () =>
          showServiceTestLink(context, controller: controller, target: target),
      icon: const Icon(Icons.qr_code_2),
      label: Text(AppLocalizations.of(context).serviceTestLink),
    );
  }
}

Future<void> showServiceTestLink(
  BuildContext context, {
  required VpnController controller,
  required ConnectionTarget target,
}) => showAppDetails(
  context,
  title: AppLocalizations.of(context).serviceTestLink,
  children: [ServiceTestLinkView(controller: controller, target: target)],
);

/// The test client's link or config for one resource: built on the device
/// from the last readback, hidden until shown. It follows the readback, so
/// it appears once the server confirms the test client.
class ServiceTestLinkView extends StatelessWidget {
  const ServiceTestLinkView({
    required this.controller,
    required this.target,
    super.key,
  });
  final VpnController controller;
  final ConnectionTarget target;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, controller.connections]),
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final checks = controller.connections;
      final inMode = controller.serviceTestClient(target.target) != null;
      final proxy = inMode ? checks.serviceTestProxy(target) : null;
      final link = proxy == null
          ? null
          : proxyShareLink(proxy.fields, proxy.name);
      final notice = !inMode
          ? l.serviceTestLinkGone
          : proxy == null
          ? l.serviceTestLinkPending
          : link == null
          ? l.serviceTestLinkUnsupported
          : null;
      return AccessLinkView(
        help: l.serviceTestLinkHelp,
        keyPrefix: 'service-test-link',
        link: link?.text,
        hint: switch (link?.kind) {
          ShareLinkKind.vless => l.serviceTestLinkVless,
          ShareLinkKind.awg => l.serviceTestLinkAwg,
          ShareLinkKind.trustTunnel => l.serviceTestLinkTt,
          null => null,
        },
        copyLabel: link?.kind == ShareLinkKind.awg
            ? l.serviceTestCopyConfig
            : null,
        notice: notice,
      );
    },
  );
}
