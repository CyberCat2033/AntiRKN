import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';

/// Fingers move right-to-left: pan is negative; natural scroll offset positive.
class DesktopBackGesture extends StatefulWidget {
  const DesktopBackGesture({
    required this.onBack,
    required this.canGoBack,
    required this.child,
    this.motion = MotionPreference.system,
    super.key,
  });
  final VoidCallback onBack;
  final bool Function() canGoBack;
  final Widget child;
  final MotionPreference motion;
  @override
  State<DesktopBackGesture> createState() => _DesktopBackGestureState();
}

class _DesktopBackGestureState extends State<DesktopBackGesture> {
  Offset travel = Offset.zero;
  Duration? last;
  Timer? end;
  double progress = 0;
  bool horizontal = false;
  DateTime? committedAt;

  /// The gesture began over content that scrolls sideways, or while another
  /// route (a dialog, a sheet) is on top: it belongs to that content.
  bool ignored = false;

  bool _ownsGesture(PointerEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return false;
    final result = HitTestResult();
    GestureBinding.instance.hitTestInView(result, event.position, event.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderViewportBase && target.axis == Axis.horizontal) {
        return false;
      }
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(pointer);
  }

  void pointer(PointerEvent event) {
    if (!const {
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }.contains(defaultTargetPlatform)) {
      return;
    }
    if (event is PointerPanZoomStartEvent) {
      end?.cancel();
      travel = Offset.zero;
      horizontal = false;
      last = null;
      committedAt = null;
      ignored = !_ownsGesture(event);
    } else if (event is PointerPanZoomUpdateEvent) {
      if (ignored) return;
      travel = event.pan;
      update();
    } else if (event is PointerPanZoomEndEvent) {
      finish();
    } else if (event is PointerScrollEvent) {
      if (committedAt != null &&
          DateTime.now().difference(committedAt!) <
              const Duration(milliseconds: 550)) {
        return;
      }
      if (last == null ||
          event.timeStamp - last! > const Duration(milliseconds: 220)) {
        travel = Offset.zero;
        horizontal = false;
        ignored = !_ownsGesture(event);
      }
      last = event.timeStamp;
      if (ignored) return;
      travel -= event.scrollDelta;
      update();
      end?.cancel();
      end = Timer(const Duration(milliseconds: 180), finish);
    }
  }

  void update() {
    if (ignored || !widget.canGoBack()) return;
    if (travel.distance > 16 && !horizontal) {
      horizontal = travel.dx.abs() > travel.dy.abs() * 2;
    }
    final value = horizontal ? (-travel.dx / 120).clamp(0.0, 1.0) : 0.0;
    if (value != progress) setState(() => progress = value);
  }

  void finish() {
    end?.cancel();
    if (!ignored && progress >= 1 && widget.canGoBack()) {
      committedAt = DateTime.now();
      widget.onBack();
    }
    if (mounted && progress != 0) setState(() => progress = 0);
    travel = Offset.zero;
  }

  @override
  void dispose() {
    end?.cancel();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(pointer);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.duration(context, widget.motion);
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedSlide(
              offset: Offset(progress > 0 ? .25 : -1.1, 0),
              duration: duration,
              curve: AppMotion.curve,
              child: AnimatedOpacity(
                opacity: progress > 0 ? 1 : 0,
                duration: duration,
                child: Transform.scale(
                  scale: .8 + progress * .2,
                  child: Material(
                    elevation: 4,
                    shape: const CircleBorder(),
                    color: progress >= 1
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.arrow_back),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
