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
  });
  final PreviewTemplate previewTemplate;
  final Future<ImportedTemplate?> Function()? pickTemplate;
  String source;
  String? importedName;
  String? importError;
  bool importing = false;
  List<ProxyDescriptor> _nodes = mixedNodes;
  List<ProxyDescriptor> get nodes => List.unmodifiable(_nodes);
  ProfileResult? result;
  bool busy = false;
  bool stale = true;
  bool failed = false;
  int _revision = 0;
  bool _disposed = false;

  static const mixedNodes = [
    ProxyDescriptor('VLESS_EU', 'VLESS'),
    ProxyDescriptor('Trust_RU', 'TrustTunnel'),
    ProxyDescriptor('WG_EU', 'WireGuard'),
  ];

  void edit(String value) {
    source = value;
    _changed();
  }

  Future<void> importFile() async {
    if (importing || busy || pickTemplate == null) return;
    importing = true;
    importError = null;
    notifyListeners();
    try {
      final imported = await pickTemplate!();
      if (_disposed || imported == null) return;
      // The selected content becomes an independent in-memory editor draft.
      source = imported.source;
      importedName = imported.name;
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

  void selectNodes(List<ProxyDescriptor> value) {
    _nodes = List.of(value);
    _changed();
  }

  void removeNode(int index) {
    _nodes = List.of(_nodes)..removeAt(index);
    _changed();
  }

  bool addNode(String name, String type) {
    name = name.trim();
    if (name.isEmpty ||
        name.length > 120 ||
        name.contains(RegExp(r'[\x00-\x1f]')) ||
        _nodes.any((n) => n.name == name) ||
        _nodes.length >= 256) {
      return false;
    }
    _nodes = [..._nodes, ProxyDescriptor(name, type)];
    _changed();
    return true;
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
      final next = await previewTemplate(source, nodes);
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
    super.dispose();
  }
}
