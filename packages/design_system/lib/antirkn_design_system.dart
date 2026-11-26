import 'dart:async';
import 'package:animations/animations.dart';
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

/// Material container transform: the tapped surface becomes the details page.
class AppOpenContainer extends StatelessWidget {
  const AppOpenContainer({
    required this.closedBuilder,
    required this.openBuilder,
    this.onClosed,
    this.motion = MotionPreference.system,
    super.key,
  });
  final Widget Function(BuildContext, VoidCallback) closedBuilder;
  final Widget Function(BuildContext, VoidCallback) openBuilder;
  final VoidCallback? onClosed;
  final MotionPreference motion;
  @override
  Widget build(BuildContext context) => OpenContainer<void>(
    tappable: false,
    closedElevation: 0,
    openElevation: 0,
    closedColor: Theme.of(context).colorScheme.surfaceContainerLow,
    openColor: Theme.of(context).scaffoldBackgroundColor,
    closedShape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppLayout.radius),
    ),
    transitionType: ContainerTransitionType.fadeThrough,
    transitionDuration:
        AppMotion.duration(context, motion) == AppMotion.standard
        ? const Duration(milliseconds: 300)
        : AppMotion.duration(context, motion),
    closedBuilder: closedBuilder,
    openBuilder: (context, close) => openBuilder(context, () => close()),
    onClosed: (_) => onClosed?.call(),
  );
}

/// Deliberate edit-mode entry, additions and confirmed deletions.
abstract final class AppHaptics {
  static const _channel = MethodChannel('org.antirkn/haptics');
  static void selection() => _selection('press', HapticFeedback.selectionClick);
  static void dragStart() =>
      _selection('dragStart', HapticFeedback.heavyImpact);
  static void dragTick() =>
      _selection('dragTick', HapticFeedback.selectionClick);

