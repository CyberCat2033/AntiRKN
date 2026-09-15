import 'dart:convert';

/// A canonical ordering for nested mappings; list order remains semantic.
Object? canonicalValue(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: canonicalValue(value[key])};
  }
  if (value is List) return value.map(canonicalValue).toList();
  return value;
}

String canonicalJson(Object? value) => jsonEncode(canonicalValue(value));
