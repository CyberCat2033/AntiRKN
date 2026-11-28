import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import 'l10n/app_localizations.dart';

class SettingsDestination {
  const SettingsDestination({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.content,
  });

  /// Stable identity: destinations may appear or disappear (sync, backup),
  /// so pages, drafts and the open page follow the id, not the position.
  final String id;
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
    this.statusDestinationId,
    this.error,
    this.initialId,
    this.onOpened,
    super.key,
  });
  final List<SettingsDestination> destinations;
  final MotionPreference motion;
  final Widget? status, error;

  /// The destination that tapping [status] opens. The status card is its
  /// only entry point, so the menu does not list it a second time.
  final String? statusDestinationId;

  /// The destination open at first; null opens the menu.
  final String? initialId;

  /// The open destination changed; null is the menu.
  final ValueChanged<String?>? onOpened;
  @override
  State<SettingsHub> createState() => SettingsHubState();
}

class SettingsHubState extends State<SettingsHub> {
  /// The open destination; null shows the menu.
  String? selectedId;
  final visited = <String>{};

  /// Position in the page switch: 0 is the menu, then the destinations.
  int get selected {
    final i = widget.destinations.indexWhere((d) => d.id == selectedId);
    return i < 0 ? 0 : i + 1;
  }

  bool get canGoBack => selected != 0;

  @override
  void initState() {
    super.initState();
    final id = widget.initialId;
    if (id != null && widget.destinations.any((d) => d.id == id)) {
      selectedId = id;
      visited.add(id);
    }
  }

  void showRoot() => open(0);
  void open(int value) {
    final id = value <= 0 || value > widget.destinations.length
        ? null
        : widget.destinations[value - 1].id;
    setState(() {
      selectedId = id;
      if (id != null) visited.add(id);
    });
    widget.onOpened?.call(id);
  }

  void openId(String id) {
    final i = widget.destinations.indexWhere((d) => d.id == id);
    if (i >= 0) open(i + 1);
  }

  @override
  void didUpdateWidget(SettingsHub oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A destination that disappeared (for example sync turned off) returns
    // to the menu instead of showing whatever moved into its position.
    if (selectedId != null &&
        !widget.destinations.any((d) => d.id == selectedId)) {
      selectedId = null;
      widget.onOpened?.call(null);
    }
  }

  Widget scroll(String id, List<Widget> children) => ListView(
    key: PageStorageKey('settings-page-$id'),
    padding: AppLayout.screenPadding(context),
    // Full width, like the other top-level pages (clients, servers, network).
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final active = AppPageVisibility.of(context);
    final selected = this.selected;
    final listed = [
      for (var i = 0; i < widget.destinations.length; i++)
        if (widget.status == null ||
            widget.destinations[i].id != widget.statusDestinationId)
          i,
    ];
    return PopScope(
      canPop: !active || selected == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && active) open(0);
      },
      child: Column(
        children: [
          AppPageHeader(
            leading: selected > 0
                ? IconButton(
                    key: const ValueKey('settings-back'),
                    tooltip: l.uiBack,
                    onPressed: () => open(0),
                    icon: const Icon(Icons.arrow_back),
                  )
                : null,
            title: Text(
              selected == 0
                  ? l.settings
                  : widget.destinations[selected - 1].title,
            ),
          ),
          Expanded(
            child: AppPageSwitch(
              index: selected,
              depth: selected == 0 ? 0 : 1,
              motion: widget.motion,
              children: [
                scroll('menu', [
                  ?widget.error,
                  if (widget.status != null)
                    AppSettingsSection(
                      title: l.uiMyData,
                      child: InkWell(
                        key: const ValueKey('settings-status'),
                        borderRadius: BorderRadius.circular(AppLayout.radius),
                        onTap: widget.statusDestinationId == null
                            ? null
                            : () => openId(widget.statusDestinationId!),
                        child: widget.status!,
                      ),
                    ),
                  AppSettingsSection(
                    title: l.uiAppSettings,
                    child: Column(
                      children: [
                        for (final (n, i) in listed.indexed) ...[
                          if (n > 0)
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
                for (final destination in widget.destinations)
                  visited.contains(destination.id)
                      ? KeyedSubtree(
                          key: ValueKey('settings-${destination.id}'),
                          child: scroll(destination.id, [destination.content]),
                        )
                      : const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
