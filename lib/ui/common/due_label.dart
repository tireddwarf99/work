/// Форматирование срока для UI (макеты: «Завтра, 18:00», «Без часу»).
library;

import 'package:intl/intl.dart';

import '../../domain/due_spec.dart';
import '../../domain/time_rules.dart';
import '../../l10n/app_localizations.dart';

/// Человекочитаемая строка срока; null — срока нет.
String? formatDue(DueSpec due, AppLocalizations l10n) {
  switch (due.kind) {
    case DueKind.none:
      return null;
    case DueKind.dateTime:
      return '${_datePart(due.date!, l10n)}, ${formatMinutes(due.minutes!)}';
    case DueKind.date:
      return '${_datePart(due.date!, l10n)}, ${l10n.noTime}';
  }
}

/// Дата для настроек/деталей (без времени).
String? formatDatePart(DueSpec due, AppLocalizations l10n) =>
    due.isNone ? null : _datePart(due.date!, l10n);

/// Минуты от полуночи как `HH:mm`.
String formatMinutes(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

/// Локальная дата как `yyyy-MM-dd` (единый формат хранения срока, §3).
String formatYmd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Разбор `yyyy-MM-dd` в локальную полночь.
DateTime parseYmd(String ymd) {
  final (y, m, d) = splitYmd(ymd);
  return DateTime(int.parse(y), int.parse(m), int.parse(d));
}

String _datePart(String ymd, AppLocalizations l10n) {
  final todayYmd = formatYmd(DateTime.now());
  if (ymd == todayYmd) return l10n.today;
  if (ymd == shiftYmd(todayYmd, 1)) return l10n.tomorrow;
  if (ymd == shiftYmd(todayYmd, -1)) return l10n.yesterday;
  return DateFormat('d MMM', l10n.localeName).format(parseYmd(ymd));
}
