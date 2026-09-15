import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import 'l10n/app_localizations.dart';

class SettingsDestination {
  const SettingsDestination({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.content,
  });
  final String title, subtitle;
  final IconData icon;
  final Widget content;
}

/// One named page per task. Drafts remain mounted when returning to the menu.
class SettingsHub extends StatefulWidget {
  const SettingsHub({
    required this.destinations,
    required this.motion,
    this.status,
    this.error,
    super.key,
  });
  final List<SettingsDestination> destinations;
  final MotionPreference motion;
  final Widget? status, error;
  @override
  State<SettingsHub> createState() => SettingsHubState();
}

class SettingsHubState extends State<SettingsHub> {
  int selected = 0;
  bool get canGoBack => selected != 0;
  void showRoot() => open(0);
  final visited = <int>{0};
  void open(int value) {
    AppHaptics.selection();
    setState(() {
      selected = value;
      visited.add(value);
    });
  }

  Widget scroll(String id, List<Widget> children) => ListView(
    key: PageStorageKey('settings-page-$id'),
    padding: AppLayout.screenPadding(context),
    children: [
      Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final active = AppPageVisibility.of(context);
    if (selected > widget.destinations.length) selected = 0;
    return PopScope(
      canPop: !active || selected == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && active) open(0);
      },
      child: Column(
        children: [
          SizedBox(
            height: 68,
            child: Row(
              children: [
                if (selected > 0)
                  IconButton(
                    tooltip: l.uiBack,
                    onPressed: () => open(0),
                    icon: const Icon(Icons.arrow_back),
                  )
                else
                  const SizedBox(width: 20),
                Expanded(
                  child: AppAnimatedTitle(
                    selected == 0
                        ? l.settings
                        : widget.destinations[selected - 1].title,
                  ),
                ),
                const SizedBox(width: 20),
              ],
            ),
          ),
          Expanded(
            child: AppPageSwitch(
              index: selected,
              motion: widget.motion,
              children: [
                scroll('menu', [
                  ?widget.error,
                  if (widget.status != null)
                    AppSettingsSection(
                      title: l.uiMyData,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppLayout.radius),
                        onTap: () {
                          final i = widget.destinations.indexWhere(
                            (d) => d.icon == Icons.sync,
                          );
                          if (i >= 0) open(i + 1);
                        },
                        child: widget.status!,
                      ),
                    ),
                  AppSettingsSection(
                    title: l.uiAppSettings,
                    child: Column(
                      children: [
                        for (
                          var i = 0;
                          i < widget.destinations.length;
                          i++
                        ) ...[
                          if (i > 0)
                            const Divider(height: 1, indent: 16, endIndent: 16),
                          ListTile(
                            key: ValueKey('settings-category-$i'),
                            leading: Icon(widget.destinations[i].icon),
                            title: Text(widget.destinations[i].title),
                            subtitle: Text(widget.destinations[i].subtitle),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => open(i + 1),
                          ),
                        ],
                      ],
                    ),
                  ),
                ]),
                for (var i = 0; i < widget.destinations.length; i++)
                  visited.contains(i + 1)
                      ? scroll('$i', [widget.destinations[i].content])
                      : const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