  static void _selection(String kind, Future<void> Function() fallback) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      _impact(fallback);
      return;
    }
    unawaited(
      _channel.invokeMethod<void>(kind).catchError((Object _) {
        _impact(fallback);
      }),
    );
  }

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
    with TickerProviderStateMixin {
  final primaryAnimations = <AnimationController>[];
  final secondaryAnimations = <AnimationController>[];

  /// The transition wrapping a page changes type (shared axis or fade
  /// through) with the kind of navigation and with reduced motion. A global
  /// key moves the page subtree into the new wrapper instead of remounting
  /// it, so drafts, scroll positions and focus survive every transition.
  /// A child with its own key keeps its page even when its position changes.
  final pageKeys = <GlobalKey>[];
  final keyedPages = <Key, GlobalKey>{};
  GlobalKey pageKey(int i) {
    final key = widget.children[i].key;
    if (key == null) return pageKeys[i];
    return keyedPages.putIfAbsent(
      key,
      () => GlobalKey(debugLabel: 'AppPageSwitch page $key'),
    );
  }

  void ensureAnimations() {
    while (primaryAnimations.length < widget.children.length) {
      primaryAnimations.add(AnimationController(vsync: this, value: 1));
      secondaryAnimations.add(AnimationController(vsync: this));
    }
    while (pageKeys.length < widget.children.length) {
      pageKeys.add(GlobalKey(debugLabel: 'AppPageSwitch page'));
    }
  }

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
    ensureAnimations();
    animation.duration = AppMotion.navigationDuration(context, widget.motion);
    for (final controller in [...primaryAnimations, ...secondaryAnimations]) {
      controller.duration = animation.duration;
    }
    if (animation.duration == Duration.zero) {
      for (final controller in primaryAnimations) {
        controller.value = 1;
      }
      for (final controller in secondaryAnimations) {
        controller.value = 0;
      }
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
    // Pages can disappear (a settings destination turned off): never animate
    // from or keep painting a page that no longer exists.
    if (previous != null && previous! >= widget.children.length) {
      previous = null;
    }
    if (oldWidget.index == widget.index) return;
    if (oldWidget.index >= widget.children.length) {
      previous = null;
      primaryAnimations[widget.index].value = 1;
      secondaryAnimations[widget.index].value = 0;
      animation.value = 1;
      return;
    }
    hierarchical = widget.depth != null && widget.depth != oldWidget.depth;
    opening = (widget.depth ?? 0) > (oldWidget.depth ?? 0);
    // A quick Back reverses the current reveal at exactly the same position.
    final reversing = animation.isAnimating && previous == widget.index;
    final start = reversing ? 1 - animation.value : 0.0;
    previous = oldWidget.index;
    final incoming = widget.index, outgoing = oldWidget.index;
    if (!hierarchical && reversing) {
      primaryAnimations[incoming].forward();
      secondaryAnimations[incoming].reverse();
      primaryAnimations[outgoing].reverse();
      secondaryAnimations[outgoing].forward();
    } else if (opening || !hierarchical) {
      if (!reversing) {
        primaryAnimations[incoming].value = 0;
        secondaryAnimations[incoming].value = 0;
        primaryAnimations[outgoing].value = 1;
        secondaryAnimations[outgoing].value = 0;
      }
      primaryAnimations[incoming].forward();
      secondaryAnimations[outgoing].forward();
    } else {
      if (!reversing) {
        primaryAnimations[outgoing].value = 1;
        secondaryAnimations[outgoing].value = 0;
        primaryAnimations[incoming].value = 1;
        secondaryAnimations[incoming].value = 1;
      }
      primaryAnimations[outgoing].reverse();
      secondaryAnimations[incoming].reverse();
    }
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
    for (final controller in [...primaryAnimations, ...secondaryAnimations]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = AppPageVisibility.of(context);
    final spatial =
        hierarchical &&
        AppMotion.duration(context, widget.motion) == AppMotion.standard;
    final foreground = opening ? widget.index : previous;
    final fill = Theme.of(context).scaffoldBackgroundColor;
    Widget page(int i) =>
        RepaintBoundary(key: pageKey(i), child: widget.children[i]);
    // Stable keys retain drafts when paint order changes.
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
                    // The transitions listen to their own animations; the
                    // page subtree itself is not rebuilt per frame.
                    child: spatial
                        ? SharedAxisTransition(
                            animation: primaryAnimations[i],
                            secondaryAnimation: secondaryAnimations[i],
                            transitionType: SharedAxisTransitionType.scaled,
                            fillColor: fill,
                            child: page(i),
                          )
                        : FadeThroughTransition(
                            animation: primaryAnimations[i],
                            secondaryAnimation: secondaryAnimations[i],
                            fillColor: fill,
                            child: page(i),
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

/// A page's own title row: inside the content beside the navigation, with
/// the same height, inset and type on every page. The title is a heading for
/// screen readers; it belongs to its page and never animates apart from it
/// (UI-73, UI-74). [leading] is usually a back button; [actions] sit at the
/// end like app bar actions.
class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    required this.title,
    this.leading,
    this.actions = const [],
    super.key,
  });
  final Widget title;
  final Widget? leading;
  final List<Widget> actions;

  /// Icon buttons keep their glyphs on the same 20 dp inset as a bare title.
  static const double _inset = 20, _buttonInset = 8, height = 68;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    // A minimum, not a fixed height: enlarged text grows the row.
    constraints: const BoxConstraints(minHeight: height),
    child: Padding(
      padding: EdgeInsetsDirectional.only(
        start: leading == null ? _inset : _buttonInset,
        end: actions.isEmpty ? _inset : _buttonInset,
      ),
      child: Row(
        children: [
          ?leading,
          Expanded(
            child: Semantics(
              header: true,
              child: DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.headlineSmall,
                child: title,
              ),
            ),
          ),
          ...actions,
        ],
      ),
    ),
  );
}

/// Stable catalogue rows animate insertion and removal without losing gestures.
class AppAnimatedCollection extends StatefulWidget {
  const AppAnimatedCollection({
    required this.items,
    this.motion = MotionPreference.system,
    super.key,
  }) : sliver = false;

