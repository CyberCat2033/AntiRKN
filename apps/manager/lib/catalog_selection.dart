import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'l10n/app_localizations.dart';

/// Selection belongs to the catalogue, survives resize, and uses stable IDs.
class CatalogSelection extends ChangeNotifier {
  bool active = false;
  final ids = <String>{};
  bool replace(Set<String> values) {
    if (setEquals(ids, values)) return false;
    ids
      ..clear()
      ..addAll(values);
    notifyListeners();
    return true;
  }

  void start({bool longPress = false}) {
    if (active) return;
    if (longPress) {
      AppHaptics.dragStart();
    } else {
      AppHaptics.selection();
    }
    active = true;
    ids.clear();
    notifyListeners();
  }

  void exit() {
    if (!active) return;
    AppHaptics.selection();
    active = false;
    ids.clear();
    notifyListeners();
  }

  void toggle(String id) {
    AppHaptics.selection();
    if (!ids.remove(id)) ids.add(id);
    notifyListeners();
  }

  void selectAll(Iterable<String> available) {
    AppHaptics.selection();
    final next = available.toSet();
    if (next.isNotEmpty && ids.containsAll(next)) {
      ids.clear();
    } else {
      ids
        ..clear()
        ..addAll(next);
    }
    notifyListeners();
  }
}

/// The avatar stays in place while space for selection expands from the left.
class CatalogSelectionLeading extends StatelessWidget {
  const CatalogSelectionLeading({
    required this.active,
    required this.selected,
    required this.onChanged,
    required this.child,
    this.checkboxKey,
    super.key,
  });
  final bool active, selected;
  final ValueChanged<bool?>? onChanged;
  final Widget child;
  final Key? checkboxKey;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      TweenAnimationBuilder<double>(
        tween: Tween(end: active ? 1 : 0),
        duration: AppMotion.duration(context, MotionPreference.system),
        curve: Curves.easeInOutCubicEmphasized,
        builder: (context, value, _) => ClipRect(
          // The full 48 dp target of the checkbox, not a clipped 36 (UI-67).
          child: SizedBox(
            width: 48 * value,
            height: 48,
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 48,
              maxWidth: 48,
              child: ExcludeSemantics(
                excluding: !active,
                child: IgnorePointer(
                  ignoring: !active,
                  child: Opacity(
                    opacity: value,
                    child: Transform.scale(
                      scale: .86 + .14 * value,
                      alignment: Alignment.centerLeft,
                      child: Checkbox(
                        key: checkboxKey,
                        value: selected,
                        onChanged: active ? onChanged : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child,
    ],
  );
}

class CatalogTitle extends StatelessWidget {
  const CatalogTitle({required this.selection, required this.title, super.key});
  final CatalogSelection selection;
  final String title;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // The count follows each toggle without rebuilding the whole shell.
    listenable: selection,
    builder: (context, _) => AnimatedSwitcher(
      duration: AppMotion.duration(context, MotionPreference.system),
      // Start-aligned: the title does not drift to the centre while the
      // two texts cross-fade (UI-67).
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [...previous, ?current],
      ),
      child: Text(
        selection.active
            ? AppLocalizations.of(context).catalogSelected(selection.ids.length)
            : title,
        key: ValueKey(selection.active),
      ),
    ),
  );
}

class CatalogNormalContent extends StatelessWidget {
  const CatalogNormalContent({
    required this.selection,
    required this.child,
    super.key,
  });
  final CatalogSelection selection;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final content = selection.active
        ? const SizedBox(width: double.infinity)
        : child;
    final duration = AppMotion.duration(context, MotionPreference.system);
    // A zero-length AnimatedSize re-dirties itself during layout (Flutter
    // assertion); with motion off the content simply switches, as AppAnimatedSize.
    if (duration == Duration.zero) return content;
    return AnimatedSize(
      duration: duration,
      curve: Curves.easeInOutCubicEmphasized,
      alignment: Alignment.topCenter,
      child: content,
    );
  }
}

class CatalogActions extends StatelessWidget {
  const CatalogActions({
    required this.selection,
    required this.available,
    required this.onDelete,
    required this.prefix,
    this.onAdd,
    this.addLabel,
    this.busy = false,
    super.key,
  });
  final CatalogSelection selection;
  final Iterable<String> available;
  final VoidCallback onDelete;
  final VoidCallback? onAdd;
  final String prefix;
  final String? addLabel;
  final bool busy;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: selection,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      return AnimatedSwitcher(
        duration: AppMotion.duration(context, MotionPreference.system),
        switchInCurve: AppMotion.curve,
        // End-aligned like the app bar actions it replaces (UI-67).
        layoutBuilder: (current, previous) => Stack(
          alignment: AlignmentDirectional.centerEnd,
          children: [...previous, ?current],
        ),
        child: Row(
          key: ValueKey(selection.active),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selection.active) ...[
              IconButton(
                key: ValueKey('$prefix-delete-selected'),
                tooltip: l.catalogDeleteSelected,
                onPressed: busy || selection.ids.isEmpty ? null : onDelete,
                icon: const Icon(Icons.delete_outline),
              ),
              IconButton(
                key: ValueKey('$prefix-select-all'),
                tooltip: l.catalogSelectAll,
                onPressed: busy || available.isEmpty
                    ? null
                    : () => selection.selectAll(available),
                icon: const Icon(Icons.select_all),
              ),
              IconButton(
                key: ValueKey('$prefix-edit-exit'),
                tooltip: l.catalogExitEditing,
                onPressed: busy ? null : selection.exit,
                icon: const Icon(Icons.close),
              ),
            ] else ...[
              if (addLabel != null)
                IconButton(
                  key: ValueKey('$prefix-add'),
                  tooltip: addLabel,
                  onPressed: busy ? null : onAdd,
                  icon: const Icon(Icons.add),
                ),
              IconButton(
                key: ValueKey('$prefix-edit'),
                tooltip: l.catalogEdit,
                onPressed: busy || available.isEmpty ? null : selection.start,
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ],
        ),
      );
    },
  );
}

Future<bool> confirmCatalogDeletion(
  BuildContext context, {
  required String explanation,
  required List<String> names,
  Widget? extra,
  required String confirmKey,
}) async {
  final l = AppLocalizations.of(context);
  return await showDialog<bool>(
        context: context,
        builder: (context) => AppFormDialog(
          title: Text(l.catalogDeleteSelected),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(explanation),
              const SizedBox(height: AppLayout.gap),
              for (final name in names) Text(name),
              ?extra,
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.sshCancel),
            ),
            AppDangerButton(
              key: ValueKey(confirmKey),
              onPressed: () {
                AppHaptics.deleted();
                Navigator.pop(context, true);
              },
              child: Text(l.catalogDeleteSelected),
            ),
          ],
        ),
      ) ??
      false;
}
