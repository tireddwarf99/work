/// Чистая логика времени и сроков (§5, §6 спеки).
///
/// Все функции принимают зону явно, чтобы поведение зависело только от входов
/// и проверялось на фиксированных часах. Локальное время хранится как
/// календарные поля, а не как UTC-момент: 09:00 остаётся 09:00 при смене
/// часового пояса.
library;

import 'package:timezone/timezone.dart' as tz;

import 'due_spec.dart';

final RegExp _ymdPattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Текущее локальное время устройства как календарные поля (§5, §6): сроки
/// хранятся без зоны, поэтому поля системных часов переносятся в зону
/// [tz.UTC], которая служит лишь контейнером без DST-скачков — сравнение
/// со сроками идёт по календарю. Результат нельзя трактовать как абсолютный
/// момент. [clock] — подмена часов (тесты).
tz.TZDateTime localNow({DateTime? clock}) {
  final n = (clock ?? DateTime.now()).toLocal();
  return tz.TZDateTime(
    tz.UTC,
    n.year,
    n.month,
    n.day,
    n.hour,
    n.minute,
    n.second,
  );
}

/// Разбирает `yyyy-MM-dd`; иначе бросает [ArgumentError].
(String, String, String) splitYmd(String ymd) {
  final m = _ymdPattern.firstMatch(ymd);
  if (m == null) {
    throw ArgumentError.value(ymd, 'ymd', 'expected yyyy-MM-dd');
  }
  return (m.group(1)!, m.group(2)!, m.group(3)!);
}

/// Форматирует локальную дату как `yyyy-MM-dd`.
String ymdOf(DateTime t) {
  final mm = t.month.toString().padLeft(2, '0');
  final dd = t.day.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-$mm-$dd';
}

tz.TZDateTime _midnight(String ymd, tz.Location loc) {
  final (y, m, d) = splitYmd(ymd);
  return tz.TZDateTime(loc, int.parse(y), int.parse(m), int.parse(d));
}

/// Срок без времени как локальный момент начала дня (для сортировок).
tz.TZDateTime startOfDay(String ymd, tz.Location loc) => _midnight(ymd, loc);

/// Граница просрочки даты без времени — следующая календарная полуночь (§6):
/// просрочка наступает в 00:00 следующего дня, а не через 24 часа от «полуночи
/// срока». DST-переход внутри суток даёт календарную, а не 24-часовую границу.
tz.TZDateTime endOfDayBoundary(String ymd, tz.Location loc) {
  final start = _midnight(ymd, loc);
  final nextDay = tz.TZDateTime(loc, start.year, start.month, start.day + 1);
  return nextDay;
}

/// Локальный момент срока (для dateTime — сам момент; для date — граница
/// следующей полуночи). Возвращает null для [DueKind.none].
tz.TZDateTime? dueDeadline(DueSpec due, tz.Location loc) => switch (due.kind) {
  DueKind.none => null,
  DueKind.date => endOfDayBoundary(due.date!, loc),
  DueKind.dateTime => _localAt(due.date!, due.minutes!, loc),
};

tz.TZDateTime _localAt(String ymd, int minutes, tz.Location loc) {
  final (y, m, d) = splitYmd(ymd);
  return tz.TZDateTime(
    loc,
    int.parse(y),
    int.parse(m),
    int.parse(d),
    minutes ~/ 60,
    minutes % 60,
  );
}

/// Задача просрочена? Для даты без времени — по следующей календарной
/// полуночи (§5, §6). Для локальной даты-времени — по самому моменту.
bool isOverdue(DueSpec due, tz.TZDateTime now) => switch (due.kind) {
  DueKind.none => false,
  DueKind.date => !now.isBefore(endOfDayBoundary(due.date!, now.location)),
  DueKind.dateTime => !now.isBefore(
    _localAt(due.date!, due.minutes!, now.location),
  ),
};

/// Остаток до срока не более [window], задача ещё не просрочена (§5: блок
/// «Наближається термін», окно 48 часов до границы просрочки).
bool isDueWithin(DueSpec due, tz.TZDateTime now, Duration window) {
  final deadline = dueDeadline(due, now.location);
  if (deadline == null) return false;
  if (isOverdue(due, now)) return false;
  return !deadline.isAfter(now.add(window));
}

