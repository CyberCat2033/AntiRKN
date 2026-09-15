import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class AppLayout {
  static const compact = 600.0;
  static const expanded = 840.0;
  static const large = 1200.0;
  static const gap = 16.0;
  static const smallGap = 8.0;
  static const contentWidth = 1040.0;
  static const radius = 18.0;
  static const padding = EdgeInsets.all(24);

  static EdgeInsets screenPadding(BuildContext context) =>
      EdgeInsets.all(MediaQuery.sizeOf(context).width < compact ? 16 : 24);
}

enum MotionPreference { system, reduced, off }

abstract final class AppMotion {
  static const standard = Duration(milliseconds: 220);
  static const reduced = Duration(milliseconds: 80);
  static Duration navigationDuration(
    BuildContext context,
    MotionPreference preference,
  ) {
    final base = duration(context, preference);
    if (base != standard) return base;
    return Duration(
      milliseconds: MediaQuery.sizeOf(context).width >= AppLayout.compact
          ? 180
          : 240,
    );
  }

  static const curve = Curves.easeOutCubic;

  static Duration duration(BuildContext context, MotionPreference preference) {
    if (MediaQuery.disableAnimationsOf(context) ||
        preference == MotionPreference.off) {
      return Duration.zero;
    }
    return preference == MotionPreference.reduced ? reduced : standard;
  }
}

/// Feedback belongs to explicit additions and confirmed deletions only.
abstract final class AppHaptics {
  static void added() => _impact(HapticFeedback.lightImpact);
  static void deleted() => _impact(HapticFeedback.mediumImpact);

  static void _impact(Future<void> Function() impact) {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    unawaited(impact().catchError((Object _) {}));
  }
}

/// Keeps page state mounted while animating navigation between sections.
class AppPageSwitch extends StatefulWidget {
  const AppPageSwitch({
    required this.index,
    required this.children,
    this.depth,
    this.motion = MotionPreference.system,
    super.key,
  });
  final int index;
  final List<Widget> children;

  /// Null for peer sections; otherwise the actual navigation depth.
  final int? depth;
  final MotionPreference motion;
  @override
  State<AppPageSwitch> createState() => _AppPageSwitchState();
}

/// Hidden pages retain drafts but must not intercept Back or keyboard focus.
class AppPageVisibility extends InheritedWidget {
  const AppPageVisibility({
    required this.active,
    required super.child,
    super.key,
  });
  final bool active;
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppPageVisibility>()?.active ??
      true;
  @override
  bool updateShouldNotify(AppPageVisibility oldWidget) =>
      active != oldWidget.active;
}

