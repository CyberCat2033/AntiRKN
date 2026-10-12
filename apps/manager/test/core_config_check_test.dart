import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/vpn/core_config_check.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as fixtures;

class Validator implements CoreConfigValidator {
  Completer<void>? hold;
  CancellationToken? token;
  String? yaml;
  @override
  Future<CoreConfigCheck> validate(
    String source,
    CancellationToken cancellation,
  ) async {
    yaml = source;
    token = cancellation;
    if (hold != null) await hold!.future;
    return CoreConfigCheck(
      status: cancellation.isCancelled
          ? CoreConfigStatus.cancelled
          : CoreConfigStatus.invalid,
      code: cancellation.isCancelled ? 'cancelled' : 'core_rejected',
      profileHash: sha256.convert(utf8.encode(source)).toString(),
      checkedAt: DateTime.now().toUtc(),
      version: '1.19.30',
      path: 'proxies[0]',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'validation is read-only and a changed template discards a late result',
    () async {
      final store = fixtures.MemoryVpn();
      final remotes = {
        'one': fixtures.Remote(store),
        'two': fixtures.Remote(store),
      };
      final validator = Validator();
      var source = fixtures.template;
      final c = fixtures.controller(
        store,
        remotes,
        source: () => source,
        coreValidator: validator,
      );
      addTearDown(c.dispose);
      await fixtures.setup(c);
      await c.prepare();
      await c.apply();
      final before = store.raw;
      final actions = remotes.values.map((r) => r.actions.length).toList();
      await c.validateCoreProfile(fixtures.alice);
      expect(c.coreCheckFor(fixtures.alice)?.status, CoreConfigStatus.invalid);
      expect(validator.yaml, c.results[fixtures.alice]!.yaml);
      expect(store.raw, before);
      expect(remotes.values.map((r) => r.actions.length), actions);
      validator.hold = Completer();
      final run = c.validateCoreProfile(fixtures.alice);
      while (validator.token == null || !c.coreValidationBusy) {
        await Future<void>.delayed(Duration.zero);
      }
      source = '${fixtures.template}\n# changed template';
      validator.hold!.complete();
      await run;
      expect(c.coreCheckFor(fixtures.alice), isNull);
      expect(c.coreValidationBusy, isFalse);
    },
  );
  for (final language in ['ru', 'en']) {
    testWidgets(
      'core check dialog and cancel at narrow large text: $language',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final store = fixtures.MemoryVpn();
        final validator = Validator()..hold = Completer();
        final c = (await tester.runAsync(() async {
          final c = fixtures.controller(store, {
            'one': fixtures.Remote(store),
            'two': fixtures.Remote(store),
          }, coreValidator: validator);
          await fixtures.setup(c);
          await c.prepare();
          await c.apply();
          return c;
        }))!;
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: CoreConfigCheckAction(
                controller: c,
                userId: fixtures.alice,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('core-check-${fixtures.alice}')),
          );
          for (var i = 0; i < 100 && validator.token == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        await tester.tap(
          find.widgetWithText(
            TextButton,
            language == 'ru' ? 'Остановить' : 'Stop',
          ),
        );
        await tester.pump();
        expect(validator.token!.isCancelled, isTrue);
        validator.hold!.complete();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();
        expect(
          c.coreCheckFor(fixtures.alice)?.status,
          CoreConfigStatus.cancelled,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
