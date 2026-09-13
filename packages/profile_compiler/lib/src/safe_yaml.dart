import 'dart:convert';

// Pinned yaml 3.1.3: public API has no bounded event reader. Keep this private
// adapter isolated; retest its security contract before dependency updates.
// ignore: implementation_imports
import 'package:yaml/src/event.dart';
// ignore: implementation_imports
import 'package:yaml/src/parser.dart';
import 'package:yaml/yaml.dart';

Map<String, Object?> parseTemplate(String source) {
  if (source.length > 262144 || utf8.encode(source).length > 262144) {
    throw const FormatException('template_size_limit');
  }
  final parser = Parser(source);
  var depth = 0;
  var events = 0;
  var documents = 0;
  while (!parser.isDone) {
    final event = parser.parse();
    if (++events > 40000) throw const FormatException('template_node_limit');
    if (event.type == EventType.documentStart && ++documents > 1) {
      throw const FormatException('multiple_yaml_documents');
    }
    if (event.type == EventType.alias) {
      throw const FormatException('yaml_alias_not_supported');
    }
    final tag = switch (event) {
      ScalarEvent() => event.tag,
      MappingStartEvent() => event.tag,
      SequenceStartEvent() => event.tag,
      _ => null,
    };
    // yaml marks quoted scalars with the non-specific string tag '!'.
    if (tag != null && tag != '!') {
      throw const FormatException('yaml_explicit_tag_not_supported');
    }
    if (event.type == EventType.mappingStart ||
        event.type == EventType.sequenceStart) {
      if (++depth > 32) throw const FormatException('template_depth_limit');
    }
    if (event.type == EventType.mappingEnd ||
        event.type == EventType.sequenceEnd) {
      depth--;
    }
  }
  final root = _plain(loadYaml(source));
  if (root is! Map<String, Object?>) {
    throw const FormatException('yaml_mapping_required');
  }
  return root;
}

Object? _plain(Object? value) {
  if (value is Map) {
    if (value.keys.any((Object? key) => key is! String || key == '<<')) {
      throw const FormatException('invalid_yaml_key');
    }
    return {
      for (final entry in value.entries)
        entry.key as String: _plain(entry.value),
    };
  }
  if (value is List) return value.map(_plain).toList();
  if (value is double && !value.isFinite) {
    throw const FormatException('non_finite_yaml_value');
  }
  return value;
}
