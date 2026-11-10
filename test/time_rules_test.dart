/// Проверки логики времени на фиксированных часах (§14, п.6): границы
/// полуночи, 48 часов, недели, високосного февраля, DST.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:notes_app/domain/due_spec.dart';
import 'package:notes_app/domain/time_rules.dart';

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  group('граница просрочки для даты без времени', () {
    test('просрочка наступает в 00:00 следующего дня, а не +24 часа', () {
      final kyiv = tz.getLocation('Europe/Kyiv');
      final boundary = endOfDayBoundary('2026-11-02', kyiv);
      // В Киеве полуночь следующего дня — конкретный локальный момент.
      expect(ymdOf(boundary), '2026-11-03');
      expect(boundary.hour, 0);
      expect(boundary.minute, 0);
    });

    test('isOverdue: вечер дня «сегодня» — не просрочено, полночь — просрочено',
        () {
      final kyiv = tz.getLocation('Europe/Kyiv');
      final evening = tz.TZDateTime(kyiv, 2026, 11, 2, 23, 59);
      final midnight = tz.TZDateTime(kyiv, 2026, 11, 3, 0, 0);
      final due = const DueSpec.dateOnly('2026-11-02');
      expect(isOverdue(due, evening), isFalse);
      expect(isOverdue(due, midnight), isTrue);
    });

    test('дата-время просрочено по самому моменту', () {
      final kyiv = tz.getLocation('Europe/Kyiv');
      final due = const DueSpec.at('2026-11-02', 18 * 60);
      expect(isOverdue(due, tz.TZDateTime(kyiv, 2026, 11, 2, 17, 59)), isFalse);
      expect(isOverdue(due, tz.TZDateTime(kyiv, 2026, 11, 2, 18, 1)), isTrue);
    });
  });

  group('окно 48 часов (блок «Наближається термін»)', () {
    test('дата без времени: 48 часов считаются до следующей полуночи', () {
      final kyiv = tz.getLocation('Europe/Kyiv');
      // Срок 3 ноября; граница — 4 ноября 00:00. В 2 ноября 00:30 остаток
      // 47.5 часа — в окне; в 1 ноября 23:30 остаток 48.5 часа — вне окна.
      final inside = tz.TZDateTime(kyiv, 2026, 11, 2, 0, 30);
      expect(
          isDueWithin(const DueSpec.dateOnly('2026-11-03'), inside,
              const Duration(hours: 48)),
          isTrue);
      final outside = tz.TZDateTime(kyiv, 2026, 11, 1, 23, 30);
      expect(
          isDueWithin(const DueSpec.dateOnly('2026-11-03'), outside,
              const Duration(hours: 48)),
          isFalse);
    });

    test('просроченная задача не попадает в окно 48 часов', () {
      final kyiv = tz.getLocation('Europe/Kyiv');
      final now = tz.TZDateTime(kyiv, 2026, 11, 4, 12, 0);
      expect(
          isDueWithin(const DueSpec.dateOnly('2026-11-02'), now,
              const Duration(hours: 48)),
          isFalse);
    });

    test('дата-время: остаток считается до момента срока', () {
      final kyiv = tz.getLocation('Europe/Kyiv');
      final due = const DueSpec.at('2026-11-02', 18 * 60);
      expect(
          isDueWithin(
              due, tz.TZDateTime(kyiv, 2026, 11, 2, 10, 0),
              const Duration(hours: 48)),
          isTrue);
    });
  });

  group('неделя понедельник—воскресенье', () {
    test('понедельник — начало недели, воскресенье — конец', () {
      final kyiv = tz.getLocation('Europe/Kyiv');
      // 2 ноября 2026 — понедельник, 8 ноября — воскресенье.
      final monday = tz.TZDateTime(kyiv, 2026, 11, 2, 12);
      expect(monday.weekday, DateTime.monday);
      expect(isDateInWeekOf('2026-11-02', monday), isTrue);
      expect(isDateInWeekOf('2026-11-08', monday), isTrue);
      expect(isDateInWeekOf('2026-11-01', monday), isFalse);
      expect(isDateInWeekOf('2026-11-09', monday), isFalse);
    });

    test('воскресенье как «сегодня»: вся неделя подходит', () {
      final kyiv = tz.getLocation('Europe/Kyiv');
      final sunday = tz.TZDateTime(kyiv, 2026, 11, 8, 23, 30);
      expect(isDateInWeekOf('2026-11-02', sunday), isTrue);
      expect(isDateInWeekOf('2026-11-08', sunday), isTrue);
      expect(isDateInWeekOf('2026-11-09', sunday), isFalse);
    });
  });

  group('несуществующее число месяца (повторение, §6)', () {
    test('31 января → последний день февраля високосного года', () {
      expect(clampDayOfMonth(2024, 2, 31), 29);
    });

    test('31 января → последний день февраля обычного года', () {
      expect(clampDayOfMonth(2026, 2, 31), 28);
    });

    test('31 марта не зажимается', () {
      expect(clampDayOfMonth(2026, 3, 31), 31);
    });

    test('сдвиг повторения 31 января → 28 февраля → 31 марта сохраняет даты',
        () {
      // Календарная разница и нормализация: исходное число в правиле
      // сохраняется, сменяется только показанный срок.
      expect(shiftYmd('2026-01-31', 28), '2026-02-28');
      expect(shiftYmd('2026-02-28', 31), '2026-03-31');
      expect(calendarDayDiff('2026-01-31', '2026-02-28'), 28);
    });
  });

  group('DST', () {
    test('несуществующее время (весенний скачок) сдвигается после скачка',
        () {
      // В Киеве 29 марта 2026 в 03:00 часы переводятся на 04:00:
      // локальное время 03:30 не существует.
      final kyiv = tz.getLocation('Europe/Kyiv');
      final resolved = resolveLocalMoment(2026, 3, 29, 3 * 60 + 30, kyiv);
      // Момент не лежит в пропущенном интервале: смещение либо 02:30+01:00
      // (до скачка), либо 04:30+03:00 (после скачка). Пакет сдвигает вперёд.
      expect(resolved.timeZoneOffset, const Duration(hours: 3),
          reason: 'момент после скачка в летнее время');
      expect(resolved.hour, 4);
      expect(resolved.minute, 30);
    });

    test('повторяющееся время (осенний откат) используется один раз', () {
      // 25 октября 2026 в 04:00 Киев возвращается на 03:00; локальное
      // время 03:30 существует дважды — берётся первое вхождение.
      final kyiv = tz.getLocation('Europe/Kyiv');
      final resolved = resolveLocalMoment(2026, 10, 25, 3 * 60 + 30, kyiv);
      expect(resolved.timeZoneOffset, const Duration(hours: 3),
          reason: 'первое вхождение — летнее время');
    });

    test('09:00 остаётся 09:00 при смене часового пояса (§6)', () {
      final kyiv = tz.getLocation('Europe/Kyiv');
      final newYork = tz.getLocation('America/New_York');
      final inKyiv = resolveLocalMoment(2026, 11, 2, 9 * 60, kyiv);
      final inNewYork = resolveLocalMoment(2026, 11, 2, 9 * 60, newYork);
      // Локальное поле времени сохраняется; физические моменты разные.
      expect(inKyiv.hour, 9);
      expect(inNewYork.hour, 9);
      expect(inKyiv.isBefore(inNewYork), isTrue);
    });
  });

  group('перенос сроков подзадач (§6)', () {
    test('дата сдвигается, минуты сохраняются; без срока — без срока', () {
      const due = DueSpec.at('2026-11-02', 18 * 60);
      final shifted = shiftDueByCalendarDays(due, 7);
      expect(shifted, const DueSpec.at('2026-11-09', 18 * 60));

      const dateOnly = DueSpec.dateOnly('2026-11-30');
      expect(shiftDueByCalendarDays(dateOnly, 1), const DueSpec.dateOnly('2026-12-01'));

      expect(shiftDueByCalendarDays(const DueSpec.none(), 5), const DueSpec.none());
    });
  });

  group('календарная арифметика дат', () {
    test('сдвиг назад и через границу года', () {
      expect(shiftYmd('2026-01-01', -1), '2025-12-31');
      expect(shiftYmd('2026-12-31', 1), '2027-01-01');
      expect(shiftYmd('2026-03-29', 0), '2026-03-29');
    });

    test('разность дат не зависит от DST-границ и знака', () {
      expect(calendarDayDiff('2026-03-28', '2026-03-30'), 2);
      expect(calendarDayDiff('2026-10-24', '2026-10-26'), 2);
      expect(calendarDayDiff('2026-11-02', '2026-11-01'), -1);
    });

    test('localNow переносит поля локальных часов', () {
      final now = localNow(clock: DateTime(2026, 11, 2, 23, 59, 30));
      expect(ymdOf(now), '2026-11-02');
      expect((now.hour, now.minute, now.second), (23, 59, 30));
    });
  });
}
