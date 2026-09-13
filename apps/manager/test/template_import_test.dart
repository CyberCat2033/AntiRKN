import 'dart:async';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/template_controller.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ProfileResult> preview(
    String text,
    List<ProxyDescriptor> nodes,
  ) async => const ProfileCompiler().preview(template: text, proxies: nodes);

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
