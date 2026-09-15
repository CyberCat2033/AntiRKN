import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/vpn/vpn_plan_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as f;

void main() {
  testWidgets(
    'expanded content can appear late and reopen with editable text',
    (tester) async {
      final bucket = PageStorageBucket();
      final input = TextEditingController(text: 'draft');
      addTearDown(input.dispose);
      var visible = true, loaded = false;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return PageStorage(
                  bucket: bucket,
                  child: visible
                      ? ListView(
                          key: const PageStorageKey('settings'),
                          children: [
                            AppExpansionTile(
                              key: const PageStorageKey('account'),
                              title: const Text('Account'),
                              children: [
                                if (loaded) ...[
                                  const SelectableText('fixture@example.com'),
                                  TextField(controller: input),
                                ],
                              ],
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      rebuild(() => loaded = true);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'edited draft');
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      rebuild(() => visible = false);
      await tester.pumpAndSettle();
      rebuild(() => visible = true);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('fixture@example.com').hitTestable(), findsOneWidget);
      expect(find.text('edited draft'), findsOneWidget);
    },
  );

  testWidgets('scroll offset and late snapshot expansion have separate state', (
    tester,
  ) async {
    final vpn = f.controller(f.MemoryVpn(), {});
    addTearDown(vpn.dispose);
    final bucket = PageStorageBucket();
    var visible = true;
    var ready = false;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return PageStorage(
                bucket: bucket,
                child: visible
                    ? ListView(
                        key: const PageStorageKey('protocols'),
                        children: [
                          const SizedBox(height: 350),
                          if (ready) ...[
                            VpnJobView(controller: vpn, serverId: 'one'),
                            VpnJobView(controller: vpn, serverId: 'awg:one'),
                            const ResourceTile(
                              storageId: 'one',
                              title: 'First',
                              subtitle: 'VLESS',
                              details: [Text('First details')],
                            ),
                            const ResourceTile(
                              storageId: 'two',
                              title: 'Second',
                              subtitle: 'VLESS',
                              details: [Text('Second details')],
                            ),
                          ],
                          const SizedBox(height: 1500),
                        ],
                      )
                    : const SizedBox.shrink(),
              );
            },
          ),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final offset = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;
    expect(offset, greaterThan(0));
    vpn.workspace = vpn.workspace.copy(
      servers: {
        'one': {'verifiedAt': '2026-09-15T00:00:00Z'},
        'awg:one': {'verifiedAt': '2026-09-14T00:00:00Z'},
      },
    );
    rebuild(() => ready = true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('First'));
    await tester.pumpAndSettle();
    expect(find.text('First details').hitTestable(), findsOneWidget);
    expect(find.text('Second details').hitTestable(), findsNothing);
    rebuild(() => visible = false);
    await tester.pumpAndSettle();
    rebuild(() => visible = true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      offset,
    );
    expect(find.text('First details').hitTestable(), findsOneWidget);
    expect(find.text('Second details').hitTestable(), findsNothing);
  });
}
