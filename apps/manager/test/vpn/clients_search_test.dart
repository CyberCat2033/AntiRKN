import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../vpn_controller_test.dart' as f;

class _Export implements ProfileExporter {
  @override
  Future<bool> save(String name, String source) async => true;
}

void main() {
  Future<void> clients(
    WidgetTester tester,
    int count, {
    double scale = 1,
  }) async {
    final c = f.controller(f.MemoryVpn(), {});
    addTearDown(c.dispose);
    const names = ['Anna', 'Boris', 'Clara', 'Dmitry', 'Elena', 'Fedor'];
    await tester.runAsync(() async {
      await c.load();
      for (var i = 0; i < count; i++) {
        await c.saveUser(
          VpnUser(
            id: '$i'.padLeft(32, '0'),
            login: 'user$i',
            name: i < names.length ? names[i] : 'Oleg $i',
            // The last client is disabled: search looks in its group too.
            enabled: i < count - 1,
          ),
        );
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.create(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: UsersPage(
            controller: c,
            serverName: (s) => s,
            exporter: _Export(),
            motion: MotionPreference.off,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a short list has no search field', (tester) async {
    await clients(tester, UsersPage.searchFrom - 1);
    expect(find.byKey(const ValueKey('clients-search')), findsNothing);
  });

  testWidgets('search narrows by name, disabled clients included', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await clients(tester, UsersPage.searchFrom);
    final field = find.descendant(
      of: find.byKey(const ValueKey('clients-search')),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    // The disabled client is folded away at first.
    expect(find.text('Oleg 6'), findsNothing);

    await tester.enterText(field, 'ole');
    await tester.pumpAndSettle();
    expect(find.text('Oleg 6'), findsOneWidget);
    expect(find.text('Anna'), findsNothing);

    await tester.enterText(field, 'zzz');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('clients-not-found')), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('clients-not-found')), findsNothing);
    expect(find.text('Anna'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the search field fits a phone with large text', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await clients(tester, UsersPage.searchFrom, scale: 2);
    expect(find.byKey(const ValueKey('clients-search')), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('clients-search')),
        matching: find.byType(TextField),
      ),
      'Anna',
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Clear search'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
