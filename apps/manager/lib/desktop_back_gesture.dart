import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Fingers move right-to-left: pan is negative; natural scroll offset positive.
class DesktopBackGesture extends StatefulWidget {
  const DesktopBackGesture({
    required this.onBack,
    required this.canGoBack,
    required this.child,
    super.key,
  });
  final VoidCallback onBack;
  final bool Function() canGoBack;
  final Widget child;
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
    } else if (event is PointerPanZoomUpdateEvent) {
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
      }
      last = event.timeStamp;
      travel -= event.scrollDelta;
      update();
      end?.cancel();
      end = Timer(const Duration(milliseconds: 180), finish);
    }
  }

  void update() {
    if (!widget.canGoBack()) return;
    if (travel.distance > 16 && !horizontal) {
      horizontal = travel.dx.abs() > travel.dy.abs() * 2;
    }
    final value = horizontal ? (-travel.dx / 120).clamp(0.0, 1.0) : 0.0;
    if (value != progress) setState(() => progress = value);
  }

  void finish() {
    end?.cancel();
    if (progress >= 1 && widget.canGoBack()) {
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
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      IgnorePointer(
        child: Align(
          alignment: Alignment.centerLeft,
          child: AnimatedSlide(
            offset: Offset(progress > 0 ? .25 : -1.1, 0),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: progress > 0 ? 1 : 0,
              duration: const Duration(milliseconds: 160),
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