/// Дата внутри локальной недели, содержащей [anyDayOfWeek]:
/// понедельник—воскресенье по местному календарю (§5, блок «На этой неделе»).
bool isDateInWeekOf(String ymd, tz.TZDateTime anyDayOfWeek) {
  final loc = anyDayOfWeek.location;
  final daysSinceMonday = anyDayOfWeek.weekday - DateTime.monday;
  final monday = tz.TZDateTime(
    loc,
    anyDayOfWeek.year,
    anyDayOfWeek.month,
    anyDayOfWeek.day - daysSinceMonday,
  );
  final nextMonday = tz.TZDateTime(
    loc,
    monday.year,
    monday.month,
    monday.day + 7,
  );
  return !startOfDay(ymd, loc).isBefore(monday) &&
      startOfDay(ymd, loc).isBefore(nextMonday);
}

/// Календарная разница в днях между датами (`to - from`) по локальному
/// календарю — используется при переносе сроков подзадач повторяющегося
/// дерева (§6).
int calendarDayDiff(String fromYmd, String toYmd) =>
    _utcDate(toYmd).difference(_utcDate(fromYmd)).inDays;

/// Сдвиг календарной даты на [days] дней с валидацией результата.
String shiftYmd(String ymd, int days) {
  final date = _utcDate(ymd);
  return ymdOf(DateTime.utc(date.year, date.month, date.day + days));
}

/// Календарная дата как UTC-полночь: сутки в UTC всегда по 24 часа, поэтому
/// разность и сдвиг не зависят от DST.
DateTime _utcDate(String ymd) {
  final (y, m, d) = splitYmd(ymd);
  return DateTime.utc(int.parse(y), int.parse(m), int.parse(d));
}

/// Перенос срока по календарной разнице (§6): дата сдвигается, локальное
/// время (минуты) сохраняется; без срока — остаётся без срока.
DueSpec shiftDueByCalendarDays(DueSpec due, int days) => switch (due.kind) {
  DueKind.none => due,
  DueKind.date => DueSpec.dateOnly(shiftYmd(due.date!, days)),
  DueKind.dateTime => DueSpec.at(shiftYmd(due.date!, days), due.minutes!),
};

int _daysInMonth(int year, int month) {
  const lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month < 1 || month > 12) {
    throw ArgumentError.value(month, 'month');
  }
  var len = lengths[month - 1];
  if (month == 2 && _isLeapYear(year)) len = 29;
  return len;
}

bool _isLeapYear(int year) =>
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

/// Несуществующее число месяца заменяется последним днём месяца; исходное
/// число в правиле сохраняется (§6): 31 января → последний день февраля →
/// 31 марта. Возвращает нормализованное число дня.
int clampDayOfMonth(int year, int month, int day) {
  final max = _daysInMonth(year, month);
  return day > max ? max : day;
}

/// Строит локальный момент из календарных полей с правилами §6:
/// несуществующее число месяца зажимается до последнего дня, несуществующее
/// местное время (DST-скачок) сдвигается к ближайшему допустимому моменту
/// после скачка. Повторяющееся время при откате часов используется один раз —
/// первое вхождение.
tz.TZDateTime resolveLocalMoment(
  int year,
  int month,
  int day,
  int minutes,
  tz.Location loc,
) {
  final clampedDay = clampDayOfMonth(year, month, day);
  final hour = minutes ~/ 60;
  final minute = minutes % 60;

  // Несуществующее время (DST-скачок вперёд) пакет нормализует в момент
  // после скачка — это и есть нужный результат.
  final candidate = tz.TZDateTime(loc, year, month, clampedDay, hour, minute);

  // Повторяющееся время (осенний откат): пакет мог выбрать второе вхождение.
  // Первое отстоит от него на разницу смещений до и после перехода.
  final dayBefore = tz.TZDateTime.fromMillisecondsSinceEpoch(
    loc,
    candidate.millisecondsSinceEpoch - Duration.millisecondsPerDay,
  );
  final shift = dayBefore.timeZoneOffset - candidate.timeZoneOffset;
  if (shift > Duration.zero) {
    final earlier = candidate.subtract(shift);
    if (earlier.hour == hour &&
        earlier.minute == minute &&
        earlier.day == clampedDay) {
      return earlier;
    }
  }
  return candidate;
}
