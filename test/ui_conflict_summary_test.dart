/// Краткая сводка версии конфликта (§10): заголовок и пояснение из payload.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/ui/conflicts_screen.dart';

void main() {
  test('заметка: title и первая строка search_text', () {
    final s = conflictSummary(
      '{"title":"План","search_text":"первая\\nвторая","revision":3}',
    );
    expect(s.title, 'План');
    expect(s.details, 'первая');
  });

  test('задача: text и description', () {
    final s = conflictSummary('{"text":"Купить хлеб","description":"сегодня"}');
    expect(s.title, 'Купить хлеб');
    expect(s.details, 'сегодня');
  });

  test('нечитаемый payload даёт пустую сводку', () {
    expect(conflictSummary('не json').title, isNull);
    expect(conflictSummary('[1,2]').details, isNull);
  });
}
