import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/server_address_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'network_support.dart';

class _LanguageStore implements LanguagePreferenceStore {
  @override
  Future<AppLanguage> readLanguage() async => AppLanguage.en;
  @override
  Future<void> writeLanguage(AppLanguage language) async {}
}

void main() {
  Future<LanguageController> start(
    WidgetTester tester,
    TestInventoryReader reader, {
    Size size = const Size(1200, 1000),
    String language = 'en',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final languages = LanguageController(_LanguageStore());
    await languages.load();
    if (language == 'ru') await languages.select(AppLanguage.ru);
    await tester.pumpWidget(
      AntiRknApp(source: '', languages: languages, networkReader: reader),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(language == 'en' ? 'Servers' : 'Серверы'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('load-network-sample')));
    await tester.pumpAndSettle();
    return languages;
  }

  Future<void> startPickers(
    WidgetTester tester, {
    String language = 'en',
    Size size = const Size(1200, 1000),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final c = NetworkController(
      reader: TestInventoryReader(() async => testInventory()),
    );
    await c.load();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(language),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (context, _) => ListView(
              key: const PageStorageKey('network-workbench'),
              children: [
                for (final role in AddressRole.values)
                  ServerAddressPicker(
                    motion: MotionPreference.system,
                    role: role,
                    choices: c.choices(role),
                    selected: c.selected(role),
                    selectionIssue: c.selectionIssue(role),
                    enabled: true,
                    onSelected: (choice) => c.select(role, choice),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, AddressRole role) async {
    final button = find.byKey(ValueKey('pick-${role.name}'));
    final scrollable = find.descendant(
      of: find.byKey(const PageStorageKey('network-workbench')),
      matching: find.byType(Scrollable),
    );
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(button, 250, scrollable: scrollable);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<Finder> option(
    WidgetTester tester,
    AddressRole role,
    String host,
  ) async {
    final list = find.descendant(
      of: find.byKey(ValueKey('address-options-${role.name}')),
      matching: find.byType(Scrollable),
    );
    tester.state<ScrollableState>(list).position.jumpTo(0);
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(ListTile, host);
    await tester.scrollUntilVisible(tile, 200, scrollable: list);
    await tester.pumpAndSettle();
    return tile;
  }

  for (final language in ['en', 'ru']) {
    testWidgets(
      'public IPs precede internal IPs without losing categories: $language',
      (tester) async {
        await start(
          tester,
          TestInventoryReader(() async => testInventory()),
          language: language,
        );
        final external = find.byKey(const ValueKey('addresses-external'));
        final internal = find.byKey(const ValueKey('addresses-internal'));
        await tester.scrollUntilVisible(
          external,
          350,
          scrollable: find.descendant(
            of: find.byKey(const PageStorageKey('network-workbench')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(external).dy,
          lessThan(tester.getTopLeft(internal).dy),
        );
        expect(
          tester.getTopLeft(find.text('93.184.215.15').last).dy,
          lessThan(tester.getTopLeft(internal).dy),
        );
        expect(
          tester.getTopLeft(find.text('10.10.0.2').last).dy,
          greaterThan(tester.getTopLeft(internal).dy),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('packaged sample is readable by the application asset loader', (
    tester,
  ) async {
    final inventory = await tester.runAsync(
      () => const SampleInventoryReader().read(),
    );
    expect(inventory!.source, NetworkSource.sample);
    expect(inventory.addresses, hasLength(14));
  });

  testWidgets('one shared picker enforces listener and endpoint roles', (
    tester,
  ) async {
    await startPickers(tester);
    expect(find.byType(ServerAddressPicker), findsNWidgets(2));
    await open(tester, AddressRole.listener);
    final wildcard = await option(tester, AddressRole.listener, '0.0.0.0');
    expect(tester.widget<ListTile>(wildcard).enabled, isTrue);
    await tester.tap(wildcard);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ServerAddressPicker>(find.byType(ServerAddressPicker).first)
          .selected!
          .host,
      '0.0.0.0',
    );
    await open(tester, AddressRole.endpoint);
    expect(find.widgetWithText(ListTile, '0.0.0.0'), findsNothing);
    final local = await option(tester, AddressRole.endpoint, '10.10.0.2');
    expect(tester.widget<ListTile>(local).enabled, isFalse);
    final public = await option(tester, AddressRole.endpoint, '93.184.215.15');
    await tester.scrollUntilVisible(
      public,
      200,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('address-options-endpoint')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(public);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ServerAddressPicker>(find.byType(ServerAddressPicker).last)
          .selected!
          .host,
      '93.184.215.15',
    );
  });

  testWidgets('server inventory has no protocol address controls', (
    tester,
  ) async {
    final languages = await start(
      tester,
      TestInventoryReader(() async => testInventory()),
    );
    expect(find.byType(ServerAddressPicker), findsNothing);
    await languages.select(AppLanguage.ru);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.byType(ServerAddressPicker), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keyboard opens picker, escape dismisses without changing selection',
    (tester) async {
      await startPickers(tester);
      final button = find.byKey(const ValueKey('pick-listener'));
      await tester.ensureVisible(button);
      final element = tester.element(button);
      final focus = Focus.of(element, scopeOk: true);
      focus.requestFocus();
      // Tab through actual focus traversal to the listening-address button.
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        if (FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<OutlinedButton>()
                ?.key ==
            const ValueKey('pick-listener')) {
          break;
        }
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('address-options-listener')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('address-options-listener')),
        findsNothing,
      );
      expect(
        tester
            .widget<ServerAddressPicker>(find.byType(ServerAddressPicker).first)
            .selected,
        isNull,
      );
    },
  );

  for (final language in ['en', 'ru']) {
    testWidgets('large text and adaptive layout with open picker: $language', (
      tester,
    ) async {
      await startPickers(
        tester,
        language: language,
        size: const Size(390, 844),
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      for (final size in [
        const Size(390, 844),
        const Size(700, 900),
        const Size(1000, 900),
        const Size(1400, 1000),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        await open(tester, AddressRole.endpoint);
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.byTooltip(language == 'en' ? 'Close' : 'Закрыть'),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
