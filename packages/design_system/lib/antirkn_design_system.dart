import 'package:flutter/material.dart';

abstract final class AppLayout {
  static const compact = 600.0;
  static const expanded = 840.0;
  static const large = 1200.0;
  static const gap = 16.0;
  static const smallGap = 8.0;
  static const contentWidth = 1440.0;
  static const padding = EdgeInsets.all(24);
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
  const SectionCard({required this.title, required this.child, super.key});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card.outlined(
    child: Padding(
      padding: AppLayout.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppLayout.gap),
          child,
        ],
      ),
    ),
  );
}
