import 'dart:io';
import 'dart:ui' as ui;
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'backup_test.dart' as backup;
import 'google_account_test.dart' as google;

class _Language implements LanguagePreferenceStore {
  _Language(this.value);
  final AppLanguage value;
  @override
  Future<AppLanguage> readLanguage() async => value;
  @override
  Future<void> writeLanguage(AppLanguage value) async {}
}

void main() {
  for (final locale in ['ru', 'en']) {
    for (final width in [390.0, 1200.0]) {
      testWidgets(
        'settings expose essentials and retain options at $width $locale',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final languages = LanguageController(
            _Language(locale == 'ru' ? AppLanguage.ru : AppLanguage.en),
          );
          await languages.load();
          addTearDown(languages.dispose);
          final account = google.AccountService();
          await account.signIn();
          final screenshots = Platform.environment['ANTIRKN_UI_EVIDENCE'];
          if (screenshots != null) {
            await tester.runAsync(() async {
              for (final font in [
                ('Roboto', '/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf'),
                (
                  'MaterialIcons',
                  '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
                ),
              ]) {
                final loader = FontLoader(font.$1)
                  ..addFont(
                    File(
                      font.$2,
                    ).readAsBytes().then((v) => ByteData.sublistView(v)),
                  );
                await loader.load();
              }
            });
          }
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: AntiRknApp(
                source: 'proxies: []',
                previewTemplate: (source, nodes) async =>
                    const ProfileCompiler().preview(
                      template: source,
                      proxies: nodes,
                    ),
                languages: languages,
                googleAccount: account,
                initialTheme: ThemeMode.dark,
                initialMotion: MotionPreference.off,
                pickTemplate: () async => null,
                backups: backup.Store(),
                backupFiles: backup.Files(),
                onRestored: () async {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          final l = lookupAppLocalizations(Locale(locale));
          await tester.tap(find.text(l.settings).last);
          await tester.pumpAndSettle();
          // Settings is a menu of sections (SettingsHub): each essential is
          // one tap away, on the page of its section.
          Future<void> section(String title, Finder essential) async {
            final tile = find.widgetWithText(ListTile, title);
            await tester.ensureVisible(tile);
            await tester.pumpAndSettle();
            await tester.tap(tile);
            await tester.pumpAndSettle();
            await tester.ensureVisible(essential);
            await tester.pumpAndSettle();
            expect(essential.hitTestable(), findsOneWidget);
            await tester.tap(find.byKey(const ValueKey('settings-back')));
            await tester.pumpAndSettle();
          }

          // The account is named once, by its display name (UI-51).
          await section(l.uiSynchronization, find.text('Fixture User'));
          await section(
            l.backupTitle,
            find.byKey(const ValueKey('backup-export')),
          );
          await section(
            l.uiClientProfiles,
            find.byKey(const ValueKey('import-template')),
          );
          expect(find.textContaining('latest upstream version'), findsNothing);
          expect(find.textContaining('SHA-256'), findsNothing);
          expect(find.textContaining('appDataFolder'), findsNothing);
          expect(find.textContaining('XChaCha'), findsNothing);
          if (screenshots != null) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(screenshots).create(recursive: true);
              await File(
                '$screenshots/settings-${width.toInt()}-$locale.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          // Large text keeps the language choice reachable.
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          await tester.pumpAndSettle();
          await section(
            l.uiInterface,
            find.widgetWithText(ListTile, l.language),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