  /// The lazy form for long lists inside a [CustomScrollView]: a sliver on a
  /// filled card surface whose rows are built only as they scroll into view,
  /// with the same insertion and removal motion (UI-31).
  const AppAnimatedCollection.sliver({
    required this.items,
    this.motion = MotionPreference.system,
    super.key,
  }) : sliver = true;
  final Map<String, Widget> items;
  final MotionPreference motion;
  final bool sliver;
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
    Widget row(String id, {Key? key}) => SizeTransition(
      key: key,
      sizeFactor: animations[id]!.drive(CurveTween(curve: AppMotion.curve)),
      axisAlignment: -1,
      child: FadeTransition(
        opacity: animations[id]!,
        child: IgnorePointer(
          ignoring: !widget.items.containsKey(id),
          child: ExcludeSemantics(
            excluding: !widget.items.containsKey(id),
            child: RepaintBoundary(child: rows[id]!),
          ),
        ),
      ),
    );
    if (!widget.sliver) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final id in order) row(id, key: ValueKey(id))],
      );
    }
    final card = Theme.of(context).cardTheme;
    final shape =
        card.shape ??
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppLayout.radius)),
        );
    // The rows' clip follows the card's own corners.
    final radius = shape is RoundedRectangleBorder
        ? shape.borderRadius.resolve(Directionality.of(context)).topLeft
        : const Radius.circular(AppLayout.radius);
    final index = {for (var i = 0; i < order.length; i++) order[i]: i};
    return DecoratedSliver(
      decoration: ShapeDecoration(
        color: card.color ?? Theme.of(context).colorScheme.surfaceContainerLow,
        shape: shape,
      ),
      sliver: SliverList.builder(
        itemCount: order.length,
        findChildIndexCallback: (key) =>
            key is ValueKey<String> ? index[key.value] : null,
        // A sliver is not clipped by its card: the first and last rows follow
        // its corners so ink and selection stay inside (one widget type for
        // every row keeps their state when the ends change).
        itemBuilder: (context, i) => ClipRRect(
          key: ValueKey(order[i]),
          borderRadius: BorderRadius.vertical(
            top: i == 0 ? radius : Radius.zero,
            bottom: i == order.length - 1 ? radius : Radius.zero,
          ),
          clipBehavior: i == 0 || i == order.length - 1
              ? Clip.antiAlias
              : Clip.none,
          child: row(order[i]),
        ),
      ),
    );
  }
}

/// Named settings groups with a visible boundary, without nested disclosures.
class AppSettingsSection extends StatelessWidget {
  const AppSettingsSection({
    this.title,
    required this.child,
    this.count,
    this.action,
    super.key,
  });

  /// Null when the section is the page's only one: the page title already
  /// names it.
  final String? title;
  final Widget child;

