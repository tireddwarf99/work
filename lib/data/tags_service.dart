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
      await _db.into(_db.tags).insert(TagsCompanion.insert(
            id: id,
            name: name,
            manualOrder: Value(await _nextOrder()),
            modifiedAt: Value(DateTime.now().toUtc()),
          ));
      await _ledger.recordSnapshot(SyncEntityType.tag, id);
      return _get(id);
    });
  }

  Future<void> rename(String tagId, String name) {
    return _db.transaction(() async {
      await (_db.update(_db.tags)..where((t) => t.id.equals(tagId)))
          .write(TagsCompanion(name: Value(name)));
      await _ledger.recordChange(SyncEntityType.tag, tagId);
    });
  }

  /// Удаление тега снимает метку со всех записей, записи не удаляются (§11).
  /// Корзины у тегов нет: тег удаляется окончательно, в outbox уходят
  /// удаления тега и его меток, а маркер не даёт офлайн-устройству
  /// воскресить тег (§10).
  Future<void> delete(String tagId) {
    return _db.transaction(() async {
      final tag = await _get(tagId);
      final links = await (_db.select(_db.entityTags)
            ..where((e) => e.tagId.equals(tagId)))
          .get();
      await (_db.delete(_db.entityTags)..where((e) => e.tagId.equals(tagId)))
          .go();
      for (final link in links) {
        await _ledger.recordDeletion(SyncEntityType.entityTag,
            entityTagId(link.entityKind, link.entityId, tagId),
            revision: link.revision + 1);
      }
      await (_db.delete(_db.tags)..where((t) => t.id.equals(tagId))).go();
      final revision = tag.revision + 1;
      await _ledger.writeDeletionMarker(SyncEntityType.tag, tagId,
          deletedAt: DateTime.now().toUtc(), revision: revision);
      await _ledger.recordDeletion(SyncEntityType.tag, tagId,
          revision: revision);
    });
  }

  Future<void> attach(EntityKind kind, String entityId, String tagId) {
    return _db.transaction(() async {
      final existing = await (_entityTagRows(kind, entityId, tagId))
          .getSingleOrNull();
      if (existing != null) return;
      await _db.into(_db.entityTags).insert(EntityTagsCompanion.insert(
            entityId: entityId,
            tagId: tagId,
            entityKind: kind,
            modifiedAt: Value(DateTime.now().toUtc()),
          ));
      await _ledger.recordSnapshot(
          SyncEntityType.entityTag, entityTagId(kind, entityId, tagId));
    });
  }

  Future<void> detach(EntityKind kind, String entityId, String tagId) {
    return _db.transaction(() async {
      final existing = await _entityTagRows(kind, entityId, tagId)
          .getSingleOrNull();
      if (existing == null) return;
      await (_db.delete(_db.entityTags)
            ..where((e) => e.entityId.equals(entityId) &
                e.tagId.equals(tagId) &
                e.entityKind.equalsValue(kind)))
          .go();
      await _ledger.recordDeletion(
          SyncEntityType.entityTag, entityTagId(kind, entityId, tagId),
          revision: existing.revision + 1);
    });
  }

  Future<List<Tag>> tagsFor(EntityKind kind, String entityId) async {
    final rows = await (_db.select(_db.entityTags).join([
      innerJoin(_db.tags, _db.tags.id.equalsExp(_db.entityTags.tagId)),
    ])
          ..where(_db.entityTags.entityId.equals(entityId) &
              _db.entityTags.entityKind.equalsValue(kind))
          ..orderBy([OrderingTerm.asc(_db.tags.manualOrder)]))
        .get();
    return rows.map((r) => r.readTable(_db.tags)).toList();
  }

  /// Реактивный перечень тегов для навигации (§4).
  Stream<List<Tag>> watchAll({bool includeTrashed = false}) =>
      _all(includeTrashed).watch();

  Future<List<Tag>> listAll({bool includeTrashed = false}) =>
      _all(includeTrashed).get();

  // --- внутренние ---

  SimpleSelectStatement<$TagsTable, Tag> _all(bool includeTrashed) =>
      _db.select(_db.tags)
        ..where((t) =>
            includeTrashed ? const Constant(true) : t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.manualOrder)]);

  SimpleSelectStatement<$EntityTagsTable, EntityTag> _entityTagRows(
          EntityKind kind, String entityId, String tagId) =>
      _db.select(_db.entityTags)
        ..where((e) => e.entityId.equals(entityId) &
            e.tagId.equals(tagId) &
            e.entityKind.equalsValue(kind));

  Future<Tag> _get(String id) async =>
      await (_db.select(_db.tags)..where((t) => t.id.equals(id))).getSingle();

  Future<int> _nextOrder() async {
    final maxExp = _db.tags.manualOrder.max();
    final q = _db.selectOnly(_db.tags)..addColumns([maxExp]);
    return (await q.getSingle().then((r) => r.read(maxExp)) ?? 0) + 1;
  }
}

/// Стабильный идентификатор метки для синхронизации (композитный ключ).
String entityTagId(EntityKind kind, String entityId, String tagId) =>
    '${kind.index}:$entityId:$tagId';
