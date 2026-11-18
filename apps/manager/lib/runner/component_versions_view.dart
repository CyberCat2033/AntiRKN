import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'component_installation_view.dart';
import 'component_updates_controller.dart';
import 'runner_controller.dart';

/// Components whose version can be chosen.
const choosableComponents = {'panel', 'xray', 'trusttunnel', 'amneziawg'};

/// Installed by AntiRKN's own installer: a new version goes into its own
/// directory and the previous one stays; a failed start switches back.
/// AmneziaWG is built from source on the server. Stable releases only.
const installerComponents = {'trusttunnel', 'amneziawg'};

/// Version choice for one software card: newer upstream releases with marks
/// and the version that ran before the last confirmed upgrade. Older
/// versions are not offered: a version the server never ran may not read
/// the data a newer one already wrote; the previous one is restored from
/// its snapshot.
Future<void> showComponentVersions(
  BuildContext context, {
  required RunnerController controller,
  required ComponentUpdatesController updates,
  required String title,
  required Map<String, String> installed,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ComponentVersionsDialog(
    controller: controller,
    updates: updates,
    title: title,
    installed: installed,
  ),
);

class _ComponentVersionsDialog extends StatefulWidget {
  const _ComponentVersionsDialog({
    required this.controller,
    required this.updates,
    required this.title,
    required this.installed,
  });
  final RunnerController controller;
  final ComponentUpdatesController updates;
  final String title;
  final Map<String, String> installed;
  @override
  State<_ComponentVersionsDialog> createState() =>
      _ComponentVersionsDialogState();
}

class _ComponentVersionsDialogState extends State<_ComponentVersionsDialog> {
  final releases = <String, List<ComponentRelease>>{};
  var plans = <String, Map<String, dynamic>>{};
  bool loading = true, failed = false, resolving = false, assetMissing = false;

  List<String> get components => [
    for (final key in widget.installed.keys)
      if (choosableComponents.contains(key)) key,
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      for (final component in components) {
        releases[component] = await widget.updates.source.releases(component);
      }
      plans = await widget.controller.componentVersionPlans(components);
      failed = plans.length != components.length;
    } catch (_) {
      failed = true;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _choose(String component, String version, bool restore) async {
    final l = AppLocalizations.of(context);
    final from = widget.installed[component]!;
    final snapshot = plans[component]?['snapshot'] as Map?;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          restore
              ? l.versionsRestoreTitle(componentName(component), version)
              : l.versionsInstallTitle(componentName(component), version),
        ),
        content: Text(
          [
            l.versionsChange(from, version),
            if (component == 'panel' && !restore) l.versionsPanelCarriesXray,
            if (component == 'panel' &&
                restore &&
                snapshot?['xrayVersion'] != null)
              l.versionsPanelRestoresXray(snapshot!['xrayVersion'] as String),
            if (component == 'amneziawg') l.versionsAwgBuild,
            installerComponents.contains(component)
                ? l.versionsSafetyInstaller
                : l.versionsSafety,
          ].join('\n\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.runnerNotNow),
          ),
          FilledButton(
            key: const ValueKey('component-version-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(restore ? l.versionsRestore : l.versionsInstall),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    final arch = plans[component]?['arch'] as String?;
    Map<String, Object?>? candidate;
    if (restore) {
      candidate = {
        'component': component,
        'version': version,
        'architecture': arch ?? 'x86_64',
        'source': 'snapshot',
      };
    } else {
      setState(() {
        resolving = true;
        assetMissing = false;
      });
      try {
        candidate = installerComponents.contains(component)
            ? await widget.updates.source.resolveInstallerRelease(
                component: component,
                version: version,
              )
            : await widget.updates.source.resolveAsset(
                component: component,
                version: version,
                architecture: arch,
              );
      } catch (_) {
        candidate = null;
      }
      if (!mounted) return;
      setState(() {
        resolving = false;
        assetMissing = candidate == null;
      });
    }
    if (candidate == null) return;
    final chosen = candidate;
    Navigator.pop(context);
    final c = widget.controller;
    await c.requestAction(() async {
      if (installerComponents.contains(component)) {
        await c.prepareComponent(component, choice: chosen);
        await c.applyComponent();
      } else {
        await c.installComponentVersion(chosen);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final children = <Widget>[];
    if (loading) {
      children.addAll([
        const LinearProgressIndicator(),
        const SizedBox(height: 12),
        Text(l.versionsLoading),
      ]);
    } else if (failed) {
      children.addAll([
        AppNotice(message: l.versionsFailed),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(l.uiCheck),
          ),
        ),
      ]);
    } else {
      children.add(
        Text(
          components.every(installerComponents.contains)
              ? l.versionsHelpInstaller
              : l.versionsHelp,
          style: theme.textTheme.bodySmall,
        ),
      );
      if (resolving) {
        children.addAll([
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ]);
      }
      if (assetMissing) {
        children.addAll([
          const SizedBox(height: 12),
          AppNotice(message: l.versionsAssetMissing),
        ]);
      }
      for (final component in components) {
        final current = widget.installed[component]!;
        final verified = verifiedComponentVersions[component];
        final newer = [
          for (final r in releases[component] ?? const <ComponentRelease>[])
            if (componentIsNewer(r.version, current, allowPreview: true) ==
                    true &&
                !(r.preview && installerComponents.contains(component)))
              r,
        ].take(8).toList();
        final snapshot = plans[component]?['snapshot'] as Map?;
        final previous = snapshot?['version'] as String?;
        children.addAll([
          const SizedBox(height: 16),
          Text(
            '${componentName(component)} · ${l.versionsInstalled(current)}',
            style: theme.textTheme.titleSmall,
          ),
          if (newer.isEmpty && (previous == null || previous == current))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(l.versionsNothing, style: theme.textTheme.bodySmall),
            ),
          for (final r in newer)
            _row(
              key: 'component-version-$component-${r.version}',
              version: r.version,
              marks: [
                r.version == verified
                    ? l.versionsVerified
                    : l.versionsUnverified,
                if (r.preview) l.versionsPreview,
                if (r.published case final date?)
                  MaterialLocalizations.of(
                    context,
                  ).formatShortDate(date.toLocal()),
              ],
              action: l.versionsInstall,
              onPressed: () => _choose(component, r.version, false),
            ),
          if (previous != null && previous != current)
            _row(
              key: 'component-version-$component-restore',
              version: previous,
              marks: [
                l.versionsPrevious,
                if (component == 'panel' && snapshot?['xrayVersion'] != null)
                  'Xray ${snapshot!['xrayVersion']}',
              ],
              action: l.versionsRestore,
              onPressed: () => _choose(component, previous, true),
            ),
        ]);
      }
    }
    return AppFormDialog(
      title: Text(l.versionsTitle(widget.title)),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }

  Widget _row({
    required String key,
    required String version,
    required List<String> marks,
    required String action,
    required VoidCallback onPressed,
  }) => ListTile(
    key: ValueKey(key),
    contentPadding: EdgeInsets.zero,
    title: Text(version),
    subtitle: Text(marks.join(' · ')),
    trailing: OutlinedButton(
      onPressed: resolving || !widget.controller.canRequestAction
          ? null
          : onPressed,
      child: Text(action),
    ),
  );
}
