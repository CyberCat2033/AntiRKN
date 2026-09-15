import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/publication/profile_link_qr.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  for (final language in ['ru', 'en']) {
    testWidgets(
      '$language QR renders and copies the link; clipboard failure can retry',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const url = 'https://drive.google.com/uc?export=download&id=fixture';
        var fail = true, guards = 0;
        final copies = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              if (fail) throw PlatformException(code: 'denied');
              copies.add((call.arguments as Map)['text'] as String);
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
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: AppTheme.create(Brightness.dark),
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: ListView(
                  children: [
                    ProfileLinkQr(
                      url: url,
                      beforeCopy: () async {
                        guards++;
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final qr = find.byKey(const ValueKey('profile-link-qr'));
        expect(find.byType(QrImageView), findsOneWidget);
        await tester.tap(qr);
        await tester.pumpAndSettle();
        expect(copies, isEmpty);
        expect(find.byType(SnackBar), findsNothing);
        expect(
          find.text(
            language == 'ru'
                ? 'Не удалось скопировать ссылку. Нажмите QR ещё раз.'
                : 'Could not copy the link. Tap the QR code to retry.',
          ),
          findsOneWidget,
        );
        fail = false;
        await tester.tap(qr);
        await tester.pumpAndSettle();
        expect(copies, [url]);
        expect(guards, 2);
        expect(
          find.text(language == 'ru' ? 'Ссылка скопирована' : 'Link copied'),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.copy), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('conflict gate prevents copying a profile link', (tester) async {
    var copied = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = true;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ProfileLinkQr(
            url: 'https://example.invalid/profile.yml',
            beforeCopy: () async {
              throw const SyncMergeFailure(SyncMergeIssue.changed);
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('profile-link-qr')));
    await tester.pumpAndSettle();
    expect(copied, isFalse);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
