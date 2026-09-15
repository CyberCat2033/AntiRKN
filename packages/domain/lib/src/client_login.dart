/// Creates an internal ASCII login from a display name. Existing accounts keep
/// their login on rename so protocol credentials and access remain stable.
String generateClientLogin(
  String displayName,
  Iterable<String> existingLogins,
) {
  const transliteration = {
    'а': 'a',
    'б': 'b',
    'в': 'v',
    'г': 'g',
    'д': 'd',
    'е': 'e',
    'ё': 'yo',
    'ж': 'zh',
    'з': 'z',
    'и': 'i',
    'й': 'y',
    'к': 'k',
    'л': 'l',
    'м': 'm',
    'н': 'n',
    'о': 'o',
    'п': 'p',
    'р': 'r',
    'с': 's',
    'т': 't',
    'у': 'u',
    'ф': 'f',
    'х': 'kh',
    'ц': 'ts',
    'ч': 'ch',
    'ш': 'sh',
    'щ': 'shch',
    'ъ': '',
    'ы': 'y',
    'ь': '',
    'э': 'e',
    'ю': 'yu',
    'я': 'ya',
  };
  final text = StringBuffer();
  for (final rune in displayName.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    text.write(transliteration[char] ?? char);
  }
  var base = text
      .toString()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  if (base.isEmpty) base = 'client';
  if (base.length > 64) base = base.substring(0, 64);
  base = base.replaceAll(RegExp('-+\$'), '');
  final occupied = existingLogins.map((login) => login.toLowerCase()).toSet();
  var candidate = base;
  for (var suffix = 2; occupied.contains(candidate); suffix++) {
    final ending = '-$suffix';
    final length = 64 - ending.length;
    final prefix = base.length > length ? base.substring(0, length) : base;
    candidate = '${prefix.replaceAll(RegExp('-+\$'), '')}$ending';
  }
  return candidate;
}
