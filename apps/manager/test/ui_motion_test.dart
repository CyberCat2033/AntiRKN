import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _DraftPage extends StatefulWidget {
  const _DraftPage({required this.onBuild});
  final VoidCallback onBuild;
  @override
  State<_DraftPage> createState() => _DraftPageState();
}

class _DraftPageState extends State<_DraftPage> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return Column(
      children: [
        const SizedBox(key: ValueKey('page-origin'), width: 100, height: 50),
        TextField(key: const ValueKey('draft'), controller: controller),
      ],
    );
  }
}

void main() {
  for (final width in [390.0, 1400.0]) {
    testWidgets(
      'hierarchy at $width preserves drafts and avoids per-frame page builds',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var index = 0;
        var builds = 0;
        var backCalls = 0;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return AppPageSwitch(
                    index: index,
                    depth: index,
                    children: [
                      const Center(child: Text('catalogue')),
                      Builder(
                        builder: (context) {
                          final active = AppPageVisibility.of(context);
                          return PopScope(
                            canPop: !active,
                            onPopInvokedWithResult: (didPop, _) {
                              if (active && !didPop) backCalls++;
                            },
                            child: _DraftPage(onBuild: () => builds++),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        update(() => index = 1);
        await tester.pump();
        final afterNavigation = builds;
        await tester.pump(const Duration(milliseconds: 60));
        final origin = tester.getCenter(
          find.byKey(const ValueKey('page-origin')),
        );
        // Opening stays centred at both phone and desktop widths.
        expect(origin.dx, closeTo(width / 2, 1));
        await tester.pumpAndSettle();
        expect(builds, afterNavigation);
        await tester.enterText(find.byKey(const ValueKey('draft')), 'unsaved');
        tester.testTextInput.hide();
        update(() => index = 0);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final duringBack = tester.getRect(
          find.byKey(const ValueKey('page-origin')),
        );
        update(() => index = 1);
        await tester.pump();
        final reversed = tester.getRect(
          find.byKey(const ValueKey('page-origin')),
        );
        expect(reversed.left, closeTo(duringBack.left, .01));
        expect(reversed.width, closeTo(duringBack.width, .01));
        await tester.pumpAndSettle();
        expect(find.text('unsaved'), findsOneWidget);
        update(() => index = 0);
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        expect(backCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('system reduced motion switches without a pending transition', (
    tester,
  ) async {
    var index = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            disableAnimations: true,
          ),
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return AppPageSwitch(
                index: index,
                depth: index,
                children: const [Text('first'), Text('second')],
              );
            },
          ),
        ),
      ),
    );
    update(() => index = 1);
    await tester.pump();
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    await tester
        .pump(); // Flush focus/semantics changes, without advancing time.
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final brightness in Brightness.values) {
    test(
      'legacy dynamic palette retains system accents and distinct surfaces $brightness',
      () {
        final base = ColorScheme.fromSeed(
          seedColor: Colors.pink,
          brightness: brightness,
        );
        final legacy = base.copyWith(
          surfaceContainerLowest: base.surface,
          surfaceContainerLow: base.surface,
          surfaceContainer: base.surface,
          surfaceContainerHigh: base.surface,
          surfaceContainerHighest: base.surface,
        );
        final theme = AppTheme.create(brightness, dynamicScheme: legacy);
        final colors = theme.colorScheme;
        expect(colors.primary, legacy.primary);
        expect(colors.secondaryContainer, legacy.secondaryContainer);
        expect(
          colors.surfaceContainerLow,
          isNot(colors.surfaceContainerLowest),
        );
        expect(colors.surfaceContainerHigh, isNot(colors.surfaceContainerLow));
        expect(theme.cardTheme.color, colors.surfaceContainerLow);
        expect(theme.scaffoldBackgroundColor, colors.surfaceContainerLowest);
        final foreground = colors.onSurface.computeLuminance();
        final background = colors.surfaceContainerLow.computeLuminance();
        final contrast = foreground > background
            ? (foreground + .05) / (background + .05)
            : (background + .05) / (foreground + .05);
        expect(contrast, greaterThan(4.5));
        expect(
          AppTheme.create(brightness, dynamicScheme: base).colorScheme,
          base,
        );
      },
    );
  }

  testWidgets('explicit add and delete feedback is mobile only', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          calls.add(call.arguments as String);
        }
        return null;
      },
    );
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    AppHaptics.added();
    AppHaptics.deleted();
    await tester.pump();
    expect(calls, isEmpty);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AppHaptics.added();
    AppHaptics.deleted();
    await tester.pump();
    expect(calls, [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.mediumImpact',
    ]);
    debugDefaultTargetPlatformOverride = null;
  });
}
