/// Журнал исходящих операций (§10): каждая мутация и запись outbox — одна
/// транзакция; подтверждённые изменения не теряются при аварии.
///
/// Сервисы вызывают методы журнала внутри своей транзакции — передача по сети
/// здесь не выполняется, это исключительно локальный журнал. Единая точка
/// локальной мутации — [recordChange]/[recordTrashed]: они повышают ревизию и
/// `modified_at` и ставят в outbox актуальный снимок (формат — как у
/// `readEntityPayload`, который читает синхронизация).
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';
import '../sync/sync_mapper.dart' show readEntityPayload;

class OutboxLedger {
  final AppDatabase _db;
  final Uuid _uuid;

  OutboxLedger(this._db, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// Запись операции обновления снапшота сущности.
  Future<void> recordUpsert(
    SyncEntityType type,
    String entityId,
    Map<String, Object?> snapshot,
  ) async {
    await _db
        .into(_db.outboxEntries)
        .insert(
          OutboxEntriesCompanion.insert(
            operationId: _uuid.v4(),
            entityType: type,
            entityId: entityId,
            changeKind: 'upsert',
            payload: jsonEncode(snapshot),
            createdAt: DateTime.now().toUtc(),
          ),
        );
  }

  /// Запись операции удаления (логического или окончательного). [revision] —
  /// ревизия удаляемой записи, если она известна.
  Future<void> recordDeletion(
    SyncEntityType type,
    String entityId, {
    int? revision,
  }) async {
    await _db
        .into(_db.outboxEntries)
        .insert(
          OutboxEntriesCompanion.insert(
            operationId: _uuid.v4(),
            entityType: type,
            entityId: entityId,
            changeKind: 'delete',
            payload: jsonEncode({
              'entity_id': entityId,
              'entity_type': type.name,
              if (revision != null) 'revision': revision,
            }),
            createdAt: DateTime.now().toUtc(),
          ),
        );
  }

  /// Ставит в outbox текущее состояние записи без изменения ревизии —
  /// для только что созданных сущностей.
  Future<void> recordSnapshot(SyncEntityType type, String entityId) async {
    await recordUpsert(type, entityId, await _snapshot(type, entityId));
  }

  /// Локальная мутация: ревизия +1, `modified_at` = сейчас, снимок в outbox.
  Future<void> recordChange(SyncEntityType type, String entityId) async {
    await _bump(type, entityId);
    await recordSnapshot(type, entityId);
  }

  /// Перемещение в корзину: ревизия +1 и операция удаления в outbox.
  Future<void> recordTrashed(SyncEntityType type, String entityId) async {
    await _bump(type, entityId);
    final snapshot = await _snapshot(type, entityId);
    await recordDeletion(
      type,
      entityId,
      revision: snapshot['revision'] as int?,
    );
  }

  /// Компактный маркер окончательного удаления без содержимого (§10): давно
  /// офлайн-устройство не должно воскресить удалённые данные.
  Future<void> writeDeletionMarker(
    SyncEntityType type,
    String entityId, {
    required DateTime deletedAt,
    required int revision,
  }) async {
    await _db
        .into(_db.deletionMarkers)
        .insertOnConflictUpdate(
          DeletionMarkersCompanion.insert(
            entityId: entityId,
            entityType: type,
            deletedAtUtc: deletedAt.toUtc().toIso8601String(),
            revision: revision,
          ),
        );
  }

  /// Непереданные операции — проверка «есть что отправлять».
  Future<List<OutboxEntry>> pending() => (_db.select(
    _db.outboxEntries,
  )..orderBy([(o) => OrderingTerm.asc(o.createdAt)])).get();

  // --- внутренние ---

  Future<Map<String, Object?>> _snapshot(
    SyncEntityType type,
    String entityId,
  ) async {
    final snapshot = await readEntityPayload(_db, type, entityId);
    if (snapshot == null) {
      throw StateError('${type.name} $entityId not found for outbox');
    }
    return snapshot;
  }

  TableInfo<Table, Object?> _tableOf(SyncEntityType type) => switch (type) {
    SyncEntityType.folder => _db.folders,
    SyncEntityType.note => _db.notes,
    SyncEntityType.taskList => _db.taskLists,
    SyncEntityType.task => _db.tasks,
    SyncEntityType.tag => _db.tags,
    _ => throw ArgumentError.value(
      type,
      'type',
      'entity has no single-id revision',
    ),
  };

  Future<void> _bump(SyncEntityType type, String entityId) async {
    final table = _tableOf(type);
    final id = table.columnsByName['id']! as GeneratedColumn<String>;
    final revision = table.columnsByName['revision']! as Expression<int>;
    final updated = await (_db.update(table)..where((_) => id.equals(entityId)))
        .write(
          RawValuesInsertable({
            'revision': revision + const Constant(1),
            'modified_at': Variable<DateTime>(DateTime.now().toUtc()),
          }),
        );
    if (updated == 0) {
      throw StateError('${type.name} $entityId not found');
    }
  }
}
