import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/licenses_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() {
    LicenseRegistry.reset();
    LicenseRegistry.addLicense(
      () => Stream.fromIterable([
        const LicenseEntryWithLineBreaks(['zeta'], 'Zeta license text'),
        const LicenseEntryWithLineBreaks(['AntiRKN'], 'GPL text'),
        const LicenseEntryWithLineBreaks(['alpha'], 'Alpha first text'),
        const LicenseEntryWithLineBreaks(['alpha', 'Beta'], 'Shared text'),
      ]),
    );
  });

  Future<void> open(
    WidgetTester tester,
    double width, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.create(Brightness.dark),
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const LicensesPage(
          applicationName: 'AntiRKN',
          applicationVersion: '0.1.1',
          applicationLegalese: 'Free software',
          motion: MotionPreference.off,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('components are grouped by package with the app first', () async {
    final components = await loadLicensedComponents(first: 'AntiRKN');
    expect(components.map((c) => c.name), ['AntiRKN', 'alpha', 'Beta', 'zeta']);
    expect(components[1].licenses, hasLength(2));
  });

  testWidgets('a compact width opens a component as a nested page', (
    tester,
  ) async {
    await open(tester, 390);
    expect(find.text('Version 0.1.1'), findsOneWidget);
    expect(find.text('2 licenses'), findsOneWidget);
    expect(find.text('Alpha first text'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('license-alpha')));
    await tester.pumpAndSettle();
    expect(find.text('Alpha first text'), findsOneWidget);
    expect(find.text('Shared text'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha first text'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the search narrows the components', (tester) async {
    await open(tester, 700);
    await tester.enterText(find.byType(SearchBar), 'ze');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('license-zeta')), findsOneWidget);
    expect(find.byKey(const ValueKey('license-alpha')), findsNothing);
    await tester.enterText(find.byType(SearchBar), 'nothing');
    await tester.pumpAndSettle();
    expect(find.text('No components found'), findsOneWidget);
  });

  for (final width in [1000.0, 1400.0]) {
    testWidgets('an expanded width $width shows the text beside the list', (
      tester,
    ) async {
      await open(tester, width);
      // The app's own license is open first.
      expect(find.text('GPL text'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('license-zeta')));
      await tester.pumpAndSettle();
      expect(find.text('Zeta license text'), findsOneWidget);
      expect(find.text('GPL text'), findsNothing);
      final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('license-zeta')),
      );
      expect(tile.selected, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('390 with text x2 has no overflow', (tester) async {
    await open(tester, 390, scale: 2);
    await tester.tap(find.byKey(const ValueKey('license-alpha')));
    await tester.pumpAndSettle();
    expect(find.text('Alpha first text'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
