/// Маппинг сущностей между локальной БД и payload-JSON облака (§10):
/// содержимое хранится JSON-строкой в одном поле документа, служебные
/// индексные поля (type/revision/commit_seq/deleted) — рядом.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';

/// payload строки таблицы → JSON-карта (DateTime → ISO UTC, ключи →
/// snake_case; поле `content` задачи наружу называется `text`).
Map<String, Object?> rowToJson(Map<String, Object?> row) {
  return {
    for (final e in row.entries)
      _payloadKey(e.key): e.value is DateTime
          ? (e.value as DateTime).toUtc().toIso8601String()
          : e.value,
  };
}

String _payloadKey(String dartName) {
  final snake = dartName
      .replaceAllMapped(RegExp(r'([A-Z])'), (m) => '_${m.group(1)!.toLowerCase()}');
  return snake == 'content' ? 'text' : snake;
}

/// Применение удалённого payload к локальной таблице (upsert).
/// Возвращает количество затронутых строк.
Future<int> applyPayload(
  AppDatabase db,
  SyncEntityType type,
  String entityId,
  Map<String, Object?> payload,
) async {
  switch (type) {
    case SyncEntityType.folder:
      await db.folders.insertOnConflictUpdate(
            FoldersCompanion.insert(
              id: entityId,
              name: payload['name'] as String? ?? '',
              parentId: Value(payload['parent_id'] as String?),
              manualOrder: Value(payload['manual_order'] as int? ?? 0),
              revision: Value(payload['revision'] as int? ?? 1),
              baseRevision: Value(payload['base_revision'] as int? ?? 0),
              modifiedAt: Value(parseDate(payload['modified_at']) ??
                  DateTime.now().toUtc()),
              deviceId: Value(payload['device_id'] as String? ?? ''),
              deletedAt: Value(parseDate(payload['deleted_at'] as String?)),
            ),
          );
      return 1;

    case SyncEntityType.note:
      await db.notes.insertOnConflictUpdate(
            NotesCompanion.insert(
              id: entityId,
              title: Value(payload['title'] as String?),
              delta: Value(payload['delta'] as String? ?? ''),
              searchText: Value(payload['search_text'] as String? ?? ''),
              pinned: Value(payload['pinned'] as bool? ?? false),
              pinOrder: Value(payload['pin_order'] as int?),
              manualOrder: Value(payload['manual_order'] as int? ?? 0),
              folderId: Value(payload['folder_id'] as String?),
              revision: Value(payload['revision'] as int? ?? 1),
              baseRevision: Value(payload['base_revision'] as int? ?? 0),
              modifiedAt: Value(parseDate(payload['modified_at']) ??
                  DateTime.now().toUtc()),
              deviceId: Value(payload['device_id'] as String? ?? ''),
              deletedAt: Value(parseDate(payload['deleted_at'] as String?)),
            ),
          );
      return 1;

    case SyncEntityType.taskList:
      await db.taskLists.insertOnConflictUpdate(
            TaskListsCompanion.insert(
              id: entityId,
              title: Value(payload['title'] as String?),
              noteId: Value(payload['note_id'] as String?),
              embedBlockId: Value(payload['embed_block_id'] as String?),
              manualOrder: Value(payload['manual_order'] as int? ?? 0),
              sortMode: Value(SortMode.values[(payload['sort_mode'] as int?) ?? 0]),
              isSystem: Value(payload['is_system'] as bool? ?? false),
              revision: Value(payload['revision'] as int? ?? 1),
              baseRevision: Value(payload['base_revision'] as int? ?? 0),
              modifiedAt: Value(parseDate(payload['modified_at']) ??
                  DateTime.now().toUtc()),
              deviceId: Value(payload['device_id'] as String? ?? ''),
              deletedAt: Value(parseDate(payload['deleted_at'] as String?)),
            ),
          );
      return 1;

    case SyncEntityType.task:
      await db.tasks.insertOnConflictUpdate(
            TasksCompanion.insert(
              id: entityId,
              listId: payload['list_id'] as String? ?? inboxListId,
              parentId: Value(payload['parent_id'] as String?),
              content: payload['text'] as String? ?? '',
              description: Value(payload['description'] as String? ?? ''),
              completedAt:
                  Value(parseDate(payload['completed_at'] as String?)),
              priority: Value(Priority.values[(payload['priority'] as int?) ?? 1]),
              dueKind: Value(DueKind.values[(payload['due_kind'] as int?) ?? 0]),
              dueDate: Value(payload['due_date'] as String?),
              dueMinutes: Value(payload['due_minutes'] as int?),
              manualOrder: Value(payload['manual_order'] as int? ?? 0),
              seriesId: Value(payload['series_id'] as String?),
              ordinal: Value(payload['ordinal'] as int?),
              revision: Value(payload['revision'] as int? ?? 1),
              baseRevision: Value(payload['base_revision'] as int? ?? 0),
              modifiedAt: Value(parseDate(payload['modified_at']) ??
                  DateTime.now().toUtc()),
              deviceId: Value(payload['device_id'] as String? ?? ''),
              deletedAt: Value(parseDate(payload['deleted_at'] as String?)),
            ),
          );
      return 1;

    case SyncEntityType.tag:
      await db.tags.insertOnConflictUpdate(
            TagsCompanion.insert(
              id: entityId,
              name: payload['name'] as String? ?? '',
              manualOrder: Value(payload['manual_order'] as int? ?? 0),
              revision: Value(payload['revision'] as int? ?? 1),
              baseRevision: Value(payload['base_revision'] as int? ?? 0),
              modifiedAt: Value(parseDate(payload['modified_at']) ??
                  DateTime.now().toUtc()),
              deviceId: Value(payload['device_id'] as String? ?? ''),
              deletedAt: Value(parseDate(payload['deleted_at'] as String?)),
            ),
          );
      return 1;

    case SyncEntityType.entityTag:
      final entityIdValue = payload['entity_id'] as String? ?? '';
      final tagId = payload['tag_id'] as String? ?? '';
      await db.entityTags.insertOnConflictUpdate(
            EntityTagsCompanion.insert(
              entityId: entityIdValue,
              tagId: tagId,
              entityKind: EntityKind.values[(payload['entity_kind'] as int?) ?? 0],
              revision: Value(payload['revision'] as int? ?? 1),
              baseRevision: Value(payload['base_revision'] as int? ?? 0),
              modifiedAt: Value(parseDate(payload['modified_at']) ??
                  DateTime.now().toUtc()),
              deviceId: Value(payload['device_id'] as String? ?? ''),
              deletedAt: Value(parseDate(payload['deleted_at'] as String?)),
            ),
          );
      return 1;

    case SyncEntityType.reminder:
    case SyncEntityType.recurrenceRule:
    case SyncEntityType.taskOccurrence:
      // Эти типы наполняются на этапах повторений/напоминаний; пустые
      // payload не доходят до сюда (outbox их не создаёт).
      return 0;
  }
}

