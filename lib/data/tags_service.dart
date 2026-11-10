/// Теги (§4): метки заметок и задач; удаление тега снимает метку,
/// не удаляя записи (§11). Теги заметок не наследуются задачами (§3).
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';

import 'outbox_ledger.dart';

class TagsService {
  final AppDatabase _db;
  final OutboxLedger _ledger;
  final Uuid _uuid;

  TagsService(this._db, this._ledger, {Uuid? uuid})
      : _uuid = uuid ?? const Uuid();

  Future<Tag> create(String name) {
    return _db.transaction(() async {
      final id = _uuid.v4();
      final order = await _nextOrder();
      await _db.into(_db.tags).insert(TagsCompanion.insert(
            id: id,
            name: name,
            manualOrder: Value(order),
            modifiedAt: Value(DateTime.now().toUtc()),
          ));
      final created = await _get(id);
      await _ledger.recordUpsert(SyncEntityType.tag, id, created.toJson());
      return created;
    });
  }

  Future<void> rename(String tagId, String name) {
    return _db.transaction(() async {
      await (_db.update(_db.tags)..where((t) => t.id.equals(tagId))).write(
        TagsCompanion(name: Value(name), modifiedAt: Value(DateTime.now().toUtc())),
      );
      await _ledger.recordUpsert(
          SyncEntityType.tag, tagId, (await _get(tagId)).toJson());
    });
  }

  /// Удаление тега снимает метку со всех записей, записи не удаляются (§11).
  Future<void> delete(String tagId) {
    return _db.transaction(() async {
      await (_db.delete(_db.entityTags)..where((e) => e.tagId.equals(tagId)))
          .go();
      await (_db.delete(_db.tags)..where((t) => t.id.equals(tagId))).go();
      await _ledger.recordDeletion(SyncEntityType.tag, tagId);
    });
  }

  Future<void> attach(EntityKind kind, String entityId, String tagId) {
    return _db.transaction(() async {
      final existing = await (_db.select(_db.entityTags)
            ..where((e) => e.entityId.equals(entityId) &
                e.tagId.equals(tagId) &
                e.entityKind.equalsNullable(kind.index)))
          .getSingleOrNull();
      if (existing != null) return;
      final row = EntityTagsCompanion.insert(
        entityId: entityId,
        tagId: tagId,
        entityKind: kind,
        modifiedAt: Value(DateTime.now().toUtc()),
      );
      await _db.into(_db.entityTags).insert(row);
      final created = await (_db.select(_db.entityTags)
            ..where((e) => e.entityId.equals(entityId) &
                e.tagId.equals(tagId) &
                e.entityKind.equalsNullable(kind.index)))
          .getSingle();
      await _ledger.recordUpsert(
          SyncEntityType.entityTag, entityTagId(kind, entityId, tagId),
          created.toJson());
    });
  }

  Future<void> detach(EntityKind kind, String entityId, String tagId) {
    return _db.transaction(() async {
      await (_db.delete(_db.entityTags)
            ..where((e) => e.entityId.equals(entityId) &
                e.tagId.equals(tagId) &
                e.entityKind.equalsNullable(kind.index)))
          .go();
      await _ledger.recordDeletion(
          SyncEntityType.entityTag, entityTagId(kind, entityId, tagId));
    });
  }

  Future<List<Tag>> tagsFor(EntityKind kind, String entityId) async {
    final rows = await (_db.select(_db.entityTags).join([
      innerJoin(_db.tags, _db.tags.id.equalsExp(_db.entityTags.tagId)),
    ])
          ..where(_db.entityTags.entityId.equals(entityId) &
              _db.entityTags.entityKind.equalsNullable(kind.index))
          ..orderBy([OrderingTerm.asc(_db.tags.manualOrder)]))
        .get();
    return rows.map((r) => r.readTable(_db.tags)).toList();
  }

  /// Реактивный перечень тегов для навигации (§4).
  Stream<List<Tag>> watchAll({bool includeTrashed = false}) =>
      (_db.select(_db.tags)
            ..where((t) =>
                includeTrashed ? const Constant(true) : t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.manualOrder)]))
          .watch();

  Future<List<Tag>> listAll({bool includeTrashed = false}) =>
      (_db.select(_db.tags)
            ..where((t) =>
                includeTrashed ? const Constant(true) : t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.manualOrder)]))
          .get();

  // --- внутренние ---

  Future<Tag> _get(String id) async =>
      await (_db.select(_db.tags)..where((t) => t.id.equals(id)))
          .getSingle();

  Future<int> _nextOrder() async {
    final maxExp = _db.tags.manualOrder.max();
    final q = _db.selectOnly(_db.tags)..addColumns([maxExp]);
    return (await q.getSingle().then((r) => r.read(maxExp)) ?? 0) + 1;
  }
}

/// Стабильный идентификатор метки для синхронизации (композитный ключ).
String entityTagId(EntityKind kind, String entityId, String tagId) =>
    '${kind.index}:$entityId:$tagId';