class _AppPageSwitchState extends State<AppPageSwitch>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(vsync: this, value: 1)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted && previous != null) {
        setState(() => previous = null);
      }
    });
  int? previous;
  bool opening = true;
  bool hierarchical = false;

  void updateDuration() {
    animation.duration = AppMotion.navigationDuration(context, widget.motion);
    if (animation.duration == Duration.zero && animation.isAnimating) {
      animation.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateDuration();
  }

  @override
  void didUpdateWidget(AppPageSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateDuration();
    if (oldWidget.index == widget.index) return;
    hierarchical = widget.depth != null && widget.depth != oldWidget.depth;
    opening = (widget.depth ?? 0) > (oldWidget.depth ?? 0);
    // A quick Back reverses the current reveal at exactly the same position.
    final reversing = animation.isAnimating && previous == widget.index;
    final start = reversing ? 1 - animation.value : 0.0;
    previous = oldWidget.index;
    if (animation.duration == Duration.zero) {
      previous = null;
      animation.value = 1;
    } else {
      animation.forward(from: start);
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = AppPageVisibility.of(context);
    final spatial =
        hierarchical &&
        AppMotion.duration(context, widget.motion) == AppMotion.standard;
    final foreground = opening ? widget.index : previous;
    // Stable keys retain drafts when paint order changes. Each transition
    // caches its expensive page subtree instead of rebuilding it per frame.
    final layers = <Widget>[
      for (var i = 0; i < widget.children.length; i++)
        Offstage(
          key: ValueKey(i),
          offstage: i != widget.index && i != previous,
          child: AppPageVisibility(
            active: active && i == widget.index,
            child: ExcludeFocus(
              excluding: !active || i != widget.index,
              child: ExcludeSemantics(
                excluding: !active || i != widget.index,
                child: IgnorePointer(
                  ignoring: !active || i != widget.index,
                  child: TickerMode(
                    enabled: active && i == widget.index,
                    child: AnimatedBuilder(
                      animation: animation,
                      child: RepaintBoundary(child: widget.children[i]),
                      builder: (context, child) {
                        final moving = spatial && i == foreground;
                        final progress = opening
                            ? animation.value
                            : 1 - animation.value;
                        final reveal = AppMotion.curve.transform(progress);
                        final opacity = spatial
                            ? (moving ? (reveal / .45).clamp(0.0, 1.0) : 1.0)
                            : (i == widget.index
                                  ? animation.value
                                  : 1 - animation.value);
                        return Opacity(
                          opacity: opacity,
                          child: Transform.scale(
                            scale: moving ? .985 + .015 * reveal : 1,
                            alignment: Alignment.topCenter,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                moving ? AppLayout.radius * (1 - reveal) : 0,
                              ),
                              child: ColoredBox(
                                color: Theme.of(
                                  context,
                                ).scaffoldBackgroundColor,
                                child: child,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
    final top = spatial ? foreground ?? widget.index : widget.index;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < layers.length; i++)
            if (i != top) layers[i],
          layers[top],
        ],
      ),
    );
  }
}

/// Titles stay still so a second animation never competes with the page.
class AppAnimatedTitle extends StatelessWidget {
  const AppAnimatedTitle(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) =>
      Text(title, style: Theme.of(context).textTheme.headlineSmall);
}

/// Stable catalogue rows animate insertion and removal without losing gestures.
class AppAnimatedCollection extends StatefulWidget {
  const AppAnimatedCollection({
    required this.items,
    this.motion = MotionPreference.system,
    super.key,
  });
  final Map<String, Widget> items;
  final MotionPreference motion;
  @override
  State<AppAnimatedCollection> createState() => _AppAnimatedCollectionState();
}

class _AppAnimatedCollectionState extends State<AppAnimatedCollection>
    with TickerProviderStateMixin {
  final rows = <String, Widget>{};
  final animations = <String, AnimationController>{};
  @override
  void initState() {
    super.initState();
    rows.addAll(widget.items);
    for (final id in rows.keys) {
      animations[id] = AnimationController(vsync: this, value: 1);
    }
  }

  @override
  void didUpdateWidget(AppAnimatedCollection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final duration = AppMotion.duration(context, widget.motion);
    for (final entry in widget.items.entries) {
      rows[entry.key] = entry.value;
      final existing = animations[entry.key];
      if (existing == null) {
        animations[entry.key] = AnimationController(
          vsync: this,
          duration: duration,
        )..forward();
      } else {
        existing.duration = duration;
        if (existing.status == AnimationStatus.reverse) existing.forward();
      }
    }
    for (final id in rows.keys.toList()) {
      if (widget.items.containsKey(id)) continue;
      final animation = animations[id]!;
      if (animation.status == AnimationStatus.reverse) continue;
      animation.duration = duration;
      animation.reverse().then((_) {
        if (!mounted || widget.items.containsKey(id)) return;
        setState(() {
          rows.remove(id);
          animations.remove(id)?.dispose();
        });
      });
    }
  }

  @override
  void dispose() {
    for (final animation in animations.values) {
      animation.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.items.keys.toList();
    final previous = rows.keys.toList();
    for (var i = 0; i < previous.length; i++) {
      if (!widget.items.containsKey(previous[i])) {
        order.insert(i < order.length ? i : order.length, previous[i]);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in order)
          SizeTransition(
            key: ValueKey(id),
            sizeFactor: animations[id]!.drive(
              CurveTween(curve: AppMotion.curve),
            ),
            axisAlignment: -1,
            child: FadeTransition(
              opacity: animations[id]!,
              child: IgnorePointer(
                ignoring: !widget.items.containsKey(id),
                child: ExcludeSemantics(
                  excluding: !widget.items.containsKey(id),
                  child: rows[id]!,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Named settings groups with a visible boundary, without nested disclosures.
class AppSettingsSection extends StatelessWidget {
  const AppSettingsSection({
    required this.title,
    required this.child,
    super.key,
  });
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 12),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Card.filled(clipBehavior: Clip.antiAlias, child: child),
      ],
    ),
  );
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
      curve: AppMotion.curve,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}

abstract final class AppTheme {
  static ColorScheme _completeDynamicScheme(
    ColorScheme scheme,
    Brightness brightness,
  ) {
    if (scheme.surfaceContainerLowest != scheme.surfaceContainerLow &&
        scheme.surfaceContainerLow != scheme.surfaceContainerHigh) {
      return scheme;
    }
    final tones = ColorScheme.fromSeed(
      seedColor: scheme.primary,
      brightness: brightness,
    );
    return scheme.copyWith(
      surface: tones.surface,
      surfaceDim: tones.surfaceDim,
      surfaceBright: tones.surfaceBright,
      surfaceContainerLowest: tones.surfaceContainerLowest,
      surfaceContainerLow: tones.surfaceContainerLow,
      surfaceContainer: tones.surfaceContainer,
      surfaceContainerHigh: tones.surfaceContainerHigh,
      surfaceContainerHighest: tones.surfaceContainerHighest,
    );
  }

  static ThemeData create(Brightness brightness, {ColorScheme? dynamicScheme}) {
    final dark = brightness == Brightness.dark;
    final colors =
        (dynamicScheme == null
            ? null
            : _completeDynamicScheme(dynamicScheme, brightness)) ??
        ColorScheme.fromSeed(
          seedColor: const Color(0xffa85b65),
          brightness: brightness,
        ).copyWith(
          primary: Color(dark ? 0xfff7b7ba : 0xff874c53),
          onPrimary: Color(dark ? 0xff492326 : 0xffffffff),
          secondaryContainer: Color(dark ? 0xff6a4649 : 0xfff1d2d7),
          onSecondaryContainer: Color(dark ? 0xffffdade : 0xff522c34),
          surface: Color(dark ? 0xff130e0e : 0xfffff8f7),
          surfaceContainerLowest: Color(dark ? 0xff130e0e : 0xfffff8f7),
          surfaceContainerLow: Color(dark ? 0xff1d1515 : 0xfff6eceb),
          surfaceContainer: Color(dark ? 0xff251b1c : 0xfff0e2e3),
          surfaceContainerHigh: Color(dark ? 0xff2a1e1f : 0xffedddde),
          onSurface: Color(dark ? 0xfff5eded : 0xff271819),
          onSurfaceVariant: Color(dark ? 0xffcbbabb : 0xff695457),
          outline: Color(dark ? 0xffa48b8f : 0xff8c7377),
          outlineVariant: Color(dark ? 0xff493638 : 0xffddc8ca),
        );
    final typography = ThemeData(brightness: brightness).textTheme
        .apply(bodyColor: colors.onSurface, displayColor: colors.onSurface)
        .copyWith(
          headlineSmall: TextStyle(
            fontSize: 25,
            height: 1.25,
            fontWeight: FontWeight.w500,
            letterSpacing: -.6,
            color: colors.onSurface,
          ),
          titleLarge: TextStyle(
            fontSize: 19,
            height: 1.3,
            fontWeight: FontWeight.w600,
            letterSpacing: -.3,
            color: colors.onSurface,
          ),
          titleMedium: TextStyle(
            fontSize: 16,
            height: 1.35,
            fontWeight: FontWeight.w500,
            color: colors.onSurface,
          ),
          bodyMedium: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: colors.onSurfaceVariant,
          ),
          bodySmall: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: colors.onSurfaceVariant,
          ),
          labelLarge: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppLayout.radius),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      textTheme: typography,
      scaffoldBackgroundColor: colors.surfaceContainerLowest,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.outline),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        labelStyle: typography.bodyMedium,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        toolbarHeight: 68,
        titleSpacing: 20,
        titleTextStyle: typography.headlineSmall,
        iconTheme: IconThemeData(color: colors.onSurfaceVariant, size: 23),
      ),
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: colors.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: shape,
      ),
      listTileTheme: ListTileThemeData(
        enableFeedback: false,
        titleTextStyle: typography.titleMedium,
        subtitleTextStyle: typography.bodyMedium,
        iconColor: colors.onSurfaceVariant,
        minVerticalPadding: 14,
        contentPadding: const EdgeInsets.symmetric(horizontal: 17, vertical: 2),
        selectedTileColor: colors.secondaryContainer,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          textStyle: typography.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          side: BorderSide(color: colors.outline),
          textStyle: typography.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: .55),
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 76,
        backgroundColor: colors.surfaceContainer,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.secondaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? colors.onSecondaryContainer
                : colors.onSurfaceVariant,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        groupAlignment: -1,
        backgroundColor: colors.surfaceContainer,
        indicatorColor: colors.secondaryContainer,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        clipBehavior: Clip.antiAlias,
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: shape,
      ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: error ? colors.onErrorContainer : colors.primary,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: error
                    ? colors.onErrorContainer
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionHeading(title: title, action: trailing, uppercase: true),
        Card.filled(
          child: Padding(padding: const EdgeInsets.all(18), child: child),
        ),
      ],
    ),
  );
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
      borderRadius: BorderRadius.circular(AppLayout.radius),
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
            style: Theme.of(context).textTheme.titleLarge,
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

/// A compact resource card. Technical values open in a labelled detail sheet.
class ResourceTile extends StatelessWidget {
  const ResourceTile({
    required this.title,
    required this.subtitle,
    required this.details,
    required this.storageId,
    this.actions,
    this.badge,
    this.note,
    this.detailsLabel,
    super.key,
  });
  final String title, subtitle, storageId;
  final List<Widget> details;
  final Widget? actions;
  final String? badge, note, detailsLabel;
  @override
  Widget build(BuildContext context) => Card.filled(
    child: Padding(
      padding: const EdgeInsets.all(17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(subtitle),
                    ],
                  ],
                ),
              ),
              ?actions,
            ],
          ),
          if (details.isNotEmpty || badge != null || note != null) ...[
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (note != null)
                  Text(note!, style: Theme.of(context).textTheme.bodySmall),
                if (badge != null) AppBadge(label: badge!),
                if (details.isNotEmpty)
                  TextButton.icon(
                    key: ValueKey('resource-details-$storageId'),
                    onPressed: () {
                      showAppDetails(context, title: title, children: details);
                    },
                    icon: const Icon(Icons.chevron_right, size: 18),
                    label: Text(
                      detailsLabel ??
                          MaterialLocalizations.of(context).moreButtonTooltip,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
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
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    clipBehavior: Clip.antiAlias,
    borderRadius: BorderRadius.circular(AppLayout.radius),
    child: ExpansionTile(
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
      expansionAnimationStyle:
          widget.expansionAnimationStyle ??
          AnimationStyle(
            duration: AppMotion.duration(context, MotionPreference.system),
            curve: AppMotion.curve,
          ),
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
    ),
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

/// Shared elements of the approved compact dashboard design.
class AppSectionHeading extends StatelessWidget {
  const AppSectionHeading({
    required this.title,
    this.count,
    this.action,
    this.uppercase = false,
    super.key,
  });
  final String title;
  final int? count;
  final Widget? action;
  final bool uppercase;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            uppercase ? title.toUpperCase() : title,
            style: uppercase
                ? Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                  )
                : Theme.of(context).textTheme.titleLarge,
          ),
        ),
        if (count != null) AppBadge(label: '$count'),
        ?action,
      ],
    ),
  );
}

class AppBadge extends StatelessWidget {
  const AppBadge({required this.label, this.icon, super.key});
  final String label;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(9),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14), const SizedBox(width: 5)],
        Flexible(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}

