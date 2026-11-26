import 'dart:async';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/template_controller.dart';
import 'package:antirkn_manager/template_settings.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ProfileResult> preview(
    String text,
    List<ProxyDescriptor> nodes,
  ) async => const ProfileCompiler().preview(template: text, proxies: nodes);

  test(
    'latest draft persists across a new controller; save errors retain draft and retry works',
    () async {
      final store = _Drafts();
      final c = TemplateController(
        source: '',
        previewTemplate: preview,
        draftStore: store,
      );
      c.edit('first');
      c.edit('latest');
      await c.persistDraft();
      expect(await store.readDraft(), 'latest');
      store.fail = true;
      c.edit('retry me');
      await c.persistDraft();
      expect(c.draftSaveFailed, isTrue);
      expect(c.source, 'retry me');
      expect(await store.readDraft(), 'latest');
      store.fail = false;
      await c.persistDraft();
      expect(c.draftSaveFailed, isFalse);
      c.dispose();
      final reopened = TemplateController(
        source: (await store.readDraft())!,
        previewTemplate: preview,
      );
      expect(reopened.source, 'retry me');
      reopened.dispose();
    },
  );

  test(
    'cancel and read failures retain edited source and previous preview',
    () async {
      Object? failure;
      final controller = TemplateController(
        source: 'proxies: []',
        previewTemplate: preview,
        pickTemplate: () async {
          if (failure != null) throw failure;
          return null;
        },
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final previous = controller.result;
      controller.edit('proxies: []\n# unsaved');
      for (final error in [
        null,
        StateError('read'),
        const FormatException('template_size_limit'),
      ]) {
        failure = error;
        await controller.importFile();
        expect(controller.source, 'proxies: []\n# unsaved');
        expect(controller.result, same(previous));
        expect(controller.stale, isTrue);
        expect(controller.importing, isFalse);
        expect(
          controller.importError,
          error == null
              ? null
              : error is FormatException
              ? 'template_size_limit'
              : 'template_read_error',
        );
      }
    },
  );

  test(
    'selected content replaces draft and preview, including invalid YAML',
    () async {
      var selected = const ImportedTemplate(
        name: 'custom.yaml',
        source: 'proxies: []\n# imported',
      );
      final controller = TemplateController(
        source: 'proxies: []',
        previewTemplate: preview,
        pickTemplate: () async => selected,
      );
      addTearDown(controller.dispose);
      await controller.importFile();
      expect(controller.source, selected.source);
      expect(controller.importedName, selected.name);
      expect(controller.stale, isFalse);
      final previous = controller.result;
      selected = const ImportedTemplate(
        name: 'broken.yml',
        source: 'proxies: [',
      );
      await controller.importFile();
      expect(controller.source, 'proxies: [');
      expect(controller.result, isNot(same(previous)));
      expect(
        controller.result!.diagnostics.map((d) => d.code),
        contains('invalid_yaml'),
      );
      expect(controller.importError, isNull);
      controller.edit('proxies: []');
      expect(selected.source, 'proxies: [');
    },
  );

  test('a file the core rejects never replaces the base config', () async {
    final store = _Drafts();
    final core = _Core(CoreConfigStatus.invalid, 'core_rejected');
    final controller = TemplateController(
      source: 'proxies: []',
      previewTemplate: preview,
      draftStore: store,
      coreValidator: core,
      pickTemplate: () async =>
          const ImportedTemplate(name: 'bad.yaml', source: 'rules: [BAD]'),
    )..importedName = 'current.yaml';
    addTearDown(controller.dispose);
    await controller.importFile();
    expect(core.yaml, 'rules: [BAD]');
    expect(controller.source, 'proxies: []');
    expect(controller.importedName, 'current.yaml');
    expect(controller.coreRejection, 'core_rejected');
    expect(controller.coreCheck, isNull);
    expect(controller.importing, isFalse);
    expect(controller.coreChecking, isFalse);
    expect(await store.readDraft(), isNull);
  });

  test(
    'accepted and unchecked files are added with the core verdict',
    () async {
      for (final (core, status) in [
        (_Core(CoreConfigStatus.valid, 'valid'), CoreConfigStatus.valid),
        (
          _Core(CoreConfigStatus.incomplete, 'provider_content'),
          CoreConfigStatus.incomplete,
        ),
        (_Core.throwing(), CoreConfigStatus.unavailable),
      ]) {
        final controller = TemplateController(
          source: 'proxies: []',
          previewTemplate: preview,
          coreValidator: core,
          pickTemplate: () async =>
              const ImportedTemplate(name: 'new.yaml', source: 'mode: rule'),
        );
        await controller.importFile();
        expect(controller.source, 'mode: rule');
        expect(controller.coreRejection, isNull);
        expect(controller.coreCheck?.status, status);
        controller.edit('mode: global');
        expect(controller.coreCheck, isNull, reason: 'edited after the check');
        controller.dispose();
      }
    },
  );

  test('disposal cancels a running core check', () async {
    final core = _Core(CoreConfigStatus.valid, 'valid')
      ..hold = Completer<void>();
    final controller = TemplateController(
      source: 'original',
      previewTemplate: preview,
      coreValidator: core,
      pickTemplate: () async =>
          const ImportedTemplate(name: 'new.yaml', source: 'new'),
    );
    final pending = controller.importFile();
    await Future<void>.delayed(Duration.zero);
    expect(controller.coreChecking, isTrue);
    controller.dispose();
    expect(core.token!.isCancelled, isTrue);
    core.hold!.complete();
    await pending;
    expect(controller.source, 'original');
  });

  for (final locale in ['en', 'ru']) {
    testWidgets('core verdict on an added file is shown, $locale x2', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var core = _Core(CoreConfigStatus.invalid, 'core_rejected');
      final controller = TemplateController(
        source: 'proxies: []',
        previewTemplate: preview,
        coreValidator: _Delegate(() => core),
        pickTemplate: () async =>
            const ImportedTemplate(name: 'new.yaml', source: 'mode: rule'),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TemplateSettings(controller: controller),
            ),
          ),
        ),
      );
      final l = lookupAppLocalizations(Locale(locale));
      await tester.tap(find.byKey(const ValueKey('import-template')));
      await tester.pumpAndSettle();
      expect(find.text(l.templateCoreRejected), findsOneWidget);
      expect(controller.source, 'proxies: []');
      core = _Core(CoreConfigStatus.valid, 'valid');
      await tester.tap(find.byKey(const ValueKey('import-template')));
      await tester.pumpAndSettle();
      expect(find.text(l.templateCoreRejected), findsNothing);
      expect(find.text(l.templateCoreValid), findsOneWidget);
      expect(find.text('new.yaml'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'pending picker rejects duplicate requests and disposal discards its result',
    () async {
      final selected = Completer<ImportedTemplate?>();
      var calls = 0;
      final controller = TemplateController(
        source: 'original',
        previewTemplate: preview,
        pickTemplate: () {
          calls++;
          return selected.future;
        },
      );
      final pending = controller.importFile();
      await controller.importFile();
      expect(calls, 1);
      expect(controller.importing, isTrue);
      controller.dispose();
      selected.complete(const ImportedTemplate(name: 'new.yml', source: 'new'));
      await pending;
      expect(controller.source, 'original');
    },
  );
}

class _Core implements CoreConfigValidator {
  _Core(this.status, this.code) : fail = false;
  _Core.throwing()
    : status = CoreConfigStatus.valid,
      code = 'valid',
      fail = true;
  final CoreConfigStatus status;
  final String code;
  final bool fail;
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
    if (fail) throw StateError('native');
    return CoreConfigCheck(
      status: status,
      code: code,
      profileHash: 'fixture',
      checkedAt: DateTime.now().toUtc(),
    );
  }
}

class _Delegate implements CoreConfigValidator {
  _Delegate(this.current);
  final CoreConfigValidator Function() current;
  @override
  Future<CoreConfigCheck> validate(String yaml, CancellationToken token) =>
      current().validate(yaml, token);
}

class _Drafts implements TemplateDraftStore {
  String? text;
  bool fail = false;
  @override
  Future<String?> readDraft() async => text;
  @override
  Future<void> writeDraft(String source) async {
    if (fail) throw StateError('fixture');
    text = source;
  }
}
