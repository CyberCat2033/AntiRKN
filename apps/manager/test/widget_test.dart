import 'dart:io';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class TestLanguageStore implements LanguagePreferenceStore {
  AppLanguage value = AppLanguage.system;
  bool fail = false;
  @override
  Future<AppLanguage> readLanguage() async => value;
  @override
  Future<void> writeLanguage(AppLanguage language) async {
    if (fail) throw StateError('test write failure');
    value = language;
  }
}

void main() {
  final source = File('../../base.yml').readAsStringSync();
  Future<void> start(
    WidgetTester tester,
    LanguageController languages, {
    Size size = const Size(1200, 900),
    Key? key,
    String? initialSource,
    Future<ImportedTemplate?> Function()? pickTemplate,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await languages.load();
    await tester.pumpWidget(
      AntiRknApp(
        key: key,
        source: initialSource ?? source,
        pickTemplate: pickTemplate,
        languages: languages,
        previewTemplate: (text, nodes) async =>
            const ProfileCompiler().preview(template: text, proxies: nodes),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'file selection fills empty editor; cancellation retains imported draft',
    (tester) async {
      tester.platformDispatcher.localesTestValue = [const Locale('en')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      ImportedTemplate? selected = ImportedTemplate(
        name: 'chosen.yml',
        source: source,
      );
      await start(
        tester,
        LanguageController(TestLanguageStore()),
        initialSource: '',
        pickTemplate: () async => selected,
      );
      final editor = find.byKey(const ValueKey('template-editor'));
      expect(tester.widget<TextField>(editor).controller!.text, isEmpty);
      await tester.tap(find.byKey(const ValueKey('import-template')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, source);
      expect(find.text('Imported: chosen.yml'), findsOneWidget);
      await tester.enterText(editor, 'proxies: []\n# draft');
      selected = null;
      await tester.ensureVisible(find.byKey(const ValueKey('import-template')));
      await tester.tap(find.byKey(const ValueKey('import-template')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(editor).controller!.text,
        'proxies: []\n# draft',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in [
    ([const Locale('ru', 'RU')], 'Проверка базового профиля'),
    ([const Locale('en', 'GB')], 'Base profile check'),
    ([const Locale('de', 'DE')], 'Base profile check'),
    ([const Locale('fr'), const Locale('ru')], 'Проверка базового профиля'),
  ]) {
    testWidgets('system locale resolution ${entry.$1}', (tester) async {
      tester.platformDispatcher.localesTestValue = entry.$1;
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await start(tester, LanguageController(TestLanguageStore()));
      expect(find.text(entry.$2), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'manual selection survives restart, preserves draft and overrides OS',
    (tester) async {
      tester.platformDispatcher.localesTestValue = [const Locale('ru')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      final store = TestLanguageStore();
      await start(tester, LanguageController(store));
      final editor = find.byKey(const ValueKey('template-editor'));
      await tester.enterText(editor, 'proxies: []\n# unsaved draft');
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('language-en')));
      await tester.pumpAndSettle();
      expect(store.value, AppLanguage.en);
      expect(find.text('Interface language'), findsOneWidget);
      await tester.tap(find.text('Templates'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(editor).controller!.text,
        'proxies: []\n# unsaved draft',
      );
      tester.platformDispatcher.localesTestValue = [const Locale('ru', 'RU')];
      await tester.pumpAndSettle();
      expect(find.text('Base profile check'), findsOneWidget);
      await start(tester, LanguageController(store), key: UniqueKey());
      expect(find.text('Base profile check'), findsOneWidget);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('language-system')));
      await tester.pumpAndSettle();
      expect(find.text('Язык интерфейса'), findsOneWidget);
      tester.platformDispatcher.localesTestValue = [const Locale('en')];
      await tester.pumpAndSettle();
      expect(find.text('Interface language'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed preference write keeps previous language and reports failure',
    (tester) async {
      tester.platformDispatcher.localesTestValue = [const Locale('en')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      final store = TestLanguageStore()..fail = true;
      await start(tester, LanguageController(store));
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('language-ru')));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not save the language preference. Please try again.'),
        findsOneWidget,
      );
      expect(store.value, AppLanguage.system);
    },
  );

  for (final language in ['en', 'ru']) {
    testWidgets('adaptive resize and large text preserve editor: $language', (
      tester,
    ) async {
      tester.platformDispatcher.localesTestValue = [Locale(language)];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await start(
        tester,
        LanguageController(TestLanguageStore()),
        size: const Size(390, 844),
      );
      expect(find.byType(NavigationBar), findsOneWidget);
      final editor = find.byKey(const ValueKey('template-editor'));
      await tester.enterText(editor, 'proxies: []\n# retained');
      for (final size in [
        const Size(700, 900),
        const Size(1000, 900),
        const Size(1400, 900),
        const Size(390, 844),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(editor).controller!.text,
          'proxies: []\n# retained',
        );
        expect(tester.takeException(), isNull);
      }
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
    });
  }

  testWidgets('system reduced motion overrides requested motion', (
    tester,
  ) async {
    Duration? duration;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              duration = AppMotion.duration(context, MotionPreference.system);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(duration, Duration.zero);
  });
}
