/// Сортировка соседних узлов списка задач (§4).
///
/// Подзадачи остаются у родителей — сравниваются только соседние узлы.
/// Ручной порядок при сортировке по сроку/приоритету служит последним
/// критерием равенства.
library;

import 'package:timezone/timezone.dart' as tz;

import 'due_spec.dart';
import 'task_sort_input.dart';
import 'time_rules.dart';

/// По сроку: сначала ближайшие, без срока внизу, затем приоритет и ручной
/// порядок (§4).
int compareByDue(TaskSortInput a, TaskSortInput b) {
  final byDue = _compareDue(a.due, b.due);
  if (byDue != 0) return byDue;
  final byPriority = b.priority.index.compareTo(a.priority.index);
  if (byPriority != 0) return byPriority;
  return a.manualOrder.compareTo(b.manualOrder);
}

/// По приоритету: высокий первым, затем срок и ручной порядок (§4).
int compareByPriority(TaskSortInput a, TaskSortInput b) {
  final byPriority = b.priority.index.compareTo(a.priority.index);
  if (byPriority != 0) return byPriority;
  final byDue = _compareDue(a.due, b.due);
  if (byDue != 0) return byDue;
  return a.manualOrder.compareTo(b.manualOrder);
}

/// Сравнение сроков по границе просрочки (§5): для даты без времени — 00:00
/// следующего дня, для даты-времени — сам момент. Сроки сравниваются как
/// календарные поля в одной зоне, поэтому зона не влияет на порядок.
/// Без срока — в самом конце.
int _compareDue(DueSpec a, DueSpec b) {
  final da = dueDeadline(a, tz.UTC);
  final db = dueDeadline(b, tz.UTC);
  if (da == null || db == null) {
    if (da == db) return 0;
    return da == null ? 1 : -1;
  }
  return da.compareTo(db);
}
