// Regressions for UI audit stage 4 (Material 3): UI-54…UI-70 and the
// component merges deferred from stage 3.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/ssh/protocol_removal.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'action_workflows_test.dart' show Repository;
import 'ssh_support.dart' as ssh;
import 'vpn_controller_test.dart' as vpn;

Widget _app(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: AppTheme.create(brightness),
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: child),
    );

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
}

/// Real fonts for screenshots; the test font draws boxes.
Future<void> _loadFonts(WidgetTester tester) => tester.runAsync(() async {
  for (final entry in {
    'Roboto': '/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf',
    'MaterialIcons':
        '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  }.entries) {
    final file = File(entry.value);
    if (!file.existsSync()) continue;
    await (FontLoader(
      entry.key,
    )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
  }
});

Future<void> _evidence(WidgetTester tester, GlobalKey key, String name) async {
  final dir = Platform.environment['ANTIRKN_UI_EVIDENCE'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File('$dir/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

/// The shared components in one place, for both themes.
Widget _gallery() => Builder(
  builder: (context) => ColoredBox(
    // The screenshot holds the page background too.
    color: Theme.of(context).scaffoldBackgroundColor,
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppPageIntro(
            'Introductory supporting text in the secondary role.',
          ),
          const Text('Body text: onSurface by default (UI-56).'),
          const SizedBox(height: 12),
          const AppNotice(message: 'An information notice.'),
          const AppNotice(message: 'A failure is announced.', error: true),
          AppNotice(
            icon: Icons.security_outlined,
            title: 'Recommended',
            message: 'A notice with a title and an action.',
            action: FilledButton.tonal(
              onPressed: () {},
              child: const Text('Act'),
            ),
          ),
          const Wrap(
            spacing: 8,
            children: [
              AppBadge(label: '3'),
              StatusChip(label: 'Connected', icon: Icons.check),
              StatusChip(label: 'Failed', icon: Icons.close, error: true),
            ],
          ),
          const SizedBox(height: 12),
          AppSettingsSection(
            title: 'Other components',
            child: Column(
              children: [
                SummaryCard(
                  embedded: true,
                  title: 'Xray',
                  subtitle: const Text('26.1.0'),
                  action: OutlinedButton(
                    onPressed: () {},
                    child: const Text('Update'),
                  ),
                ),
                const Divider(indent: 16, endIndent: 16),
                const ListTile(
                  title: Text('List tile'),
                  subtitle: Text('Supporting text in onSurfaceVariant'),
                ),
              ],
            ),
          ),
          SectionCard(title: 'Section', child: const Text('Padded content')),
          ResourceTile(
            title: 'VLESS · 443',
            subtitle: 'TCP · REALITY',
            details: const [],
            storageId: 'gallery',
            badge: 'Enabled',
            switchValue: true,
            onBadgeTap: () {},
            selected: true,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              AppDangerButton.text(
                onPressed: () {},
                child: const Text('Delete'),
              ),
              AppDangerButton(onPressed: () {}, child: const Text('Delete')),
              const AppDisabledReason(
                reason: 'The server is running another operation',
                child: FilledButton(onPressed: null, child: Text('Add')),
              ),
            ],
          ),
          const AppEmptyState(
            title: 'No servers',
            message: 'Empty state text in the secondary role.',
            icon: Icons.dns_outlined,
          ),
        ],
      ),
    ),
  ),
);

class _Counter extends StatefulWidget {
  const _Counter({required this.enabled});
  final bool enabled;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: widget.enabled ? () => setState(() => taps++) : null,
    child: Text('taps $taps'),
  );
}

