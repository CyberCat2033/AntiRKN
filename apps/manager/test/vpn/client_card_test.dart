import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/vpn/profile_share_sheet.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../vpn_controller_test.dart' as f;

class _Export implements ProfileExporter {
  @override
  Future<bool> save(String name, String source) async => true;
}

void main() {
  Future<VpnController> open(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = f.controller(f.MemoryVpn(), {});
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await c.load();
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
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
    // The row has no QR button: the row itself opens the card.
    expect(find.byKey(ValueKey('client-qr-${f.alice}')), findsNothing);
    await tester.tap(find.byKey(ValueKey('client-${f.alice}')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Durations.short2));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileShareSheet), findsOneWidget);
    return c;
  }

  testWidgets('on a phone the row opens the card as a bottom sheet; '
      'editing is one step in', (tester) async {
    await open(tester);
    expect(
      find.ancestor(
        of: find.byType(ProfileShareSheet),
        matching: find.byType(BottomSheet),
      ),
      findsOneWidget,
    );
    final edit = find.byKey(const ValueKey('client-card-edit'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('vpn-user-name')))
          .controller!
          .text,
      'Alice',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // The card stays open under the form.
    expect(find.byType(ProfileShareSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deleting from the card closes it with the client', (
    tester,
  ) async {
    final c = await open(tester);
    final delete = find.byKey(const ValueKey('client-card-delete'));
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('client-delete-confirm')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Durations.medium2));
    await tester.pumpAndSettle();
    expect(c.workspace.userById(f.alice)?.deleted ?? true, isTrue);
    expect(find.byType(ProfileShareSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a medium window the card is a dialog', (tester) async {
    await open(tester, width: 700);
    expect(
      find.ancestor(
        of: find.byType(ProfileShareSheet),
        matching: find.byType(Dialog),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('profile-close')), findsOneWidget);
  });

  testWidgets('the card fits a phone with text x2', (tester) async {
    await open(tester, scale: 2);
    final delete = find.byKey(const ValueKey('client-card-delete'));
    await tester.ensureVisible(delete);
    await tester.pumpAndSettle();
    expect(delete, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