  /// Shown beside [title], as in [AppSectionHeading].
  final int? count;
  final Widget? action;
  @override
  Widget build(BuildContext context) => _CardSection(
    heading: title == null
        ? null
        : AppSectionHeading(
            title: title!,
            subheader: true,
            count: count,
            action: action,
          ),
    child: child,
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

  /// Themes already built, by brightness and dynamic scheme. ThemeData holds
  /// closures without value equality: a new instance on every app rebuild
  /// (language, settings error, dynamic color) made MaterialApp animate the
  /// whole theme each time.
  static final _themes = <(Brightness, ColorScheme?), ThemeData>{};

  static ThemeData create(Brightness brightness, {ColorScheme? dynamicScheme}) {
    final key = (brightness, dynamicScheme);
    final cached = _themes[key];
    if (cached != null) return cached;
    // Dynamic color changes rarely; keep the cache from growing without end.
    if (_themes.length >= 8) _themes.clear();
    return _themes[key] = _create(brightness, dynamicScheme: dynamicScheme);
  }

  static ThemeData _create(
    Brightness brightness, {
    ColorScheme? dynamicScheme,
  }) {
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
    // The M3 type scale: sizes, line heights and tracking stay the
    // baseline's; only a few weights change. Body text is onSurface; a
    // secondary colour is set where text is secondary (UI-56).
    // ThemeData.textTheme carries no sizes until Theme.of localizes it; the
    // component themes below read [typography] directly, so it is merged
    // with the M3 (2021) geometry here.
    final base = Typography.englishLike2021
        .merge(ThemeData(brightness: brightness).textTheme)
        .apply(bodyColor: colors.onSurface, displayColor: colors.onSurface);
    final typography = base.copyWith(
      headlineSmall: base.headlineSmall?.copyWith(fontWeight: FontWeight.w500),
      titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w500),
      bodySmall: base.bodySmall?.copyWith(color: colors.onSurfaceVariant),
      labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
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
        subtitleTextStyle: typography.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
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
          (states) => typography.labelMedium?.copyWith(
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

/// A status with its icon; the same pill as [AppBadge] (UI-53).
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
  Widget build(BuildContext context) =>
      AppBadge(label: label, icon: icon, error: error);
}

/// A titled card with padded content. Shares its layout with
/// [AppSettingsSection], which holds edge-to-edge rows (UI-53).
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.title,
    required this.child,
    this.trailing,
    this.subheader = false,
    super.key,
  });
  final String title;
  final Widget child;
  final Widget? trailing;

  /// A list-style subheader instead of a page-level section title.
  final bool subheader;
  @override
  Widget build(BuildContext context) => _CardSection(
    heading: AppSectionHeading(
      title: title,
      action: trailing,
      subheader: subheader,
    ),
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
}

class _CardSection extends StatelessWidget {
  const _CardSection({required this.heading, required this.child});
  final Widget? heading;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?heading,
        Card.filled(clipBehavior: Clip.antiAlias, child: child),
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
    this.embedded = false,
    super.key,
  });
  final String title;
  final Widget subtitle;
  final Widget? leading, action;
  final VoidCallback? onTap;
  final bool selected;

  /// A row inside a section card: no card of its own, so there is no card
  /// in a card (UI-58).
  final bool embedded;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (embedded) {
      return Material(
        color: selected ? colors.secondaryContainer : Colors.transparent,
        child: _content(context),
      );
    }
    return Card.filled(
      color: selected ? colors.secondaryContainer : null,
      clipBehavior: Clip.antiAlias,
      child: _content(context),
    );
  }

  Widget _content(BuildContext context) => InkWell(
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
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
  );
}

/// A compact resource card. Technical values open in a labelled detail sheet.
class ResourceTile extends StatelessWidget {
  const ResourceTile({
    required this.title,
    required this.subtitle,
    required this.storageId,
    this.details = const [],
    this.tags = const [],
    this.actions,
    this.footer,
    this.badge,
    this.note,
    this.detailsLabel,
    this.onBadgeTap,
    this.badgeBusy = false,
    this.switchValue,
    this.selected = false,
    this.selecting = false,
    this.onTap,
    super.key,
  });
  final String title, subtitle, storageId;
  final List<Widget> details;

  /// Short states under the subtitle, e.g. [AppBadge]s of a resource class.
  final List<Widget> tags;
  final Widget? actions, footer;
  final String? badge, note, detailsLabel;
  final VoidCallback? onBadgeTap;
  final bool badgeBusy;

  /// When set, [badge] labels a switch with this value and [onBadgeTap]
  /// flips it: a state is shown as a switch, not as a button that reads
  /// like its state (UI-59).
  final bool? switchValue;

  /// Selection is drawn by the card itself, with its ripple on top: a
  /// highlight under the opaque card was invisible (UI-58).
  final bool selected;

  /// In selection mode the whole card toggles; its own controls do not
  /// take the tap.
  final bool selecting;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Card.filled(
    color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
    child: InkWell(
      onTap: onTap,
      child: AbsorbPointer(absorbing: selecting, child: _body(context)),
    ),
  );

