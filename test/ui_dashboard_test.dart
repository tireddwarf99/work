/// Раскладка dashboard по блокам (§5): просроченная задача попадает в
/// «Пропущені» ровно один раз, блоки сортируются.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/data/outbox_ledger.dart';
import 'package:notes_app/data/tasks_service.dart';
import 'package:notes_app/db/app_database.dart';
import 'package:notes_app/domain/due_spec.dart';
import 'package:notes_app/ui/dashboard/dashboard_screen.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  late AppDatabase db;
  late TasksService tasks;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tasks = TasksService(db, OutboxLedger(db));
  });

  tearDown(() => db.close());

  Future<Task> add(String text, DueSpec due) async {
    final task = await tasks.create(inboxListId, text: text);
    await tasks.setDue(task.id, due);
    return tasks.get(task.id);
  }

  // Среда, 10 июня 2026, 12:00.
  final now = tz.TZDateTime(tz.UTC, 2026, 6, 10, 12);

  test(
    'просроченные dateTime и date попадают в «Пропущені» по одному разу',
    () async {
      final pastDateTime = await add(
        'dt',
        const DueSpec.at('2026-06-10', 9 * 60),
      );
      final pastDate = await add('d', const DueSpec.dateOnly('2026-06-09'));
      final future = await add('f', const DueSpec.at('2026-06-10', 18 * 60));

      final data = buildDashboardData([pastDateTime, pastDate, future], now);

      expect(data.overdue.map((t) => t.content), ['dt', 'd']);
      expect(data.overdue.where((t) => t.id == pastDateTime.id), hasLength(1));
      expect(data.overdue.any((t) => t.id == future.id), isFalse);
    },
  );

  test('задача без срока — в «Загальні», сегодняшняя — в «Сьогодні»', () async {
    final none = await add('n', const DueSpec.none());
    final today = await add('t', const DueSpec.dateOnly('2026-06-10'));

    final data = buildDashboardData([none, today], now);

    expect(data.general.map((t) => t.id), [none.id]);
    expect(data.today.map((t) => t.id), [today.id]);
    expect(data.overdue, isEmpty);
  });

  test('«Сьогодні» отсортирован по сроку', () async {
    final late = await add('late', const DueSpec.at('2026-06-10', 20 * 60));
    final early = await add('early', const DueSpec.at('2026-06-10', 13 * 60));

    final data = buildDashboardData([late, early], now);

    expect(data.today.map((t) => t.content), ['early', 'late']);
  });
}
