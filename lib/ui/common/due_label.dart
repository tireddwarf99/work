/// Форматирование срока для UI (макеты: «Завтра, 18:00», «Без часу»).
library;

import 'package:intl/intl.dart';

import '../../domain/due_spec.dart';
import '../../l10n/app_localizations.dart';

/// Человекочитаемая строка срока; null — срока нет.
String? formatDue(DueSpec due, AppLocalizations l10n) {
  switch (due.kind) {
    case DueKind.none:
      return null;
    case DueKind.dateTime:
      return '${_datePart(due.date!, l10n)}, ${_timePart(due.minutes!)}';
    case DueKind.date:
      return '${_datePart(due.date!, l10n)}, ${l10n.noTime}';
  }
}

/// Дата для настроек/деталей (без времени).
String? formatDatePart(DueSpec due, AppLocalizations l10n) =>
    due.isNone ? null : _datePart(due.date!, l10n);

String _timePart(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

String _datePart(String ymd, AppLocalizations l10n) {
  final todayYmd = _todayYmd();
  final tomorrowYmd = _shift(todayYmd, 1);
  final yesterdayYmd = _shift(todayYmd, -1);
  if (ymd == todayYmd) return l10n.today;
  if (ymd == tomorrowYmd) return l10n.tomorrow;
  if (ymd == yesterdayYmd) return l10n.yesterday;
  final (y, m, d) = _split(ymd);
  final date = DateTime(int.parse(y), int.parse(m), int.parse(d));
  return DateFormat('d MMM', l10n.localeName).format(date);
}

String _todayYmd() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

String _shift(String ymd, int days) {
  final (y, m, d) = _split(ymd);
  final date =
      DateTime(int.parse(y), int.parse(m), int.parse(d) + days);
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

(String, String, String) _split(String ymd) =>
    (ymd.substring(0, 4), ymd.substring(5, 7), ymd.substring(8, 10));
