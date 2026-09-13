import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

class NetworkController extends ChangeNotifier {
  NetworkController({required this.reader, DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  final NetworkInventoryReader reader;
  final DateTime Function() clock;
  final policy = const AddressSelectionPolicy();
  ServerNetworkInventory? inventory;
  bool loading = false;
  bool failed = false;
  bool _disposed = false;
  final _selections = <AddressRole, AddressChoice>{};

  void accept(ServerNetworkInventory next) {
    if (_disposed) return;
    if (inventory?.serverId != next.serverId) _selections.clear();
    inventory = next;
    failed = false;
    for (final role in AddressRole.values) {
      final previous = selected(role);
      if (previous == null) continue;
      final matching = choices(role).where((c) => c.id == previous.id);
      if (matching.isNotEmpty) _selections[role] = matching.first;
    }
    notifyListeners();
  }

  void clear() {
    inventory = null;
    _selections.clear();
    failed = false;
    if (!_disposed) notifyListeners();
  }

  void tick() {
    if (!_disposed && inventory != null) notifyListeners();
  }

  AddressChoice? selected(AddressRole role) => _selections[role];
  List<AddressChoice> choices(AddressRole role) =>
      inventory == null ? [] : policy.choices(inventory!, role, now: clock());

  SelectionIssue? selectionIssue(AddressRole role) {
    final choice = selected(role);
    if (choice == null) return null;
    if (inventory == null) return SelectionIssue.unavailable;
    return policy.validateSelection(choice, inventory!, role, now: clock());
  }

  void select(AddressRole role, AddressChoice? choice) {
    if (_disposed || loading) return;
    if (choice == null) {
      _selections.remove(role);
    } else {
      final current = choices(
        role,
      ).where((c) => c.id == choice.id && c.enabled);
      if (current.isEmpty) return;
      _selections[role] = current.first;
    }
    notifyListeners();
  }

  Future<void> load() async {
    if (_disposed || loading) return;
    loading = true;
    failed = false;
    notifyListeners();
    try {
      final next = await reader.read();
      if (!_disposed) {
        accept(next);
      }
    } catch (_) {
      if (!_disposed) failed = true;
    } finally {
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
