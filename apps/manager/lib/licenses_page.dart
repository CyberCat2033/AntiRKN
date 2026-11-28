import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';

/// The licenses of one component, as [LicenseRegistry] groups them.
class LicensedComponent {
  const LicensedComponent(this.name, this.licenses);
  final String name;
  final List<LicenseEntry> licenses;
}

/// Reads [LicenseRegistry] once: [first] leads, the rest sort by name.
Future<List<LicensedComponent>> loadLicensedComponents({String? first}) async {
  final byName = <String, List<LicenseEntry>>{};
  await for (final entry in LicenseRegistry.licenses) {
    for (final name in entry.packages) {
      (byName[name] ??= []).add(entry);
    }
  }
  final names = byName.keys.toList()
    ..sort((a, b) {
      if (a == first) return -1;
      if (b == first) return 1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
  return [for (final n in names) LicensedComponent(n, byName[n]!)];
}

/// Settings → About → Licenses: the app, a searchable list of components
/// and the text of the open one — beside the list on an expanded width,
/// as a nested page below it.
class LicensesPage extends StatefulWidget {
  const LicensesPage({
    required this.applicationName,
    required this.motion,
    this.applicationVersion,
    this.applicationLegalese,
    super.key,
  });
  final String applicationName;
  final String? applicationVersion, applicationLegalese;
  final MotionPreference motion;

  @override
  State<LicensesPage> createState() => _LicensesPageState();
}

class _LicensesPageState extends State<LicensesPage> {
  late final Future<List<LicensedComponent>> _components =
      loadLicensedComponents(first: widget.applicationName);
  final _search = TextEditingController();
  String _query = '';
  String? _open;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppPageHeader(
              leading: IconButton(
                tooltip: l.uiBack,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
              ),
              title: Text(l.aboutLicenses),
            ),
            Expanded(
              child: FutureBuilder(
                future: _components,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Padding(
                      padding: AppLayout.screenPadding(context),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: AppEmptyState(
                          title: l.licensesLoadFailed,
                          icon: Icons.error_outline,
                        ),
                      ),
                    );
                  }
                  final all = snapshot.data;
                  if (all == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return LayoutBuilder(
                    builder: (context, box) =>
                        _body(context, l, all, AppListDetail.fits(box)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l,
    List<LicensedComponent> all,
    bool wide,
  ) {
    final query = _query.trim().toLowerCase();
    final shown = query.isEmpty
        ? all
        : all.where((c) => c.name.toLowerCase().contains(query)).toList();
    final open = wide
        ? shown.where((c) => c.name == _open).firstOrNull ?? shown.firstOrNull
        : null;
    final list = _list(context, l, shown, open, wide);
    if (!wide) return list;
    return AppListDetail(
      motion: widget.motion,
      resizeLabel: l.uiResizePanes,
      list: list,
      detail: open == null
          ? const SizedBox.expand()
          : LicenseText(
              key: ValueKey(open.name),
              component: open,
              color: Theme.of(context).colorScheme.surfaceContainer,
            ),
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l,
    List<LicensedComponent> shown,
    LicensedComponent? open,
    bool wide,
  ) {
    final head = <Widget>[
      _AppSummary(
        name: widget.applicationName,
        version: widget.applicationVersion,
        legalese: widget.applicationLegalese,
      ),
      const SizedBox(height: AppLayout.gap),
      AppSearchField(
        key: const ValueKey('licenses-search'),
        controller: _search,
        hintText: l.licensesSearch,
        clearTooltip: l.licensesSearchClear,
        onChanged: (v) => setState(() => _query = v),
      ),
      const SizedBox(height: AppLayout.gap),
      AppSectionHeading(
        title: l.licensesComponents,
        count: shown.length,
        subheader: true,
      ),
      if (shown.isEmpty)
        AppEmptyState(
          title: l.licensesNotFound,
          message: l.licensesNotFoundHelp(_query.trim()),
          icon: Icons.search_off,
        ),
    ];
    return ListView.builder(
      padding: AppLayout.screenPadding(context),
      itemCount: head.length + shown.length,
      itemBuilder: (context, i) {
        if (i < head.length) return head[i];
        final c = shown[i - head.length];
        return _ComponentTile(
          component: c,
          selected: c == open,
          wide: wide,
          onTap: () => wide
              ? setState(() => _open = c.name)
              : pushAppPage<void>(
                  context,
                  motion: widget.motion,
                  builder: (_) => _ComponentPage(component: c),
                ),
        );
      },
    );
  }
}

/// The app's own name, version and terms above the components.
class _AppSummary extends StatelessWidget {
  const _AppSummary({required this.name, this.version, this.legalese});
  final String name;
  final String? version, legalese;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(AppLayout.gap),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppIconTile(icon: Icons.gavel_outlined),
            const SizedBox(width: AppLayout.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: theme.textTheme.titleLarge),
                  if (version != null)
                    Text(l.licensesVersion(version!), style: muted),
                  if (legalese != null) ...[
                    const SizedBox(height: AppLayout.smallGap),
                    Text(legalese!, style: theme.textTheme.bodyMedium),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A component row: its name and how many licenses it carries. On an
/// expanded width the open one is highlighted instead of a chevron.
class _ComponentTile extends StatelessWidget {
  const _ComponentTile({
    required this.component,
    required this.selected,
    required this.wide,
    required this.onTap,
  });
  final LicensedComponent component;
  final bool selected, wide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ListTile(
        key: ValueKey('license-${component.name}'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppLayout.radius),
        ),
        selected: selected,
        selectedColor: colors.onSecondaryContainer,
        selectedTileColor: colors.secondaryContainer,
        title: Text(component.name),
        subtitle: Text(l.licensesCount(component.licenses.length)),
        trailing: wide ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// A component's licenses as a nested page below an expanded width.
class _ComponentPage extends StatelessWidget {
  const _ComponentPage({required this.component});
  final LicensedComponent component;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppPageHeader(
              leading: IconButton(
                tooltip: l.uiBack,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
              ),
              title: Text(component.name),
            ),
            Expanded(child: LicenseText(component: component, showName: false)),
          ],
        ),
      ),
    );
  }
}

/// The selectable license texts of [component], one card each.
class LicenseText extends StatelessWidget {
  const LicenseText({
    required this.component,
    this.color,
    this.showName = true,
    super.key,
  });
  final LicensedComponent component;

  /// The cards' colour; the list-detail pane passes a role a step above
  /// its own surface.
  final Color? color;

  /// The nested page already names the component in its header.
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final head = showName ? 1 : 0;
    final licenses = component.licenses;
    return SelectionArea(
      child: ListView.builder(
        padding: AppLayout.screenPadding(context),
        itemCount: head + licenses.length,
        itemBuilder: (context, i) {
          if (i < head) {
            return AppSectionHeading(
              title: component.name,
              action: Text(
                l.licensesCount(licenses.length),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
            child: Card.filled(
              color: color,
              child: Padding(
                padding: const EdgeInsets.all(AppLayout.gap),
                child: _Paragraphs(licenses[i - head]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Paragraphs extends StatelessWidget {
  const _Paragraphs(this.license);
  final LicenseEntry license;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, p) in license.paragraphs.indexed)
          Padding(
            padding: EdgeInsetsDirectional.only(
              top: i == 0 ? 0 : AppLayout.smallGap,
              start: p.indent == LicenseParagraph.centeredIndent
                  ? 0
                  : AppLayout.gap * p.indent,
            ),
            child: p.indent == LicenseParagraph.centeredIndent
                ? Text(
                    p.text,
                    textAlign: TextAlign.center,
                    style: text.titleSmall,
                  )
                : Text(p.text, style: text.bodyMedium),
          ),
      ],
    );
  }
}
