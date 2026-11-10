/// Доменные перечисления и спецификация срока выполнения задачи.
library;

/// Приоритет задачи (§3). Значения совпадают с порядком сортировки
/// «сначала высокий» при сравнении убыванием.
enum Priority { low, normal, high }

/// Тип срока (§3): отсутствие, календарная дата или локальная дата-время.
enum DueKind { none, date, dateTime }

/// Режим сортировки списка задач (§4).
enum SortMode { manual, due, priority }

/// Вид напоминания (§7): относительное к сроку или абсолютное локальное время.
enum ReminderKind { relative, absolute }

/// Вид правила повторения (§6): календарное расписание или интервал от выполнения.
enum RecurrenceKind { calendar, interval }

/// К чему привязан тег (§3).
enum EntityKind { note, task }

/// Типы сущностей синхронизации (§3, служебный порядок фиксирован).
enum SyncEntityType {
  folder,
  note,
  taskList,
  task,
  tag,
  reminder,
  recurrenceRule,
  taskOccurrence,
  entityTag,
}

/// Срок задачи: отсутствие, календарная дата или локальная дата-время.
///
/// Дата без времени и локальная дата-время — разные типы (§3): отсутствие
/// времени никогда не кодируется как UTC-полночь. [date] — строка `yyyy-MM-dd`
/// в локальном календаре; [minutes] — минуты от локальной полуночи, задаются
/// только для [DueKind.dateTime].
class DueSpec {
  final DueKind kind;
  final String? date;
  final int? minutes;

  const DueSpec.none()
      : kind = DueKind.none,
        date = null,
        minutes = null;

  const DueSpec.dateOnly(String this.date)
      : kind = DueKind.date,
        minutes = null;

  const DueSpec.at(String this.date, int this.minutes)
      : kind = DueKind.dateTime;

  bool get isNone => kind == DueKind.none;
  bool get hasTime => kind == DueKind.dateTime;

  @override
  bool operator ==(Object other) =>
      other is DueSpec &&
      other.kind == kind &&
      other.date == date &&
      other.minutes == minutes;

  @override
  int get hashCode => Object.hash(kind, date, minutes);

  @override
  String toString() => switch (kind) {
        DueKind.none => 'none',
        DueKind.date => 'date($date)',
        DueKind.dateTime => 'dateTime($date, $minutes)',
      };
}
