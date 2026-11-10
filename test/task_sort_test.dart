/// Сортировка соседних узлов списка по правилам §4.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/domain/due_spec.dart';
import 'package:notes_app/domain/task_sort.dart';
import 'package:notes_app/domain/task_sort_input.dart';

TaskSortInput t({
  Priority priority = Priority.normal,
  String? date,
  int? minutes,
  required int order,
}) =>
    TaskSortInput(
      priority: priority,
      due: date == null
          ? const DueSpec.none()
          : (minutes == null
              ? DueSpec.dateOnly(date)
              : DueSpec.at(date, minutes)),
      manualOrder: order,
);

void main() {
  test('по сроку: сначала ближайшие, без срока внизу', () {
    final sooner = t(date: '2026-11-02', order: 2);
    final later = t(date: '2026-11-05', order: 1);
    final none = t(order: 0); // ручной порядок 0, но без срока — всё равно внизу
    final list = [none, later, sooner]..sort(compareByDue);
    expect(list, [sooner, later, none]);
  });

  test('по сроку: момент того же дня раньше границы следующей полуночи', () {
    // Граница просрочки даты без времени — 00:00 следующего дня (§5),
    // поэтому 02.11 18:00 «ближе», чем весь день 02.11.
    final dateOnly = t(date: '2026-11-02', order: 1);
    final withTime = t(date: '2026-11-02', minutes: 18 * 60, order: 2);
    final list = [dateOnly, withTime]..sort(compareByDue);
    expect(list.first, withTime);
  });

  test('по сроку: равенство — высокий приоритет, затем ручной порядок', () {
    final high = t(priority: Priority.high, date: '2026-11-02', order: 2);
    final normal = t(priority: Priority.normal, date: '2026-11-02', order: 1);
    final list = [normal, high]..sort(compareByDue);
    expect(list.first, high);

    final first = t(date: '2026-11-02', order: 1);
    final second = t(date: '2026-11-02', order: 2);
    final tie = [second, first]..sort(compareByDue);
    expect(tie, [first, second]);
  });

  test('по приоритету: высокий первым, затем срок, затем ручной порядок', () {
    final highLate = t(priority: Priority.high, date: '2026-11-10', order: 2);
    final normalSoon = t(priority: Priority.normal, date: '2026-11-01', order: 1);
    final list = [normalSoon, highLate]..sort(compareByPriority);
    expect(list.first, highLate);

    final a = t(priority: Priority.low, order: 3);
    final b = t(priority: Priority.low, order: 1);
    expect([a, b]..sort(compareByPriority), [b, a]);
  });

  test('по сроку: дата-время раньше, чем дата без времени того же дня',
      () {
    // Граница просрочки даты без времени — 00:00 следующего дня (§5),
    // поэтому момент 02.11 09:00 «ближе», чем весь день 02.11.
    final morning = t(date: '2026-11-02', minutes: 9 * 60, order: 1);
    final allDay = t(date: '2026-11-02', order: 2);
    final list = [allDay, morning]..sort(compareByDue);
    expect(list.first, morning);
  });
}
