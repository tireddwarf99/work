/// Трёхстороннее автослияние (§10): база — последняя общая подтверждённая
/// ревизия записи (sync_base), НЕ пользовательская история версий.
///
/// Независимые поля объединяются; одинаковые изменения считаются одним;
/// пересечения дают конфликт. Консервативно: сомнение сохраняет обе версии.
library;

/// Результат слияния полей.
class FieldMergeResult {
  /// Объединённый payload (конфликтные поля — локальные значения).
  final Map<String, Object?> merged;

  /// Поля, которые изменили обе стороны по-разному.
  final List<String> conflicts;

  const FieldMergeResult({required this.merged, required this.conflicts});

  bool get hasConflicts => conflicts.isNotEmpty;
}

/// Слияние по полям относительно [base].
FieldMergeResult mergePayloads({
  required Map<String, Object?> base,
  required Map<String, Object?> local,
  required Map<String, Object?> remote,
  List<String> mergeableKeys = const [],
}) {
  final merged = <String, Object?>{};
  final conflicts = <String>[];
  final keys = <String>{
    ...base.keys,
    ...local.keys,
    ...remote.keys,
  };
  for (final key in keys) {
    final b = base[key];
    final l = local[key];
    final r = remote[key];
    final localChanged = l != b;
    final remoteChanged = r != b;
    if (!localChanged) {
      merged[key] = r;
    } else if (!remoteChanged || l == r) {
      merged[key] = l;
    } else {
      // Обе стороны изменили поле по-разному.
      conflicts.add(key);
      merged[key] = l;
    }
  }
  return FieldMergeResult(merged: merged, conflicts: conflicts);
}

/// Разрешение «удаление против редактирования» (§10): побеждает более
/// поздняя дата действия; при равном времени удаление выигрывает.
/// Возвращает true, если должна победить удалённая сторона.
bool deletionWins({
  required DateTime? localModifiedAt,
  required DateTime? remoteModifiedAt,
  required bool localDeleted,
  required bool remoteDeleted,
}) {
  if (remoteDeleted && !localDeleted) {
    // Удаление (удалённое) против редактирования (локального).
    final l = localModifiedAt;
    final r = remoteModifiedAt;
    if (l == null) return true;
    // Позднее редактирование восстанавливает запись; при равенстве
    // удаление выигрывает.
    return !l.isAfter(r!);
  }
  if (localDeleted && !remoteDeleted) {
    final l = localModifiedAt!;
    final r = remoteModifiedAt;
    if (r == null) return true;
    return !r.isAfter(l);
  }
  // Обе удалены или обе активны: позднее время — победитель; при равенстве
  // удаление выигрывает.
  final l = localModifiedAt;
  final r = remoteModifiedAt;
  if (l == null) return true;
  if (r == null) return false;
  if (r.isAfter(l)) return true;
  if (l.isAfter(r)) return false;
  return true; // равное время — удаление выигрывает (§10)
}

/// Парсинг ISO-строки даты (UTC), null при отсутствии/повреждении.
DateTime? parseUtc(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  return DateTime.tryParse(iso)?.toUtc();
}