  Widget _body(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppLayout.gap),
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
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: AppLayout.smallGap),
                    Wrap(spacing: 8, runSpacing: 4, children: tags),
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
              if (badge != null)
                switchValue != null
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            badge!,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(width: AppLayout.smallGap),
                          if (badgeBusy)
                            const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Switch(
                              key: ValueKey('resource-switch-$storageId'),
                              value: switchValue!,
                              onChanged: onBadgeTap == null
                                  ? null
                                  : (_) => onBadgeTap!(),
                            ),
                        ],
                      )
                    : onBadgeTap == null && !badgeBusy
                    ? AppBadge(label: badge!)
                    : FilledButton.tonal(
                        onPressed: badgeBusy ? null : onBadgeTap,
                        child: badgeBusy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(badge!),
                      ),
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
        ?footer,
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
      childrenPadding:
          widget.childrenPadding ?? const EdgeInsets.fromLTRB(0, 12, 0, 16),
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
    this.subheader = false,
    super.key,
  });
  final String title;
  final int? count;
  final Widget? action;

  /// The M3 list subheader (titleSmall in primary, sentence case) instead of
  /// a section title. One style for every subheader; no upper case (UI-53).
  final bool subheader;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: subheader
                ? Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
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

/// A small non-interactive label: a count, a state, a status with icon.
class AppBadge extends StatelessWidget {
  const AppBadge({
    required this.label,
    this.icon,
    this.error = false,
    super.key,
  });
  final String label;
  final IconData? icon;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = error
        ? colors.onErrorContainer
        : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 16,
              color: error ? colors.onErrorContainer : colors.primary,
            ),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
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
    // Introductory, supporting text: the secondary role (UI-56).
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
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
            Text(
              message!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
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
    this.title,
    this.error = false,
    this.icon = Icons.info_outline,
    this.action,
    this.margin = const EdgeInsets.only(bottom: 12),
    bool? liveRegion,
    super.key,
  }) : liveRegion = liveRegion ?? error;
  final String message;

  /// Optional heading above [message], for notices that recommend an action.
  final String? title;
  final bool error;
  final IconData icon;
  final Widget? action;

  /// Space around the notice; inline notices in rows and dialogs pass zero.
  final EdgeInsetsGeometry margin;

  /// Announces the message when it appears. On by default for errors, so a
  /// failure is not only a colour change.
  final bool liveRegion;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: margin,
      child: Semantics(
        container: true,
        liveRegion: liveRegion,
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
                      if (title case final title?)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: error
                                      ? colors.onErrorContainer
                                      : colors.onSurface,
                                ),
                          ),
                        ),
                      Text(
                        message,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: error
                              ? colors.onErrorContainer
                              : colors.onSurface,
                        ),
                      ),
                      if (action case final action?)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: action,
                        ),
                    ],
                  ),
                ),
              ],
            ),
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
                // The title names the dialog route for screen readers, as in
                // AlertDialog (UI-73).
                child: Semantics(
                  container: true,
                  header: true,
                  namesRoute: true,
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.headlineSmall!,
                    child: title!,
                  ),
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

/// The body of a form: one gap between every field, section, action and
/// hint, so supporting text never touches the next field's floating label.
/// An [AppFormHint] sits closer to the field it belongs to, as M3 supporting
/// text does.
class AppFormFields extends StatelessWidget {
  const AppFormFields({required this.children, super.key});
  final List<Widget> children;

  static const double hintGap = 4;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0)
          SizedBox(
            height: children[i] is AppFormHint
                ? hintGap
                // Switch rows carry their own padding, like list rows.
                : children[i] is AppFormSwitch &&
                      children[i - 1] is AppFormSwitch
                ? 0
                : AppLayout.gap,
          ),
        children[i],
      ],
    ],
  );
}

