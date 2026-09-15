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

  void start() {
    active = true;
    ids.clear();
    notifyListeners();
  }

  void exit() {
    active = false;
    ids.clear();
    notifyListeners();
  }

  void toggle(String id) {
    if (!ids.remove(id)) ids.add(id);
    notifyListeners();
  }

  void selectAll(Iterable<String> available) {
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
      return Row(
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
        builder: (context) => AlertDialog(
          title: Text(l.catalogDeleteSelected),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(explanation),
                const SizedBox(height: AppLayout.gap),
                for (final name in names) Text(name),
                ?extra,
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.sshCancel),
            ),
            FilledButton(
              key: ValueKey(confirmKey),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.catalogDeleteSelected),
            ),
          ],
        ),
      ) ??
      false;
}
