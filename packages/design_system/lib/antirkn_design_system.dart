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
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      cardTheme: const CardThemeData(margin: EdgeInsets.zero),
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
                  style: Theme.of(context).textTheme.titleLarge,
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
          if (constraints.maxWidth < AppLayout.compact ||
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
    this.actions,
    super.key,
  });
  final String title, subtitle;
  final List<Widget> details;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => Card.filled(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpansionTile(
          maintainState: true,
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text(title),
          subtitle: Text(subtitle),
          childrenPadding: const EdgeInsets.symmetric(
            horizontal: AppLayout.gap,
            vertical: AppLayout.smallGap,
          ),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: details,
        ),
        if (actions != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppLayout.smallGap,
              0,
              AppLayout.smallGap,
              AppLayout.smallGap,
            ),
            child: actions!,
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
  Widget build(BuildContext context) => ExpansionTile(
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
        return total + width + 64;
      });
      return SegmentedButton<T>(
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
