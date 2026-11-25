import 'dart:convert';
import 'dart:async';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/template_settings.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'core_config_check_test.dart' as core;
import 'awg_test.dart' as awg;
import 'tt_test.dart' as tt;

import 'vpn_controller_test.dart' as f;

String customTemplate(String domain) => f.template.replaceFirst(
  '"MATCH,ALL"',
  '"DOMAIN-SUFFIX,$domain,ALL","MATCH,ALL"',
);

void main() {
  test(
    'individual config works before a shared base config is selected',
    () async {
      final c = f.controller(f.MemoryVpn(), {}, source: () => '');
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(
        VpnUser(
          id: f.alice,
          login: 'alice',
          name: 'Alice',
          baseTemplate: customTemplate('alice.example'),
        ),
      );
      expect(c.results[f.alice]!.hasBlockingErrors, isFalse);
      expect(c.results[f.alice]!.yaml, contains('alice.example'));
    },
  );

  test(
    'offline forgetting retires all protocols and interrupted revocations without SSH',
    () async {
      final targets = ['one', awgTarget('one'), ttTarget('one')];
      final store = f.MemoryVpn()
        ..raw = VpnWorkspace(
          id: 'f' * 32,
          users: [
            VpnUser(
              id: f.alice,
              login: 'alice',
              name: 'Alice',
              baseTemplate: customTemplate('alice.example'),
            ),
            VpnUser(
              id: f.bob,
              login: 'bob',
              name: 'Bob',
              enabled: false,
              baseTemplate: customTemplate('bob.example'),
              deletion: {
                'version': 1,
                'id': 'e' * 32,
                'targets': {
                  for (final target in targets) target: {'status': 'running'},
                },
              },
            ),
          ],
          inbounds: [f.inbound('one', '1' * 32)],
          awgInterfaces: [AwgInterface(serverId: 'one', spec: awg.spec())],
          ttEndpoints: [
            TrustTunnelEndpoint(
              serverId: 'one',
              spec: {...tt.spec(), 'id': 'c' * 32},
            ),
          ],
          servers: {
            for (final target in targets)
              target: {
                'cancelRequested': true,
                'authorizedPayload': 'interrupted',
                'pending': {'id': '2' * 32},
              },
          },
        ).encode();
      final c = VpnController(
        repository: store,
        remote: (_) =>
            throw StateError('No SSH lookup is needed for local forgetting'),
        template: () => f.template,
        timer: (_, _) => Timer(Duration.zero, () {}),
      );
      addTearDown(c.dispose);
      await c.load();
      expect(await c.forgetServersLocally({'one'}), isTrue);
      expect(c.workspace.inbounds.single.deleted, isTrue);
      expect(c.workspace.awgInterfaces.single.deleted, isTrue);
      expect(c.workspace.ttEndpoints.single.deleted, isTrue);
      expect(c.workspace.serverIds, isEmpty);
      expect(c.hasRunning, isFalse);
      final deleted = c.workspace.users.last;
      expect(deleted.revocationComplete, isFalse);
      expect(deleted.revocationSettled, isTrue);
      expect(deleted.baseTemplate, customTemplate('bob.example'));
      expect(c.results[f.alice]!.hasBlockingErrors, isFalse);
      expect(c.results[f.alice]!.yaml, contains('alice.example'));
      final persisted = VpnWorkspace.decode(store.raw!);
      expect(persisted.serverIds, isEmpty);
      expect(persisted.users.last.revocationSettled, isTrue);
    },
  );

  for (final language in ['en', 'ru']) {
    testWidgets(
      'client YAML selection, cancel and shared fallback on narrow large text: $language',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        var pickCount = 0;
        final store = f.MemoryVpn();
        final remotes = {'one': f.Remote(store), 'two': f.Remote(store)};
        VpnController createController() => VpnController(
          repository: store,
          template: () => f.template,
          pickTemplate: () async => ++pickCount == 1
              ? ImportedTemplate(
                  name: 'alice.yaml',
                  source: customTemplate('alice.example'),
                )
              : null,
          remote: (id) => remotes[id] == null
              ? null
              : VpnRemote(
                  transport: remotes[id]!,
                  panelId: f.panel,
                  identity: 'identity-$id',
                ),
          timer: (_, _) => Timer(Duration.zero, () {}),
        );
        late final VpnController c;
        await tester.runAsync(() async {
          c = createController();
          await f.setup(c);
          await c.prepareAndApply();
        });
        addTearDown(c.dispose);
        for (final remote in remotes.values) {
          remote.actions.clear();
        }
        Future<void>? editing;
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
              body: Builder(
                builder: (context) => TextButton(
                  key: const ValueKey('edit-client'),
                  onPressed: () => editing = UsersPage.edit(
                    context,
                    c,
                    MotionPreference.off,
                    c.workspace.users.first,
                  ),
                  child: const Text('Edit'),
                ),
              ),
            ),
          ),
        );
        Future<void> open() async {
          await tester.runAsync(
            () => tester.tap(find.byKey(const ValueKey('edit-client'))),
          );
          await tester.pumpAndSettle();
        }

        Future<void> save() async {
          // The form stores the client before it closes (UI-01), so the save
          // itself needs real async time, like opening the form does.
          await tester.runAsync(
            () => tester.tap(find.byKey(const ValueKey('vpn-user-save'))),
          );
          for (
            var i = 0;
            i < 300 &&
                find
                    .byKey(const ValueKey('vpn-user-save'))
                    .evaluate()
                    .isNotEmpty;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          await tester.runAsync(() => editing!);
          await tester.pumpAndSettle();
        }

        Future<void> pick() async {
          await tester.ensureVisible(
            find.byKey(const ValueKey('import-template')),
          );
          await tester.tap(find.byKey(const ValueKey('import-template')));
          final draft = tester
              .widget<TemplateSettings>(find.byType(TemplateSettings))
              .controller;
          await tester.runAsync(() async {
            for (var i = 0; i < 100 && (draft.importing || draft.busy); i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
          await tester.pumpAndSettle();
          expect(draft.importing || draft.busy, isFalse);
        }

        await open();
        await tester.tap(
          find.byKey(const ValueKey('vpn-user-individual-template')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('vpn-user-save')));
        await tester.pumpAndSettle();
        expect(find.byType(TemplateSettings), findsOneWidget);
        await pick();
        await save();
        expect(
          c.workspace.users.first.baseTemplate,
          customTemplate('alice.example'),
        );
        expect(c.results[f.alice]!.yaml, contains('alice.example'));
        expect(remotes.values.every((r) => r.actions.isEmpty), isTrue);
        await open();
        expect(find.text('alice.yaml'), findsOneWidget);
        await pick();
        await save();
        expect(c.workspace.users.first.baseTemplateName, 'alice.yaml');
        await open();
        await tester.tap(
          find.byKey(const ValueKey('vpn-user-individual-template')),
        );
        await tester.pumpAndSettle();
        await save();
        expect(c.workspace.users.first.baseTemplate, isNull);
        expect(c.results[f.alice]!.yaml, isNot(contains('alice.example')));
        expect(tester.takeException(), isNull);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  test(
    'forget lost server clears failed verification and keeps individual config',
    () async {
      final store = f.MemoryVpn();
      final remotes = {'one': f.Remote(store), 'two': f.Remote(store)};
      final c = f.controller(store, remotes);
      addTearDown(c.dispose);
      await f.setup(c);
      await c.prepareAndApply();
      await c.saveUser(
        VpnUser(
          id: f.alice,
          login: 'alice',
          name: 'Alice',
          baseTemplate: customTemplate('alice.example'),
        ),
      );
      remotes['one']!.failState = true;
      expect((await c.syncAllServersAndProfiles()).verified, isFalse);
      expect(c.serverSyncIssue, isNotNull);
      remotes.remove('one');
      remotes['two']!.actions.clear();
      expect(await c.forgetServersLocally({'one'}), isTrue);
      expect(c.serverSyncIssue, isNull);
      expect(
        c.workspace.users.first.baseTemplate,
        customTemplate('alice.example'),
      );
      expect(c.results[f.alice]!.yaml, contains('alice.example'));
      expect(c.results[f.alice]!.yaml, isNot(contains('Server one')));
      expect(c.hasCurrentVerifiedProfiles, isTrue);
      expect(
        (await c.syncAllServersAndProfiles(
          allowVerifiedSnapshot: true,
        )).usedSavedVerification,
        isTrue,
      );
      expect(remotes['two']!.actions, isEmpty);
    },
  );

  test(
    'individual templates compile independently and keep credentials',
    () async {
      final store = f.MemoryVpn();
      final remotes = {'one': f.Remote(store), 'two': f.Remote(store)};
      var shared = f.template;
      final validator = core.Validator();
      final c = f.controller(
        store,
        remotes,
        source: () => shared,
        coreValidator: validator,
      );
      addTearDown(c.dispose);
      await f.setup(c);
      await c.prepareAndApply();
      final desired = canonicalJson(c.workspace.desired('one', f.panel));
      final credentials = RegExp(r'^\s*uuid:.*$', multiLine: true);
      final aliceProxy = credentials
          .allMatches(c.results[f.alice]!.yaml!)
          .map((m) => m.group(0))
          .toList();
      expect(aliceProxy, isNotEmpty);
      final bobHash = c.results[f.bob]!.sha256Hash;
      for (final remote in remotes.values) {
        remote.actions.clear();
        remote.failPlan = true;
        remote.failState = true;
      }
      await c.saveUser(
        VpnUser(
          id: f.alice,
          login: 'alice',
          name: 'Alice',
          baseTemplate: customTemplate('alice.example'),
          baseTemplateName: 'alice.yaml',
        ),
      );
      expect(c.error, isNull);
      expect(c.results[f.alice]!.yaml, contains('alice.example'));
      expect(c.results[f.bob]!.sha256Hash, bobHash);
      expect(c.results[f.bob]!.yaml, isNot(contains('alice.example')));
      expect(
        credentials
            .allMatches(c.results[f.alice]!.yaml!)
            .map((m) => m.group(0))
            .toList(),
        aliceProxy,
      );
      expect(canonicalJson(c.workspace.desired('one', f.panel)), desired);
      expect(c.hasCurrentVerifiedProfiles, isTrue);
      final sync = await c.syncAllServersAndProfiles(
        allowVerifiedSnapshot: true,
      );
      expect(sync.usedSavedVerification, isTrue);
      expect(remotes.values.every((r) => r.actions.isEmpty), isTrue);
      await c.validateCoreProfile(f.alice);
      expect(validator.yaml, contains('alice.example'));
      expect(validator.yaml, c.results[f.alice]!.yaml);

      final individualHash = c.results[f.alice]!.sha256Hash;
      shared = customTemplate('shared.example');
      await c.refreshProfiles();
      expect(c.results[f.alice]!.sha256Hash, individualHash);
      expect(c.results[f.bob]!.yaml, contains('shared.example'));

      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      expect(c.results[f.alice]!.yaml, contains('shared.example'));
      expect(c.results[f.alice]!.sha256Hash, isNot(individualHash));
      final reopened = f.controller(store, remotes, source: () => shared);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.workspace.users.first.baseTemplate, isNull);
    },
  );

  test(
    'bad individual YAML blocks only its client and retains the last valid profile',
    () async {
      final store = f.MemoryVpn();
      final c = f.controller(store, {});
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      await c.saveUser(VpnUser(id: f.bob, login: 'bob', name: 'Bob'));
      final oldProfile = c.workspace.profiles[f.alice];
      await c.saveUser(
        VpnUser(
          id: f.alice,
          login: 'alice',
          name: 'Alice',
          baseTemplate: 'rules: [',
        ),
      );
      await c.refreshProfiles();
      expect(c.results[f.alice]!.hasBlockingErrors, isTrue);
      expect(c.results[f.bob]!.hasBlockingErrors, isFalse);
      expect(c.workspace.profiles[f.alice], oldProfile);
    },
  );

  test('individual base config is versioned and validates UTF-8 limits', () {
    final user = VpnUser(
      id: f.alice,
      login: 'alice',
      name: 'Alice',
      baseTemplate: f.template,
      baseTemplateName: 'base.yaml',
    );
    expect(
      VpnUser.fromJson(
        jsonDecode(jsonEncode(user.toJson())) as Map<String, dynamic>,
      ).baseTemplate,
      f.template,
    );
    expect(
      () => VpnUser.fromJson({
        ...user.toJson(),
        'baseConfig': {'version': 2, 'source': f.template},
      }),
      throwsFormatException,
    );
    expect(
      () => VpnUser(
        id: f.alice,
        login: 'alice',
        name: 'Alice',
        baseTemplate: 'я' * (128 * 1024 + 1),
      ),
      throwsFormatException,
    );
  });
}
