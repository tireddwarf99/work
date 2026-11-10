/// Журнал исходящих операций (§10): каждая мутация и запись outbox — одна
/// транзакция; подтверждённые изменения не теряются при аварии.
///
/// Сервисы вызывают [recordUpsert]/[recordDeletion] внутри своей транзакции —
/// передача по сети здесь не выполняется, это исключительно локальный журнал.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';

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
    await _db.into(_db.outboxEntries).insert(
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

  /// Запись операции удаления (логического; физическая очистка позже
  /// порождает DeletionMarkers, §10).
  Future<void> recordDeletion(SyncEntityType type, String entityId) async {
    await _db.into(_db.outboxEntries).insert(
          OutboxEntriesCompanion.insert(
            operationId: _uuid.v4(),
            entityType: type,
            entityId: entityId,
            changeKind: 'delete',
            payload: jsonEncode({
              'entity_id': entityId,
              'entity_type': type.name,
            }),
            createdAt: DateTime.now().toUtc(),
          ),
        );
  }

  /// Непереданные операции — проверка «есть что отправлять».
  Future<List<OutboxEntry>> pending() =>
      (_db.select(_db.outboxEntries)
            ..orderBy([(o) => OrderingTerm.asc(o.createdAt)]))
          .get();
}