/// A named group of form fields on a tonal surface: forms read as a few
/// groups, not one flat wall of fields. With [expandable] the group stays
/// closed under its title (e.g. "Advanced settings") and keeps its draft.
class AppFormSection extends StatelessWidget {
  const AppFormSection({
    required this.children,
    this.title,
    this.expandable = false,
    super.key,
  }) : assert(!expandable || title != null);
  final String? title;
  final List<Widget> children;
  final bool expandable;

  @override
  Widget build(BuildContext context) {
    final surface = Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppLayout.radius),
      clipBehavior: Clip.antiAlias,
      child: expandable
          ? AppExpansionTile(
              maintainState: true,
              title: Text(title!),
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              shape: const RoundedRectangleBorder(),
              collapsedShape: const RoundedRectangleBorder(),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              children: [AppFormFields(children: children)],
            )
          : Padding(
              padding: const EdgeInsets.all(12),
              child: AppFormFields(children: children),
            ),
    );
    if (expandable || title == null) return surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, AppLayout.smallGap),
          child: Text(
            title!,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        surface,
      ],
    );
  }
}

/// Short supporting text under a field or form action; it never repeats
/// what the form already shows.
class AppFormHint extends StatelessWidget {
  const AppFormHint(this.text, {this.error = false, super.key});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: error
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// A secondary action inside a form (scan, regenerate, issue): one tonal
/// button at the start of the row, as wide as its label.
class AppFormAction extends StatelessWidget {
  const AppFormAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.tooltip,
    this.buttonKey,
    super.key,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// Work started by the action runs: a progress ring replaces the icon.
  final bool busy;
  final String? tooltip;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    Widget button = FilledButton.tonalIcon(
      key: buttonKey,
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon),
      label: Text(label),
    );
    if (tooltip case final message?) {
      button = Tooltip(message: message, child: button);
    }
    return Align(alignment: AlignmentDirectional.centerStart, child: button);
  }
}

/// An on/off setting inside a form section. Its text lines up with the text
/// of the fields above, and its ink keeps the field shape.
class AppFormSwitch extends StatelessWidget {
  const AppFormSwitch({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.secondary,
    this.switchKey,
    super.key,
  });
  final String title;
  final String? subtitle;
  final Widget? secondary;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? switchKey;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: switchKey,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    secondary: secondary,
    value: value,
    onChanged: onChanged,
  );
}

/// A "more" (⋮) button with a menu of actions, reachable by mouse, touch
/// and keyboard: the button owns the focus node the menu needs to move focus
/// into its items with the arrow keys.
class AppMoreMenu extends StatefulWidget {
  const AppMoreMenu({
    required this.tooltip,
    required this.children,
    this.buttonKey,
    super.key,
  });
  final String tooltip;
  final List<Widget> children;
  final Key? buttonKey;
  @override
  State<AppMoreMenu> createState() => _AppMoreMenuState();
}

class _AppMoreMenuState extends State<AppMoreMenu> {
  final _focus = FocusNode(debugLabel: 'AppMoreMenu');
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    childFocusNode: _focus,
    menuChildren: widget.children,
    builder: (context, menu, _) => IconButton(
      key: widget.buttonKey,
      focusNode: _focus,
      tooltip: widget.tooltip,
      onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      icon: const Icon(Icons.more_vert),
    ),
  );
}

/// Says why a control is unavailable: a tooltip present only while [reason]
/// is set, so an enabled control keeps its own tooltip and semantics. The
/// control keeps its state (e.g. a switch mid-animation) when the reason
/// comes and goes.
class AppDisabledReason extends StatefulWidget {
  const AppDisabledReason({
    required this.reason,
    required this.child,
    super.key,
  });
  final String? reason;
  final Widget child;
  @override
  State<AppDisabledReason> createState() => _AppDisabledReasonState();
}

class _AppDisabledReasonState extends State<AppDisabledReason> {
  final _child = GlobalKey();
  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _child, child: widget.child);
    return switch (widget.reason) {
      final reason? => Tooltip(message: reason, child: child),
      null => child,
    };
  }
}

