import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/catalog_selection.dart';
import 'package:antirkn_manager/drag_select_list.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in ['ru', 'en']) {
    testWidgets(
      'long press, reversible range, edge scroll and feedback: $locale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 650);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final selection = CatalogSelection();
        addTearDown(selection.dispose);
        final feedback = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              feedback.add(call.arguments as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        var taps = 0;
        ScrollController? scroll;
        final ids = List.generate(40, (i) => '$i');
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.create(Brightness.dark),
            locale: Locale(locale),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: ListenableBuilder(
              listenable: selection,
              builder: (context, _) => Scaffold(
                appBar: AppBar(
                  title: Text(
                    selection.active
                        ? AppLocalizations.of(
                            context,
                          ).catalogSelected(selection.ids.length)
                        : 'Catalogue',
                  ),
                  actions: [
                    CatalogActions(
                      selection: selection,
                      available: ids,
                      prefix: 'test',
                      onDelete: () {},
                    ),
                  ],
                ),
                body: DragSelectList(
                  selection: selection,
                  ids: ids,
                  builder: (controller, item) {
                    scroll = controller;
                    return ListView(
                      controller: controller,
                      children: [
                        for (final id in ids)
                          item(
                            id,
                            SizedBox(
                              height: 72,
                              child: ListTile(
                                key: ValueKey('row-$id'),
                                leading: selection.active
                                    ? Checkbox(
                                        value: selection.ids.contains(id),
                                        onChanged: (_) => selection.toggle(id),
                                      )
                                    : null,
                                title: Text('Item $id'),
                                onTap: () => taps++,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final start = tester.getCenter(find.byKey(const ValueKey('row-1')));
        final gesture = await tester.startGesture(start);
        await tester.pump(const Duration(milliseconds: 600));
        expect(selection.active, true);
        expect(selection.ids, {'1'});
        await gesture.moveTo(
          tester.getCenter(find.byKey(const ValueKey('row-4'))),
        );
        await tester.pump();
        expect(selection.ids, {'1', '2', '3', '4'});
        await gesture.moveTo(start);
        await tester.pump();
        expect(selection.ids, {'1'});
        await gesture.moveTo(const Offset(190, 645));
        for (var i = 0; i < 70; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(scroll!.offset, greaterThan(500));
        expect(selection.ids.length, greaterThan(10));
        await gesture.moveTo(const Offset(190, 58));
        for (var i = 0; i < 85; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(scroll!.offset, 0);
        await gesture.moveTo(start);
        await tester.pump();
        expect(selection.ids, {'1'});
        await gesture.up();
        await tester.pumpAndSettle();
        expect(taps, 0);
        expect(feedback.length, greaterThan(5));
        final clicks = feedback.length;
        await tester.pump(const Duration(seconds: 1));
        expect(feedback.length, clicks);
        await tester.tap(find.byKey(const ValueKey('test-select-all')));
        await tester.pumpAndSettle();
        expect(selection.ids.length, 40);
        await tester.tap(find.byKey(const ValueKey('test-select-all')));
        await tester.pumpAndSettle();
        expect(selection.ids, isEmpty);
        await tester.tap(find.byKey(const ValueKey('test-edit-exit')));
        await tester.pumpAndSettle();
        expect(selection.active, false);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