void main() {
  group('UI-56 M3 type scale and text colours', () {
    for (final brightness in Brightness.values) {
      test('$brightness: M3 sizes, body text onSurface, AA contrast', () {
        final theme = AppTheme.create(brightness);
        final t = theme.textTheme, c = theme.colorScheme;
        expect(t.headlineSmall!.fontSize, 24);
        expect(t.titleLarge!.fontSize, 22);
        expect(t.titleMedium!.fontSize, 16);
        expect(t.bodyMedium!.fontSize, 14);
        expect(t.bodySmall!.fontSize, 12);
        expect(t.labelLarge!.fontSize, 14);
        expect(t.bodyMedium!.color, c.onSurface);
        expect(t.bodyLarge!.color, c.onSurface);
        expect(
          theme.listTileTheme.subtitleTextStyle!.color,
          c.onSurfaceVariant,
        );
        for (final surface in [
          c.surface,
          c.surfaceContainerLowest,
          c.surfaceContainerLow,
          c.surfaceContainer,
          c.surfaceContainerHigh,
        ]) {
          expect(_contrast(c.onSurface, surface), greaterThan(4.5));
          expect(_contrast(c.onSurfaceVariant, surface), greaterThan(4.5));
          expect(_contrast(c.primary, surface), greaterThan(3));
        }
        expect(
          _contrast(c.onErrorContainer, c.errorContainer),
          greaterThan(4.5),
        );
        expect(_contrast(c.onError, c.error), greaterThan(4.5));
        expect(
          _contrast(c.onSecondaryContainer, c.secondaryContainer),
          greaterThan(4.5),
        );
      });
    }

    for (final brightness in Brightness.values) {
      testWidgets('$brightness gallery renders without overflow', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(700, 1700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _loadFonts(tester);
        final key = GlobalKey();
        await tester.pumpWidget(
          _app(
            RepaintBoundary(key: key, child: _gallery()),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final context = tester.element(find.text('Padded content'));
        final scheme = Theme.of(context).colorScheme;
        // Plain body text inherits onSurface, not the muted variant.
        expect(DefaultTextStyle.of(context).style.color, scheme.onSurface);
        await _evidence(tester, key, 'stage4-gallery-${brightness.name}');
      });
    }
  });

  group('UI-57 errors', () {
    testWidgets('an error notice is a live region; margin is honoured', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          const Column(
            children: [
              AppNotice(message: 'boom', error: true, margin: EdgeInsets.zero),
              AppNotice(message: 'info'),
            ],
          ),
        ),
      );
      expect(
        tester.getSemantics(find.text('boom')),
        matchesSemantics(label: 'boom', isLiveRegion: true),
      );
      final error = find.ancestor(
        of: find.text('boom'),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.liveRegion == true,
        ),
      );
      expect(error, findsOneWidget);
      final info = find.ancestor(
        of: find.text('info'),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.liveRegion == true,
        ),
      );
      expect(info, findsNothing);
      expect(tester.getTopLeft(find.byType(AppNotice).first).dy, 0);
      handle.dispose();
    });
  });

  group('UI-55 destructive confirmations', () {
    testWidgets('confirm is filled in error colours; dismiss is "no"', (
      tester,
    ) async {
      bool? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await confirmAppDanger(
                context,
                title: 'Delete?',
                content: const Text('rich content'),
                confirmLabel: 'Delete',
                cancelLabel: 'Cancel',
                confirmKey: const ValueKey('confirm'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('rich content'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(const ValueKey('confirm')),
          matching: find.byType(FilledButton),
        ),
      );
      final scheme = Theme.of(tester.element(find.text('open'))).colorScheme;
      expect(button.style!.backgroundColor!.resolve({}), scheme.error);
      expect(button.style!.foregroundColor!.resolve({}), scheme.onError);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });

  group('UI-54 deleting a resource', () {
    testWidgets('VLESS form: a confirmed Delete button, no checkbox', (
      tester,
    ) async {
      final network = NetworkController(reader: const SampleInventoryReader());
      addTearDown(network.dispose);
      final c = vpn.controller(vpn.MemoryVpn(), {});
      addTearDown(c.dispose);
      await tester.runAsync(() => vpn.setup(c));
      final inbound = c.workspace.inbounds.first;
      VlessInbound? result;
      var closed = false;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<VlessInbound>(
                  context: context,
                  builder: (_) => InboundForm(
                    serverId: inbound.serverId,
                    network: network,
                    motion: MotionPreference.off,
                    inbound: inbound,
                  ),
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      final delete = find.byKey(const ValueKey('vpn-inbound-delete'));
      expect(delete, findsOneWidget);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      // Cancelling the confirmation keeps the form and deletes nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      expect(find.byType(InboundForm), findsOneWidget);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('vpn-inbound-delete-confirm')),
      );
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result!.deleted, isTrue);
      expect(result!.enabled, isFalse);
    });
  });

  group('UI-60 protocol removal', () {
    testWidgets('reachable from a "more" menu by mouse and keyboard', (
      tester,
    ) async {
      final repo = Repository(), connector = ssh.FakeConnector();
      final session = ssh.controller(repo.vault, connector, repository: repo),
          controller = vpn.controller(vpn.MemoryVpn(), {});
      await ssh.prepare(session);
      await session.save();
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Widget detail(Brightness brightness) => _app(
        Builder(
          builder: (context) => ServerDetailView(
            session: session,
            motion: MotionPreference.off,
            sections: [
              ServerProtocolSection(
                name: 'AmneziaWG',
                count: 0,
                mark: 'W',
                detected: true,
                onRemove: () => removeServerProtocol(
                  context,
                  session,
                  controller,
                  'amneziawg',
                  'AmneziaWG',
                ),
                child: const Text('interfaces'),
              ),
              ServerProtocolSection(
                name: 'TrustTunnel',
                count: 0,
                mark: 'T',
                detected: false,
                child: const Text('endpoints'),
              ),
            ],
          ),
        ),
        brightness: brightness,
      );
      await _loadFonts(tester);
      for (final brightness in Brightness.values) {
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(key: key, child: detail(brightness)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _evidence(tester, key, 'stage4-server-${brightness.name}');
      }
      final l = AppLocalizations.of(tester.element(find.text('AmneziaWG')));
      final menu = find.byKey(const ValueKey('protocol-menu-AmneziaWG'));
      expect(menu, findsOneWidget);
      expect(find.byTooltip(l.uiProtocolActions), findsOneWidget);
      // A protocol that is not installed has nothing to remove.
      expect(
        find.byKey(const ValueKey('protocol-menu-TrustTunnel')),
        findsNothing,
      );
      // Mouse.
      await tester.tap(menu);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('protocol-remove-AmneziaWG')));
      await tester.pump(const Duration(milliseconds: 400));
      // The item runs after the menu closes; its dialog needs a frame.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AppFormDialog), findsOneWidget);
      await tester.tap(find.text(l.sshCancel));
      await tester.pump(const Duration(milliseconds: 400));
      expect(connector.calls, 0);
      // Keyboard: focus the menu button, open it, choose the item.
      Focus.of(
        tester.element(find.descendant(of: menu, matching: find.byType(Icon))),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('protocol-remove-AmneziaWG')),
        findsOneWidget,
      );
      // The item is a focusable menu entry that Enter activates.
      final item = find.byKey(const ValueKey('protocol-remove-AmneziaWG'));
      Focus.of(
        tester.element(find.descendant(of: item, matching: find.byType(Text))),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AppFormDialog), findsOneWidget);
      await tester.tap(find.text(l.sshCancel));
      await tester.pump(const Duration(milliseconds: 400));
      expect(connector.calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      session.network.dispose();
      controller.dispose();
    });
  });

  group('UI-63 reasons for disabled controls', () {
    testWidgets('a tooltip only while held; the control keeps its state', (
      tester,
    ) async {
      final reason = ValueNotifier<String?>(null);
      addTearDown(reason.dispose);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<String?>(
            valueListenable: reason,
            builder: (context, value, _) => AppDisabledReason(
              reason: value,
              child: _Counter(enabled: value == null),
            ),
          ),
        ),
      );
      expect(find.byType(Tooltip), findsNothing);
      await tester.tap(find.text('taps 0'));
      await tester.pump();
      expect(find.text('taps 1'), findsOneWidget);
      reason.value = 'busy elsewhere';
      await tester.pump();
      expect(find.byTooltip('busy elsewhere'), findsOneWidget);
      // Reparented, not rebuilt: the count survives the reason.
      expect(find.text('taps 1'), findsOneWidget);
      reason.value = null;
      await tester.pump();
      expect(find.byType(Tooltip), findsNothing);
      expect(find.text('taps 1'), findsOneWidget);
    });
  });

  group('UI-53 merged components', () {
    testWidgets('one subheader style, sentence case; StatusChip is a badge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const Column(
            children: [
              AppSettingsSection(title: 'My data', child: SizedBox()),
              AppSectionHeading(title: 'Update available', subheader: true),
              StatusChip(label: 'ok', icon: Icons.check),
            ],
          ),
        ),
      );
      expect(find.text('MY DATA'), findsNothing);
      final a = tester.widget<Text>(find.text('My data')).style!;
      final b = tester.widget<Text>(find.text('Update available')).style!;
      expect(a, b);
      expect(
        find.descendant(
          of: find.byType(StatusChip),
          matching: find.byType(AppBadge),
        ),
        findsOneWidget,
      );
    });
  });
}