/// The confirming action of a destructive choice (reset, delete, remove):
/// a filled button in the error colours of the scheme.
class AppDangerButton extends StatelessWidget {
  const AppDangerButton({
    required this.onPressed,
    required this.child,
    this.icon,
    super.key,
  }) : _text = false;

  /// The low-emphasis entry to a destructive action, e.g. "Delete" beside
  /// "Save" in a form: error-coloured text that opens [confirmAppDanger].
  const AppDangerButton.text({
    required this.onPressed,
    required this.child,
    this.icon,
    super.key,
  }) : _text = true;
  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final bool _text;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_text) {
      final style = TextButton.styleFrom(foregroundColor: colors.error);
      return icon == null
          ? TextButton(onPressed: onPressed, style: style, child: child)
          : TextButton.icon(
              onPressed: onPressed,
              style: style,
              icon: icon!,
              label: child,
            );
    }
    final style = FilledButton.styleFrom(
      backgroundColor: colors.error,
      foregroundColor: colors.onError,
    );
    return icon == null
        ? FilledButton(onPressed: onPressed, style: style, child: child)
        : FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: icon!,
            label: child,
          );
  }
}

/// Asks before a destructive action. Resolves to true only when the person
/// chose [confirmLabel]; dismissing the dialog counts as "no".
Future<bool> confirmAppDanger(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  required String confirmLabel,
  required String cancelLabel,
  Key? confirmKey,
}) async {
  return _confirmApp(
    context,
    title: title,
    message: message,
    content: content,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
    confirmKey: confirmKey,
    danger: true,
  );
}

/// Asks before a consequential but reversible action (a mode, an install):
/// the same dialog as [confirmAppDanger] with a filled confirming button in
/// the primary colours. Resolves to true only when the person chose
/// [confirmLabel].
Future<bool> confirmAppAction(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  required String confirmLabel,
  required String cancelLabel,
  Key? confirmKey,
}) => _confirmApp(
  context,
  title: title,
  message: message,
  content: content,
  confirmLabel: confirmLabel,
  cancelLabel: cancelLabel,
  confirmKey: confirmKey,
  danger: false,
);

Future<bool> _confirmApp(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  required String confirmLabel,
  required String cancelLabel,
  Key? confirmKey,
  required bool danger,
}) async {
  assert((message == null) != (content == null), 'message or content');
  return await showDialog<bool>(
        context: context,
        builder: (context) {
          void confirm() => Navigator.pop(context, true);
          return AppFormDialog(
            title: Text(title),
            content: content ?? Text(message!),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(cancelLabel),
              ),
              danger
                  ? AppDangerButton(
                      key: confirmKey,
                      onPressed: confirm,
                      child: Text(confirmLabel),
                    )
                  : FilledButton(
                      key: confirmKey,
                      onPressed: confirm,
                      child: Text(confirmLabel),
                    ),
            ],
          );
        },
      ) ??
      false;
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