/// Физическое удаление сущности локально (для маркеров удалений после
/// того, как локальная запись уже была удалена и вычищена).
Future<void> hardDeleteEntity(
  AppDatabase db,
  SyncEntityType type,
  String entityId,
) async {
  switch (type) {
    case SyncEntityType.folder:
      await (db.delete(db.folders)..where((f) => f.id.equals(entityId))).go();
      break;
    case SyncEntityType.note:
      await (db.delete(db.notes)..where((n) => n.id.equals(entityId))).go();
      break;
    case SyncEntityType.taskList:
      await (db.delete(db.taskLists)..where((l) => l.id.equals(entityId)))
          .go();
      break;
    case SyncEntityType.task:
      await (db.delete(db.tasks)..where((t) => t.id.equals(entityId))).go();
      break;
    case SyncEntityType.tag:
      await (db.delete(db.tags)..where((t) => t.id.equals(entityId))).go();
      break;
    case SyncEntityType.entityTag:
      final parts = entityId.split(':');
      if (parts.length == 3) {
        await (db.delete(db.entityTags)
              ..where((e) => e.entityId.equals(parts[1]) &
                  e.tagId.equals(parts[2]) &
                  e.entityKind.equalsNullable(int.parse(parts[0]))))
            .go();
      }
      break;
    case SyncEntityType.reminder:
    case SyncEntityType.recurrenceRule:
    case SyncEntityType.taskOccurrence:
      break;
  }
}

/// Считывание текущего payload сущности для базы слияния (sync_base).
Future<Map<String, Object?>?> readEntityPayload(
  AppDatabase db,
  SyncEntityType type,
  String entityId,
) async {
  Map<String, Object?>? row;
  switch (type) {
    case SyncEntityType.folder:
      final f = await (db.select(db.folders)..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = f?.toJson();
      break;
    case SyncEntityType.note:
      final n = await (db.select(db.notes)..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = n?.toJson();
      break;
    case SyncEntityType.taskList:
      final l = await (db.select(db.taskLists)
            ..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = l?.toJson();
      break;
    case SyncEntityType.task:
      final t = await (db.select(db.tasks)..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = t?.toJson();
      break;
    case SyncEntityType.tag:
      final t = await (db.select(db.tags)..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = t?.toJson();
      break;
    case SyncEntityType.entityTag:
      final parts = entityId.split(':');
      if (parts.length == 3) {
        final e = await (db.select(db.entityTags)
              ..where((x) => x.entityId.equals(parts[1]) &
                  x.tagId.equals(parts[2]) &
                  x.entityKind.equalsNullable(int.parse(parts[0]))))
            .getSingleOrNull();
        row = e?.toJson();
      }
      break;
    case SyncEntityType.reminder:
    case SyncEntityType.recurrenceRule:
    case SyncEntityType.taskOccurrence:
      return null;
  }
  return row == null ? null : rowToJson(row);
}

DateTime? parseDate(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value)?.toUtc();
  }
  return null;
}

String encodePayload(Map<String, Object?> payload) => jsonEncode(payload);

Map<String, Object?> decodePayload(String json) {
  final decoded = jsonDecode(json);
  return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
}
