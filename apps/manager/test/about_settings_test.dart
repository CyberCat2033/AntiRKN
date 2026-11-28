import 'dart:io';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/about_settings.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the bundled license is the repository LICENSE', () {
    expect(
      File(appLicenseAsset).readAsStringSync(),
      File('../../LICENSE').readAsStringSync(),
    );
  });

  testWidgets('About opens the licenses page with the app GPL entry', (
    tester,
  ) async {
    registerAppLicenses();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: AboutSettings(motion: MotionPreference.off),
          ),
        ),
      ),
    );
    expect(find.textContaining('not a VPN service'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('about-licenses')));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    final packages = <String>{};
    await for (final entry in LicenseRegistry.licenses) {
      packages.addAll(entry.packages);
    }
    expect(packages, containsAll(['AntiRKN', 'mihomo']));
    expect(
      await rootBundle.loadString(appLicenseAsset),
      contains('GNU GENERAL PUBLIC LICENSE'),
    );
    expect(tester.takeException(), isNull);
  });
}
