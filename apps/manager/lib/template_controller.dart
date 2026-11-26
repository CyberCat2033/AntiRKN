import 'dart:async';

import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

typedef PreviewTemplate =
    Future<ProfileResult> Function(String, List<ProxyDescriptor>);

Future<ProfileResult> previewInBackground(
  String source,
  List<ProxyDescriptor> nodes,
) => compute(_preview, (source, nodes));

ProfileResult _preview((String, List<ProxyDescriptor>) input) =>
    const ProfileCompiler().preview(template: input.$1, proxies: input.$2);

class TemplateController extends ChangeNotifier {
  TemplateController({
    required this.source,
    required this.previewTemplate,
    this.pickTemplate,
    this.draftStore,
    this.coreValidator,
  });
  final TemplateDraftStore? draftStore;
  bool savingDraft = false;
  bool draftSaveFailed = false;
  int _draftRevision = 0;
  Future<void> _draftWrites = Future.value();
  final PreviewTemplate previewTemplate;
  final Future<ImportedTemplate?> Function()? pickTemplate;

  /// Checks an added base config with the client core before it is accepted.
  final CoreConfigValidator? coreValidator;

  /// The core's verdict on the accepted file, while it is the current source.
  CoreConfigCheck? coreCheck;

  /// Why the core rejected the last picked file; the source was kept.
  String? coreRejection;
  bool coreChecking = false;
  CancellationToken? _coreToken;
  String source;
  String? importedName;
  String? importError;
  bool importing = false;
  ProfileResult? result;
  bool busy = false;
  bool stale = true;
  bool failed = false;
  int _revision = 0;
  bool _disposed = false;

  void edit(String value) {
    source = value;
    coreCheck = null;
    persistDraft();
    _changed();
  }

  Future<void> importFile() async {
    if (importing || busy || pickTemplate == null) return;
    importing = true;
    importError = null;
    coreRejection = null;
    notifyListeners();
    try {
      final imported = await pickTemplate!();
      if (_disposed || imported == null) return;
      final check = await _checkCore(imported.source);
      if (_disposed) return;
      // A file the core rejects never replaces the current base config: every
      // client profile is built from it.
      if (check?.status == CoreConfigStatus.invalid) {
        coreRejection = check!.code;
        return;
      }
      coreCheck = check;
      // The selected content becomes an independent in-memory editor draft.
      source = imported.source;
      importedName = imported.name;
      persistDraft();
      _changed();
      await refresh();
    } on FormatException catch (e) {
      if (!_disposed) {
        importError = e.message == 'template_size_limit'
            ? e.message
            : 'template_read_error';
      }
    } catch (_) {
      if (!_disposed) importError = 'template_read_error';
    } finally {
      if (!_disposed) {
        importing = false;
        notifyListeners();
      }
    }
  }

  Future<CoreConfigCheck?> _checkCore(String yaml) async {
    final validator = coreValidator;
    if (validator == null) return null;
    final token = _coreToken = CancellationToken();
    coreChecking = true;
    notifyListeners();
    try {
      return await validator.validate(yaml, token);
    } catch (e) {
      // A failed check is not a verdict on the file: it is added unchecked.
      debugPrint('template_core_check_failed type=${e.runtimeType}');
      return CoreConfigCheck(
        status: CoreConfigStatus.unavailable,
        code: 'validation_failed',
        profileHash: '',
        checkedAt: DateTime.now().toUtc(),
      );
    } finally {
      _coreToken = null;
      coreChecking = false;
    }
  }

  Future<void> persistDraft() {
    final store = draftStore;
    if (store == null) return Future.value();
    final text = source;
    final revision = ++_draftRevision;
    savingDraft = true;
    draftSaveFailed = false;
    if (!_disposed) notifyListeners();
    _draftWrites = _draftWrites.then((_) async {
      if (revision != _draftRevision) return;
      try {
        await store.writeDraft(text);
      } catch (_) {
        if (revision == _draftRevision) draftSaveFailed = true;
      } finally {
        if (revision == _draftRevision) savingDraft = false;
        if (!_disposed) notifyListeners();
      }
    });
    return _draftWrites;
  }

  void _changed() {
    _revision++;
    stale = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (busy) return;
    busy = true;
    failed = false;
    final revision = _revision;
    notifyListeners();
    try {
      final next = await previewTemplate(source, const []);
      if (!_disposed && revision == _revision) {
        result = next;
        stale = false;
      }
    } catch (_) {
      if (!_disposed) failed = true;
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _coreToken?.cancel();
    super.dispose();
  }
}
