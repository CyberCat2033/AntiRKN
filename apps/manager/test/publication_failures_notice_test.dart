import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/publication/publication_panel.dart';
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

  for (final locale in ['en', 'ru']) {
    testWidgets('clients notice names the count and reason in $locale', (
      tester,
    ) async {
      final c = await controller();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        _app(PublicationFailuresNotice(controller: c), locale: locale),
      );
      expect(find.byKey(const ValueKey('publication-failures')), findsNothing);

      c.queues[active.id] = {'status': 'error', 'issue': 'network'};
      c.queues[disabled.id] = {'status': 'error', 'issue': 'missing'};
      c.notifyListeners();
      await tester.pump();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l.publicationClientsFailed(1)), findsOneWidget);
      expect(find.text(l.publicationNetwork), findsOneWidget);
      expect(find.text(l.publicationRetry), findsOneWidget);

      c.queues[other.id] = {'status': 'error', 'issue': 'conflict'};
      c.notifyListeners();
      await tester.pump();
      expect(find.text(l.publicationClientsFailed(2)), findsOneWidget);
      expect(find.text(l.publicationClientsFailedMixed), findsOneWidget);
      await tester.pumpAndSettle();
    });
  }
}
