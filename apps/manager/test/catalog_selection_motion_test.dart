import 'package:antirkn_manager/catalog_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'selection moves content continuously and reverses without a jump',
    (tester) async {
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: active,
              builder: (context, selecting, _) => ListTile(
                leading: CatalogSelectionLeading(
                  active: selecting,
                  selected: false,
                  onChanged: (_) {},
                  child: const SizedBox(width: 40, height: 40),
                ),
                title: const Text('Server'),
              ),
            ),
          ),
        ),
      );
      double x() => tester.getTopLeft(find.text('Server')).dx;
      final initial = x();
      active.value = true;
      await tester.pump();
      expect(x(), initial);
      await tester.pump(const Duration(milliseconds: 110));
      expect(x(), greaterThan(initial));
      // The checkbox slot is the full 48 dp target (UI-67).
      expect(x(), lessThan(initial + 48));
      final halfway = x();
      active.value = false;
      await tester.pump();
      expect(x(), halfway);
      await tester.pumpAndSettle();
      expect(x(), initial);
      expect(tester.takeException(), isNull);
    },
  );
}
