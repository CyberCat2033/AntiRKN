import 'package:flutter/material.dart';

abstract final class AppLayout {
  static const compact = 600.0;
  static const expanded = 840.0;
  static const large = 1200.0;
  static const gap = 16.0;
  static const smallGap = 8.0;
  static const contentWidth = 1440.0;
  static const padding = EdgeInsets.all(24);

  static EdgeInsets screenPadding(BuildContext context) =>
      EdgeInsets.all(MediaQuery.sizeOf(context).width < compact ? 16 : 24);
}

enum MotionPreference { system, reduced, off }

abstract final class AppMotion {
  static const standard = Duration(milliseconds: 220);
  static const reduced = Duration(milliseconds: 80);

  static Duration duration(BuildContext context, MotionPreference preference) {
    if (MediaQuery.disableAnimationsOf(context) ||
        preference == MotionPreference.off) {
      return Duration.zero;
    }
    return preference == MotionPreference.reduced ? reduced : standard;
  }
}

/// Applies shared motion policy and skips size animation when it is disabled.
class AppAnimatedSize extends StatelessWidget {
  const AppAnimatedSize({required this.child, required this.motion, super.key});
  final Widget child;
  final MotionPreference motion;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.duration(context, motion);
    if (duration == Duration.zero) return child;
    return AnimatedSize(
      duration: duration,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}

abstract final class AppTheme {
  static ThemeData create(Brightness brightness, {ColorScheme? dynamicScheme}) {
    final colors =
        dynamicScheme ??
        ColorScheme.fromSeed(
          seedColor: const Color(0xff386a57),
          brightness: brightness,
        );
    final typography = ThemeData(brightness: brightness).textTheme;
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        scrolledUnderElevation: 0,
        titleTextStyle: typography.titleLarge?.copyWith(
          color: colors.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      listTileTheme: ListTileThemeData(
        titleTextStyle: typography.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        subtitleTextStyle: typography.bodyMedium,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: .5),
      ),
      navigationRailTheme: const NavigationRailThemeData(groupAlignment: -1),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({
    required this.label,
    required this.icon,
    this.error = false,
    super.key,
  });
  final String label;
  final IconData icon;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(
        icon,
        size: 18,
        color: error ? colors.onErrorContainer : colors.onSecondaryContainer,
      ),
      label: Text(label),
      backgroundColor: error
          ? colors.errorContainer
          : colors.secondaryContainer,
      labelStyle: TextStyle(
        color: error ? colors.onErrorContainer : colors.onSecondaryContainer,
      ),
      side: BorderSide.none,
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.title,
    required this.child,
    this.trailing,
    super.key,
  });
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(AppLayout.gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (trailing case final action?) ...[
                const SizedBox(width: AppLayout.smallGap),
                action,
              ],
            ],
          ),
          const SizedBox(height: AppLayout.gap),
          child,
        ],
      ),
    );
    return context.findAncestorWidgetOfExactType<SectionCard>() != null
        ? content
        : Card.filled(child: content);
  }
}

/// A shared card row; long labels and large text put actions below the summary.
class SummaryCard extends StatelessWidget {
  const SummaryCard({
    required this.title,
    required this.subtitle,
    this.leading,
    this.action,
    this.onTap,
    this.selected = false,
    super.key,
  });
  final String title;
  final Widget subtitle;
  final Widget? leading, action;
  final VoidCallback? onTap;
  final bool selected;
  @override
  Widget build(BuildContext context) => Card.filled(
    color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(AppLayout.gap),
        child: LayoutBuilder(
          builder: (context, size) {
            final stacked =
                size.maxWidth < 480 ||
                MediaQuery.textScalerOf(context).scale(14) > 21;
            final summary = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  child: subtitle,
                ),
              ],
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: AppLayout.gap),
                    ],
                    Expanded(child: summary),
                    if (!stacked && action != null) ...[
                      const SizedBox(width: AppLayout.gap),
                      action!,
                    ],
                  ],
                ),
                if (stacked && action != null)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: action!,
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

/// A section heading whose actions move below the title on narrow layouts.
class ContentSection extends StatelessWidget {
  const ContentSection({
    required this.title,
    required this.child,
    this.actions,
    super.key,
  });
  final String title;
  final Widget child;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final titleWidget = Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
          );
          if (constraints.maxWidth < 280 ||
              MediaQuery.textScalerOf(context).scale(14) > 21) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [titleWidget, ?actions],
            );
          }
          return Row(
            children: [
              Expanded(child: titleWidget),
              ?actions,
            ],
          );
        },
      ),
      const SizedBox(height: AppLayout.smallGap),
      child,
    ],
  );
}

