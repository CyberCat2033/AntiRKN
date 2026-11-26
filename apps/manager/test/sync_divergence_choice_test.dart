import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/sync/auto_sync_controller.dart';
import 'package:antirkn_manager/sync/google_account_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'auto_sync_test.dart' show Session, Settings;
import 'google_account_test.dart' show AccountService;

final _divergence = SyncDivergence(
  local: SyncVersionInfo(savedAt: DateTime.utc(2026, 11, 25, 9, 30)),
  cloud: SyncVersionInfo(
    savedAt: DateTime.utc(2026, 11, 25, 10, 15),
    deviceName: 'Linux · desk',
  ),
);

final _otherWorkspace = SyncDivergence(
  local: const SyncVersionInfo(),
  cloud: SyncVersionInfo(
    savedAt: DateTime.utc(2026, 11, 25, 10, 15),
    deviceName: 'Linux · desk',
  ),
  otherWorkspace: true,
);

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    for (final width in [390.0, 1400.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('replacing another cloud workspace is confirmed at $width, '
            'text x$scale, ${locale.languageCode}', (tester) async {
          tester.view
            ..physicalSize = Size(width, 900)
            ..devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final account = AccountService();
          await account.signIn();
          final session = Session()
            ..results.addAll([
              AutoSyncResult(divergence: _otherWorkspace),
              const AutoSyncResult(),
            ]);
          final sync = AutoSyncController(
            accountService: account,
            settings: Settings(),
            changes: const Stream<void>.empty(),
            openSession: () async => session,
            apply: (_) async => true,
          );
          await tester.pumpWidget(
            MaterialApp(
              locale: locale,
              theme: AppTheme.create(Brightness.light),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: sync,
                  builder: (context, _) => ListView(
                    children: [
                      if (sync.divergence != null)
                        SyncDivergenceNotice(sync: sync),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 10));
          await tester.pump(const Duration(milliseconds: 10));
          final l = lookupAppLocalizations(locale);
          expect(find.text(l.autoSyncOtherWorkspace), findsOneWidget);
          expect(find.text(l.autoSyncDiverged), findsNothing);
          Future<void> keepLocal() async {
            await tester.tap(
              find.byKey(const ValueKey('google-sync-choose-version')),
            );
            await tester.pumpAndSettle();
            expect(find.text(l.autoSyncOtherWorkspaceHelp), findsOneWidget);
            expect(
              find.textContaining(l.autoSyncOtherTakeCloudEffect),
              findsOne,
            );
            // With large text the sheet scrolls to the options.
            final option = find.byKey(
              const ValueKey('app-choice-SyncDivergenceChoice.keepLocal'),
            );
            await tester.ensureVisible(option);
            await tester.pumpAndSettle();
            await tester.tap(option);
            await tester.pumpAndSettle();
            expect(find.text(l.autoSyncReplaceCloudTitle), findsOneWidget);
            expect(tester.takeException(), isNull);
          }

          // Cancelling the confirmation changes nothing.
          await keepLocal();
          await tester.ensureVisible(find.text(l.sshCancel));
          await tester.tap(find.text(l.sshCancel));
          await tester.pumpAndSettle();
          expect(session.resolved, isEmpty);
          expect(sync.divergence, isNotNull);
          await keepLocal();
          final replace = find.byKey(
            const ValueKey('google-sync-replace-cloud'),
          );
          await tester.ensureVisible(replace);
          await tester.tap(replace);
          await tester.pumpAndSettle();
          expect(session.resolved, [SyncDivergenceChoice.keepLocal]);
          expect(sync.divergence, isNull);
          await tester.runAsync(sync.stop);
          sync.dispose();
        });
      }
    }
  }

  for (final locale in AppLocalizations.supportedLocales) {
    for (final width in [390.0, 700.0, 1000.0, 1400.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'the version choice fits at $width, text x$scale, ${locale.languageCode}',
          (tester) async {
            tester.view
              ..physicalSize = Size(width, 900)
              ..devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final account = AccountService();
            await account.signIn();
            final session = Session()
              ..results.addAll([
                AutoSyncResult(divergence: _divergence),
                const AutoSyncResult(),
              ]);
            final sync = AutoSyncController(
              accountService: account,
              settings: Settings(),
              changes: const Stream<void>.empty(),
              openSession: () async => session,
              apply: (_) async => true,
            );
            await tester.pumpWidget(
              MaterialApp(
                locale: locale,
                theme: AppTheme.create(Brightness.light),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: ListenableBuilder(
                    listenable: sync,
                    builder: (context, _) => ListView(
                      children: [
                        if (sync.divergence != null)
                          SyncDivergenceNotice(sync: sync),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await tester.pump(const Duration(milliseconds: 10));
            await tester.pump(const Duration(milliseconds: 10));
            final l = lookupAppLocalizations(locale);
            expect(sync.phase, AutoSyncPhase.diverged);
            expect(find.text(l.autoSyncDiverged), findsOneWidget);
            await tester.tap(
              find.byKey(const ValueKey('google-sync-choose-version')),
            );
            await tester.pumpAndSettle();
            expect(find.text(l.autoSyncChooseTitle), findsOneWidget);
            expect(find.text(l.autoSyncKeepLocal), findsOneWidget);
            expect(find.text(l.autoSyncTakeCloud), findsOneWidget);
            // Both versions say when and on which device they were saved.
            expect(find.textContaining('Linux · desk'), findsOneWidget);
            expect(
              find.textContaining('· ${l.autoSyncThisDevice}'),
              findsOneWidget,
            );
            expect(find.textContaining(l.autoSyncTakeCloudEffect), findsOne);
            for (final key in [
              'app-choice-SyncDivergenceChoice.keepLocal',
              'app-choice-SyncDivergenceChoice.takeCloud',
            ]) {
              final size = tester.getSize(find.byKey(ValueKey(key)));
              expect(size.height, greaterThanOrEqualTo(48));
            }
            expect(tester.takeException(), isNull);
            // With large text the sheet scrolls to the second option.
            await tester.ensureVisible(
              find.byKey(
                const ValueKey('app-choice-SyncDivergenceChoice.takeCloud'),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(
                const ValueKey('app-choice-SyncDivergenceChoice.takeCloud'),
              ),
            );
            await tester.pumpAndSettle();
            expect(session.resolved, [SyncDivergenceChoice.takeCloud]);
            expect(sync.divergence, isNull);
            expect(find.text(l.autoSyncDiverged), findsNothing);
            await tester.runAsync(sync.stop);
            sync.dispose();
          },
        );
      }
    }
  }
}
