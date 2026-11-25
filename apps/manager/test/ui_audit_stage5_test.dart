// Regressions for UI audit stage 5: l10n, accessibility, dead code (UI-71…
// UI-75).
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/app_strings.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/publication/profile_link_qr.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' as f;

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  theme: AppTheme.create(Brightness.light),
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Scaffold(body: child),
);

class _Export implements ProfileExporter {
  @override
  Future<bool> save(String name, String source) async => true;
}

void main() {
  group('UI-71 dates and placeholders', () {
    testWidgets('dates follow the app language, not DateTime.toString', (
      tester,
    ) async {
      late AppLocalizations en, ru;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              en = AppLocalizations.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              ru = AppLocalizations.of(context);
              return const SizedBox();
            },
          ),
          locale: const Locale('ru'),
        ),
      );
      final at = DateTime(2026, 11, 25, 12, 34, 56);
      expect(en.formatDateTime(at), isNot(contains('.000')));
      expect(en.formatDateTime(at), contains('11/25/2026'));
      expect(ru.formatDateTime(at), contains('25.11.2026'));
      expect(ru.formatDateTime(at), contains('12:34'));
      expect(
        ru.formatEpochSeconds(at.millisecondsSinceEpoch / 1000),
        ru.formatDateTime(at),
      );
      expect(ru.egressCheckedAt('12', 'x'), contains('мс'));
      expect(en.egressCheckedAt('12', 'x'), contains('ms'));
    });
  });

  group('UI-73 accessibility', () {
    testWidgets('a form dialog title names its route and is a heading', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          const AppFormDialog(title: Text('Edit client'), content: Text('x')),
        ),
      );
      expect(
        tester.getSemantics(find.text('Edit client')),
        matchesSemantics(
          label: 'Edit client',
          isHeader: true,
          namesRoute: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a page title is a heading', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(const AppPageTitle('Settings')));
      expect(
        tester.getSemantics(find.text('Settings')),
        matchesSemantics(label: 'Settings', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('the client switch names its client', (tester) async {
      final handle = tester.ensureSemantics();
      final c = f.controller(f.MemoryVpn(), {});
      addTearDown(c.dispose);
      await tester.runAsync(() async {
        await c.load();
        await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      });
      await tester.pumpWidget(
        _app(
          UsersPage(
            controller: c,
            serverName: (s) => s,
            exporter: _Export(),
            motion: MotionPreference.off,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('Access for Alice')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the QR button is announced once and shows keyboard focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          ProfileLinkQr(
            url: 'https://example.invalid/profile.yml',
            beforeCopy: () async {},
          ),
        ),
      );
      final l = AppLocalizations.of(tester.element(find.byType(ProfileLinkQr)));
      final node = tester.getSemantics(
        find.byKey(const ValueKey('profile-link-qr')),
      );
      // One label, not the Semantics label plus the tooltip's.
      expect(node.label, l.publicationCopyLink);
      expect(node.tooltip, isEmpty);
      BoxBorder? border() =>
          (tester
                      .widget<DecoratedBox>(
                        find
                            .ancestor(
                              of: find.byKey(const ValueKey('profile-link-qr')),
                              matching: find.byType(DecoratedBox),
                            )
                            .first,
                      )
                      .decoration
                  as BoxDecoration)
              .border;
      expect(border(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(border(), isNotNull);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });
  });

  group('UI-74 dead details', () {
    testWidgets('a resource without details shows no details button', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const ResourceTile(
            title: 'One',
            subtitle: 'Two',
            storageId: 'x',
            badge: 'Enabled',
          ),
        ),
      );
      expect(find.byKey(const ValueKey('resource-details-x')), findsNothing);
    });
  });

  group('UI-75 clients of one server', () {
    test('a server without client protocols serves no clients', () async {
      final c = f.controller(f.MemoryVpn(), {});
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      await c.saveUser(
        VpnUser(id: f.bob, login: 'bob', name: 'Bob', enabled: false),
      );
      await c.saveInbound(f.inbound('one', '1' * 32));
      expect(c.error, isNull);
      expect(c.clientCountOn('one'), 1);
      expect(c.clientCountOn('two'), 0);
    });
  });
}