/// One resource with a short summary and optional technical details.
class ResourceTile extends StatelessWidget {
  const ResourceTile({
    required this.title,
    required this.subtitle,
    required this.details,
    required this.storageId,
    this.actions,
    super.key,
  });
  final String title, subtitle, storageId;
  final List<Widget> details;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => Card.filled(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppExpansionTile(
          key: PageStorageKey('resource-details-$storageId'),
          maintainState: true,
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: actions,
          childrenPadding: const EdgeInsets.symmetric(
            horizontal: AppLayout.gap,
            vertical: AppLayout.smallGap,
          ),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: details,
        ),
      ],
    ),
  );
}

/// Expansion state and descendant scroll positions must use different buckets.
/// TextField and SelectableText contain scrollables even without an explicit
/// controller. Otherwise they can read the tile's bool as a double after login,
/// lazy construction or reopening a section.
class AppExpansionTile extends StatefulWidget {
  const AppExpansionTile({
    required this.title,
    this.children = const [],
    this.subtitle,
    this.leading,
    this.trailing,
    this.maintainState = false,
    this.childrenPadding,
    this.tilePadding,
    this.expandedCrossAxisAlignment,
    this.shape,
    this.collapsedShape,
    this.onExpansionChanged,
    this.expansionAnimationStyle,
    super.key,
  });
  final Widget title;
  final List<Widget> children;
  final Widget? subtitle, leading, trailing;
  final bool maintainState;
  final EdgeInsetsGeometry? childrenPadding, tilePadding;
  final CrossAxisAlignment? expandedCrossAxisAlignment;
  final ShapeBorder? shape, collapsedShape;
  final ValueChanged<bool>? onExpansionChanged;
  final AnimationStyle? expansionAnimationStyle;

  @override
  State<AppExpansionTile> createState() => _AppExpansionTileState();
}

class _AppExpansionTileState extends State<AppExpansionTile> {
  final _contents = PageStorageBucket();

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: widget.title,
    subtitle: widget.subtitle,
    leading: widget.leading,
    trailing: widget.trailing,
    maintainState: widget.maintainState,
    tilePadding: widget.tilePadding,
    childrenPadding: widget.childrenPadding,
    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
    shape: widget.shape,
    collapsedShape: widget.collapsedShape,
    onExpansionChanged: widget.onExpansionChanged,
    expansionAnimationStyle: widget.expansionAnimationStyle,
    children: [
      PageStorage(
        bucket: _contents,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              widget.expandedCrossAxisAlignment ?? CrossAxisAlignment.center,
          children: widget.children,
        ),
      ),
    ],
  );
}

/// Keeps settings and their draft state mounted while showing a short summary.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    required this.title,
    required this.child,
    this.subtitle,
    this.attention = false,
    super.key,
  });
  final String title;
  final Widget child;
  final String? subtitle;
  final bool attention;

  @override
  Widget build(BuildContext context) => AppExpansionTile(
    maintainState: true,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    leading: attention
        ? Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error)
        : null,
    children: [child],
  );
}

/// Short option sets use M3 segments; large text uses a vertical arrangement.
class AppChoice<T> extends StatelessWidget {
  const AppChoice({
    required this.value,
    required this.options,
    required this.onChanged,
    this.keyPrefix,
    super.key,
  });
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final style = Theme.of(context).textTheme.labelLarge!;
      final requiredWidth = options.fold<double>(0, (total, option) {
        final text = TextPainter(
          text: TextSpan(text: option.$2, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final width = text.width;
        text.dispose();
        return total + width + 32;
      });
      return SegmentedButton<T>(
        showSelectedIcon: false,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        direction: requiredWidth > size.maxWidth
            ? Axis.vertical
            : Axis.horizontal,
        segments: [
          for (final option in options)
            ButtonSegment<T>(
              value: option.$1,
              label: Text(
                option.$2,
                key: keyPrefix == null
                    ? null
                    : ValueKey(
                        '$keyPrefix-${option.$1 is Enum ? (option.$1 as Enum).name : option.$1}',
                      ),
              ),
            ),
        ],
        selected: {value},
        onSelectionChanged: onChanged == null
            ? null
            : (values) => onChanged!(values.single),
      );
    },
  );
}
