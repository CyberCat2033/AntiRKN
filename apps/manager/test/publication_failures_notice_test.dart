import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/publication/publication_panel.dart';
import 'package:antirkn_manager/vpn/clients_status_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'publication_binding_dialog_test.dart' show Controller;

const _settings = PublicationSettings(
  accountKey: 'account',
  folderId: 'folder',
  folderName: 'Folder',
  access: PublicationAccess.link,
);

Widget _app(Widget child, {String locale = 'en'}) => MaterialApp(
  locale: Locale(locale),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  final active = VpnUser(id: 'a' * 32, login: 'active', name: 'Active');
  final other = VpnUser(id: 'b' * 32, login: 'other', name: 'Other');
  final disabled = VpnUser(
    id: 'c' * 32,
    login: 'disabled',
    name: 'Disabled',
    enabled: false,
  );

  Future<Controller> controller() async {
    final c = Controller();
    await c.ready;
    c.vpn.workspace = c.vpn.workspace.copy(users: [active, other, disabled]);
    c.settings = _settings;
    return c;
  }

  test('a disabled client stored failure is not a current one', () async {
    final c = await controller();
    addTearDown(c.dispose);
    c.queues[disabled.id] = {'status': 'error', 'issue': 'network'};
    expect(c.publicationErrorUserIds, isEmpty);
    c.queues[active.id] = {'status': 'error', 'issue': 'network'};
    c.queues[other.id] = {'status': 'published'};
    expect(c.publicationErrorUserIds, [active.id]);
  });

  testWidgets('settings no longer show a bare retry for client failures', (
    tester,
  ) async {
    final c = await controller();
    addTearDown(c.dispose);
    c.queues[active.id] = {'status': 'error', 'issue': 'network'};
    await tester.pumpWidget(_app(PublicationSettingsPanel(controller: c)));
    final l = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    expect(find.text(l.runnerRetry), findsNothing);
    expect(find.text(l.publicationRetry), findsNothing);
    await tester.pumpAndSettle();
  });

  Widget card(Controller c, {bool access = true, bool syncing = false}) =>
      ClientsStatusCard(
        vpn: c.vpn,
        publications: c,
        hasAccess: access,
        syncing: syncing,
        motion: MotionPreference.off,
        onShowFailed: () {},
      );

  for (final locale in ['en', 'ru']) {
    testWidgets(
      'clients status names the count, clients and reason in $locale',
      (tester) async {
        final c = await controller();
        addTearDown(c.dispose);
        await tester.pumpWidget(_app(card(c), locale: locale));
        expect(
          find.byKey(const ValueKey('publication-failures')),
          findsNothing,
        );

        c.queues[active.id] = {'status': 'error', 'issue': 'network'};
        c.queues[disabled.id] = {'status': 'error', 'issue': 'missing'};
        c.notifyListeners();
        await tester.pump();
        final l = AppLocalizations.of(tester.element(find.byType(Scaffold)));
        expect(find.text(l.publicationClientsFailed(1)), findsOneWidget);
        expect(find.text('Active · ${l.publicationNetwork}'), findsOneWidget);
        expect(find.text(l.publicationRetry), findsOneWidget);
        // A Drive issue is the same for all: no client to single out.
        expect(
          find.byKey(const ValueKey('publication-failures-show')),
          findsNothing,
        );

        c.queues[other.id] = {'status': 'error', 'issue': 'conflict'};
        c.notifyListeners();
        await tester.pump();
        expect(find.text(l.publicationClientsFailed(2)), findsOneWidget);
        expect(find.text('Active, Other'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('publication-failures-show')),
          findsOneWidget,
        );
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('clients status puts the most pressing state first', (
    tester,
  ) async {
    final c = await controller();
    addTearDown(c.dispose);
    c.queues[other.id] = {'status': 'error', 'issue': 'conflict'};
    Future<void> show({bool access = true, bool syncing = false}) async {
      await tester.pumpWidget(_app(card(c, access: access, syncing: syncing)));
      await tester.pump();
    }

    Finder byKey(String key) => find.byKey(ValueKey(key));

    // Nowhere to connect is said on its own, beside the passing state.
    await show(access: false);
    expect(byKey('vpn-clients-no-access'), findsOneWidget);
    expect(byKey('publication-failures'), findsOneWidget);

    await show(syncing: true);
    expect(byKey('clients-sync-progress'), findsOneWidget);
    expect(byKey('publication-failures'), findsNothing);

    c.error = PublicationIssue.unauthorized;
    await show();
    expect(byKey('clients-sign-in'), findsOneWidget);
    expect(byKey('clients-sign-in-action'), findsOneWidget);
    expect(byKey('publication-failures'), findsNothing);

    c.error = null;
    await show();
    expect(byKey('publication-failures'), findsOneWidget);

    c.queues.clear();
    c.notifyListeners();
    await tester.pump();
    expect(byKey('publication-failures'), findsNothing);
    await tester.pumpAndSettle();
  });
}
