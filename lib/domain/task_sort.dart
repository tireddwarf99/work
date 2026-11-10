/// Сортировка соседних узлов списка задач (§4).
///
/// Подзадачи остаются у родителей — сравниваются только соседние узлы.
/// Ручной порядок при сортировке по сроку/приоритету служит последним
/// критерием равенства.
library;

import 'due_spec.dart';
import 'time_rules.dart';
import 'task_sort_input.dart';

/// По сроку: сначала ближайшие, без срока внизу, затем приоритет и ручной
/// порядок (§4).
int compareByDue(TaskSortInput a, TaskSortInput b) {
  final da = _dueKey(a.due);
  final db = _dueKey(b.due);
  final byDue = da.compareTo(db);
  if (byDue != 0) return byDue;
  final byPriority = b.priority.index.compareTo(a.priority.index);
  if (byPriority != 0) return byPriority;
  return a.manualOrder.compareTo(b.manualOrder);
}

/// По приоритету: высокий первым, затем срок и ручной порядок (§4).
int compareByPriority(TaskSortInput a, TaskSortInput b) {
  final byPriority = b.priority.index.compareTo(a.priority.index);
  if (byPriority != 0) return byPriority;
  final byDue = _dueKey(a.due).compareTo(_dueKey(b.due));
  if (byDue != 0) return byDue;
  return a.manualOrder.compareTo(b.manualOrder);
}

/// Ключ срока: по границе просрочки (§5) — «сначала ближайшие».
/// Для даты без времени граница — 00:00 следующего дня; для даты-времени —
/// сам локальный момент. Без срока — в самом конце.
int _dueKey(DueSpec due) {
  if (due.isNone) return 0x7FFFFFFFFFFFFFFF;
  final (y, m, d) = splitYmd(due.date!);
  final dayIndex = int.parse(y) * 10000 + int.parse(m) * 100 + int.parse(d);
  if (due.hasTime) return dayIndex * 100000 + due.minutes! + 1;
  return (dayIndex + 1) * 100000 + 1;
}