class AppIconTile extends StatelessWidget {
  const AppIconTile({
    this.icon,
    this.text,
    this.size = 44,
    this.round = false,
    super.key,
  });
  final IconData? icon;
  final String? text;
  final double size;
  final bool round;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: round
          ? Theme.of(context).colorScheme.secondaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(round ? size / 2 : 15),
    ),
    child: text == null
        ? Icon(icon, color: Theme.of(context).colorScheme.primary, size: 23)
        : Text(
            text!,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
  );
}

class AppPageIntro extends StatelessWidget {
  const AppPageIntro(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    required this.title,
    required this.icon,
    this.message,
    this.action,
    super.key,
  });
  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Card.filled(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(
        children: [
          AppIconTile(icon: icon, size: 58),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(message!, textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}

class AppNotice extends StatelessWidget {
  const AppNotice({
    required this.message,
    this.error = false,
    this.icon = Icons.info_outline,
    this.action,
    super.key,
  });
  final String message;
  final bool error;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: error ? colors.errorContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                error ? Icons.error_outline : icon,
                size: 21,
                color: error ? colors.onErrorContainer : colors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: error
                            ? colors.onErrorContainer
                            : colors.onSurface,
                      ),
                    ),
                    ?action,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Form body scrolls independently while the existing action buttons stay visible.
class AppFormDialog extends StatelessWidget {
  const AppFormDialog({this.title, this.content, this.actions, super.key});
  final Widget? title, content;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight:
              (media.size.height -
                      media.viewInsets.bottom -
                      media.padding.vertical -
                      32)
                  .clamp(120.0, double.infinity),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.headlineSmall!,
                  child: title!,
                ),
              ),
            if (content != null)
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 20),
                  child: content,
                ),
              ),
            if (actions?.isNotEmpty == true)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: .5),
                    ),
                  ),
                ),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> showAppDetails(
  BuildContext context, {
  required String title,
  required List<Widget> children,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  sheetAnimationStyle: AnimationStyle(
    duration: AppMotion.duration(context, MotionPreference.system),
  ),
  builder: (context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .8,
      maxWidth: 680,
    ),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final child in children)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: child),
        ],
      ),
    ),
  ),
);

Future<T?> showAppChoice<T>(
  BuildContext context, {
  required String title,
  required T value,
  required List<(T, String)> options,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    sheetAnimationStyle: AnimationStyle(
      duration: AppMotion.duration(context, MotionPreference.system),
    ),
    builder: (context) => SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 12),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
            for (final option in options)
              ListTile(
                title: Text(option.$2),
                selected: value == option.$1,
                trailing: value == option.$1 ? const Icon(Icons.check) : null,
                onTap: () {
                  Navigator.pop(context, option.$1);
                },
              ),
          ],
        ),
      ),
    ),
  );
}

class AppActionRow extends StatelessWidget {
  const AppActionRow({required this.children, super.key});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked =
          constraints.maxWidth < 280 ||
          MediaQuery.textScalerOf(context).scale(14) > 20;
      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              children[i],
            ],
          ],
        );
      }
      return Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 9),
            Expanded(child: children[i]),
          ],
        ],
      );
    },
  );
}

class AppTwoColumn extends StatelessWidget {
  const AppTwoColumn({required this.first, required this.second, super.key});
  final Widget first, second;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < AppLayout.expanded) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 24), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          const SizedBox(width: 24),
          Expanded(child: second),
        ],
      );
    },
  );
}