/// [message] explains the choice; [descriptions] add a line under options.
Future<T?> showAppChoice<T>(
  BuildContext context, {
  required String title,
  required T value,
  required List<(T, String)> options,
  String? message,
  Map<T, String> descriptions = const {},
  MotionPreference motion = MotionPreference.system,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    sheetAnimationStyle: AnimationStyle(
      duration: AppMotion.duration(context, motion),
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
            if (message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final option in options)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ListTile(
                  key: ValueKey('app-choice-${option.$1}'),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  title: Text(option.$2),
                  subtitle: descriptions[option.$1] == null
                      ? null
                      : Text(descriptions[option.$1]!),
                  selected: value == option.$1,
                  trailing: value == option.$1 ? const Icon(Icons.check) : null,
                  onTap: () {
                    Navigator.pop(context, option.$1);
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Form selections share the rounded choice sheet used by settings.
class AppSelectField<T> extends StatelessWidget {
  const AppSelectField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.motion = MotionPreference.system,
    super.key,
  });
  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  final MotionPreference motion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final border = theme.inputDecorationTheme.border;
    final radius = border is OutlineInputBorder
        ? border.borderRadius
        : BorderRadius.circular(12);
    return Semantics(
      button: true,
      enabled: onChanged != null,
      child: Material(
        color: theme.inputDecorationTheme.fillColor ?? Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onChanged == null
              ? null
              : () async {
                  FocusScope.of(context).unfocus();
                  final selected = await showAppChoice<T>(
                    context,
                    title: label,
                    value: value,
                    options: options,
                    motion: motion,
                  );
                  if (context.mounted && selected != null) {
                    onChanged?.call(selected);
                  }
                },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              filled: false,
              enabled: onChanged != null,
              suffixIcon: const Icon(Icons.expand_more),
            ),
            child: Text(
              options.where((option) => option.$1 == value).firstOrNull?.$2 ??
                  value?.toString() ??
                  '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                // The M3 disabled role: onSurface at 38 % (UI-68).
                color: onChanged == null
                    ? theme.colorScheme.onSurface.withValues(alpha: .38)
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How loud an [AppStatusBanner] is.
enum AppStatusTone {
  /// Work runs by itself; nothing is asked of the person.
  progress,

  /// Work waits for the person.
  attention,

  /// Work failed and waits for the person.
  error,
}

/// One-line summary of background work above a list. It appears only while
/// there is something to report and carries at most a couple of actions;
/// the details open from [onTap].
class AppStatusBanner extends StatelessWidget {
  const AppStatusBanner({
    required this.title,
    this.message,
    this.tone = AppStatusTone.progress,
    this.icon,
    this.actions = const [],
    this.progress,
    this.onTap,
    this.tooltip,
    super.key,
  });
  final String title;
  final String? message;
  final AppStatusTone tone;
  final IconData? icon;
  final List<Widget> actions;

  /// Determinate progress 0..1; [AppStatusTone.progress] without a value
  /// shows an indeterminate bar.
  final double? progress;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final error = tone == AppStatusTone.error;
    final background = error
        ? colors.errorContainer
        : colors.surfaceContainerHigh;
    final foreground = error ? colors.onErrorContainer : colors.onSurface;
    final accent = switch (tone) {
      AppStatusTone.progress => colors.primary,
      AppStatusTone.attention => colors.tertiary,
      AppStatusTone.error => colors.onErrorContainer,
    };
    final leading =
        icon ??
        switch (tone) {
          AppStatusTone.progress => Icons.sync,
          AppStatusTone.attention => Icons.pending_actions,
          AppStatusTone.error => Icons.error_outline,
        };
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: text.titleSmall?.copyWith(color: foreground)),
        if (message case final message?)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(
                color: error
                    ? colors.onErrorContainer
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            actions.isNotEmpty &&
            (constraints.maxWidth < AppLayout.compact ||
                MediaQuery.textScalerOf(context).scale(14) > 20);
        final row = Row(
          children: [
            Icon(leading, color: accent, size: 22),
            const SizedBox(width: 14),
            Expanded(child: body),
            if (!stacked)
              for (final action in actions) ...[
                const SizedBox(width: 8),
                action,
              ],
            if (actions.isEmpty && onTap != null) ...[
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
            ],
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                actions.isEmpty || stacked ? 16 : 12,
                stacked ? 4 : 12,
              ),
              child: row,
            ),
            if (stacked)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 4,
                  children: actions,
                ),
              ),
            if (tone == AppStatusTone.progress)
              LinearProgressIndicator(value: progress, minHeight: 3),
          ],
        );
      },
    );
    return Semantics(
      container: true,
      liveRegion: tone != AppStatusTone.progress,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(AppLayout.radius),
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? content
            : InkWell(
                onTap: onTap,
                child: tooltip == null
                    ? content
                    : Tooltip(message: tooltip!, child: content),
              ),
      ),
    );
  }
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
