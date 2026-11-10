/// Порядок задач в UI по режиму сортировки (§4).
library;

import '../../db/app_database.dart';
import '../../domain/due_spec.dart';
import '../../domain/task_sort.dart';
import '../../domain/task_sort_input.dart';
import 'task_row.dart';

/// Задачи в порядке [mode]; ручной порядок возвращается как есть. Сравниваются
/// соседи: ручной порядок — последний критерий компараторов домена.
List<Task> sortTasks(SortMode mode, List<Task> tasks) {
  if (mode == SortMode.manual) return tasks;
  TaskSortInput input(Task t) => TaskSortInput(
    priority: t.priority,
    due: dueSpecFromRow(t),
    manualOrder: t.manualOrder,
  );
  return [...tasks]..sort(
    (a, b) => mode == SortMode.due
        ? compareByDue(input(a), input(b))
        : compareByPriority(input(a), input(b)),
  );
}
