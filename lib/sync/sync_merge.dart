/// Трёхстороннее автослияние (§10): база — последняя общая подтверждённая
/// ревизия записи (sync_base), НЕ пользовательская история версий.
///
/// Независимые поля объединяются; одинаковые изменения считаются одним;
/// пересечения дают конфликт. Консервативно: сомнение сохраняет обе версии.
library;

/// Служебные поля протокола: не участвуют в сравнении (у каждой стороны
/// они свои), а в результате слияния выставляются заново.
const Set<String> serviceKeys = {
  'revision',
  'base_revision',
  'modified_at',
  'device_id',
  'deleted_at',
  'last_op_id',
  'commit_seq',
};

/// Результат слияния полей.
class FieldMergeResult {
  /// Объединённый payload (конфликтные поля — локальные значения);
  /// служебные поля: revision = max(local, remote) + 1, base_revision =
  /// ревизия удалённой стороны, modified_at — более поздний, device_id и
  /// deleted_at — локальные.
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
}) {
  final merged = <String, Object?>{};
  final conflicts = <String>[];
  final keys = <String>{
    ...base.keys,
    ...local.keys,
    ...remote.keys,
  }..removeAll(serviceKeys);
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

  final localRevision = local['revision'] as int? ?? 1;
  final remoteRevision = remote['revision'] as int? ?? 1;
  merged['revision'] =
      (localRevision > remoteRevision ? localRevision : remoteRevision) + 1;
  merged['base_revision'] = remoteRevision;
  merged['modified_at'] = _later(local['modified_at'], remote['modified_at']);
  merged['device_id'] = local['device_id'] ?? '';
  merged['deleted_at'] = local['deleted_at'];
  return FieldMergeResult(merged: merged, conflicts: conflicts);
}

/// Более поздняя из двух ISO-дат; при неразборчивости — локальная.
Object? _later(Object? local, Object? remote) {
  final l = local is String ? DateTime.tryParse(local) : null;
  final r = remote is String ? DateTime.tryParse(remote) : null;
  if (l == null) return r == null ? local : remote;
  if (r == null) return local;
  return r.isAfter(l) ? remote : local;
}

/// Разрешение «удаление против редактирования» (§10): побеждает более
/// поздняя дата действия; при равном времени удаление выигрывает.
/// Возвращает true, если должна победить удаляющая сторона (при
/// удалении с обеих сторон — позднее время, при равенстве — удаление).
bool deletionWins({
  required DateTime? localModifiedAt,
  required DateTime? remoteModifiedAt,
  required bool localDeleted,
  required bool remoteDeleted,
}) {
  final l = localModifiedAt;
  final r = remoteModifiedAt;
  if (remoteDeleted && !localDeleted) {
    // Удаление (удалённое) против редактирования (локального).
    return l == null || r == null || !l.isAfter(r);
  }
  if (localDeleted && !remoteDeleted) {
    return l == null || r == null || !r.isAfter(l);
  }
  // Обе удалены или обе активны: позднее время — победитель; при равенстве
  // удаление выигрывает.
  if (l == null) return true;
  if (r == null) return false;
  if (r.isAfter(l)) return true;
  if (l.isAfter(r)) return false;
  return true; // равное время — удаление выигрывает (§10)
}
