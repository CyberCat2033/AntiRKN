import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'display names produce lowercase ASCII logins with Russian transliteration',
    () {
      expect(generateClientLogin('  Иван Иванов  ', []), 'ivan-ivanov');
      expect(
        generateClientLogin('Ёж ЙЦУК Щука Юлия Яна ЪЬ', []),
        'yozh-ytsuk-shchuka-yuliya-yana',
      );
      expect(generateClientLogin('Alice / WORK_2026!', []), 'alice-work-2026');
      expect(generateClientLogin('📱 家庭', []), 'client');
    },
  );

  test('collisions include case variants and names with numeric suffixes', () {
    expect(generateClientLogin('Иван', ['IVAN', 'ivan-2', 'ivan-3']), 'ivan-4');
    expect(generateClientLogin('Иван 2', ['ivan-2']), 'ivan-2-2');
  });

  test('truncation and suffixes fit the existing account contract', () {
    final name = 'Щ' * 80;
    final first = generateClientLogin(name, []);
    final second = generateClientLogin(name, [first]);
    expect(first.length, 64);
    expect(second.length, 64);
    expect(second, endsWith('-2'));
    expect(second, matches(RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$')));
    expect(
      () => VpnUser(id: '1' * 32, login: second, name: name),
      returnsNormally,
    );
  });
}
