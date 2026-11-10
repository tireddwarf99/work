/// Минимальный снимок задачи для сравнения при сортировке (§4).
///
/// Отдельный класс вместо полной строки БД: сортировка — чистая функция,
/// проверяется без базы.
library;

import 'due_spec.dart';

class TaskSortInput {
  final Priority priority;
  final DueSpec due;
  final int manualOrder;

  const TaskSortInput({
    required this.priority,
    required this.due,
    required this.manualOrder,
  });
}
