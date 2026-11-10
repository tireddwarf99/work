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

/// Даты в JSON — ISO-строки (а не миллисекунды), как в облачном payload.
const ValueSerializer _isoSerializer =
    ValueSerializer.defaults(serializeDateTimeValuesAsString: true);

const Set<String> _dateKeys = {
  'modified_at',
  'deleted_at',
  'completed_at',
  'skipped_at',
};

/// Приведение снапшота из outbox к облачному формату: ключи snake_case,
/// даты — ISO UTC (сервисы пишут `toJson()` с camelCase и датами в мс).
Map<String, Object?> canonicalPayload(Map<String, Object?> payload) {
  return {
    for (final e in payload.entries)
      _payloadKey(e.key): _dateKeys.contains(_payloadKey(e.key)) &&
              e.value is int
          ? DateTime.fromMillisecondsSinceEpoch(e.value as int, isUtc: true)
              .toIso8601String()
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
      await db.reminders.insertOnConflictUpdate(
            RemindersCompanion.insert(
              id: entityId,
              taskId: payload['task_id'] as String? ?? '',
              kind: _enumAt(ReminderKind.values, payload['kind'] as int?),
              offsetMinutes: Value(payload['offset_minutes'] as int?),
              localDate: Value(payload['local_date'] as String?),
              localMinutes: Value(payload['local_minutes'] as int?),
              snoozedUntil: Value(payload['snoozed_until'] as String?),
              revision: Value(payload['revision'] as int? ?? 1),
              baseRevision: Value(payload['base_revision'] as int? ?? 0),
              modifiedAt: Value(parseDate(payload['modified_at']) ??
                  DateTime.now().toUtc()),
              deviceId: Value(payload['device_id'] as String? ?? ''),
              deletedAt: Value(parseDate(payload['deleted_at'])),
            ),
          );
      return 1;

    case SyncEntityType.recurrenceRule:
      await db.recurrenceRules.insertOnConflictUpdate(
            RecurrenceRulesCompanion.insert(
              id: entityId,
              taskId: payload['task_id'] as String? ?? '',
              kind: _enumAt(RecurrenceKind.values, payload['kind'] as int?),
              pattern: payload['pattern'] as String? ?? '{}',
              revision: Value(payload['revision'] as int? ?? 1),
              baseRevision: Value(payload['base_revision'] as int? ?? 0),
              modifiedAt: Value(parseDate(payload['modified_at']) ??
                  DateTime.now().toUtc()),
              deviceId: Value(payload['device_id'] as String? ?? ''),
              deletedAt: Value(parseDate(payload['deleted_at'])),
            ),
          );
      return 1;

    case SyncEntityType.taskOccurrence:
      await db.taskOccurrences.insertOnConflictUpdate(
            TaskOccurrencesCompanion.insert(
              id: entityId,
              seriesId: payload['series_id'] as String? ?? '',
              ordinal: payload['ordinal'] as int? ?? 0,
              dueDate: Value(payload['due_date'] as String?),
              dueMinutes: Value(payload['due_minutes'] as int?),
              completedAt: Value(parseDate(payload['completed_at'])),
              skippedAt: Value(parseDate(payload['skipped_at'])),
              revision: Value(payload['revision'] as int? ?? 1),
              baseRevision: Value(payload['base_revision'] as int? ?? 0),
              modifiedAt: Value(parseDate(payload['modified_at']) ??
                  DateTime.now().toUtc()),
              deviceId: Value(payload['device_id'] as String? ?? ''),
              deletedAt: Value(parseDate(payload['deleted_at'])),
            ),
          );
      return 1;
  }
}

/// Значение перечисления по индексу; неизвестный индекс — первый элемент
/// (payload от более новой версии не должен ронять pull).
T _enumAt<T>(List<T> values, int? index) =>
    index != null && index >= 0 && index < values.length
        ? values[index]
        : values.first;

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
      row = f?.toJson(serializer: _isoSerializer);
      break;
    case SyncEntityType.note:
      final n = await (db.select(db.notes)..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = n?.toJson(serializer: _isoSerializer);
      break;
    case SyncEntityType.taskList:
      final l = await (db.select(db.taskLists)
            ..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = l?.toJson(serializer: _isoSerializer);
      break;
    case SyncEntityType.task:
      final t = await (db.select(db.tasks)..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = t?.toJson(serializer: _isoSerializer);
      break;
    case SyncEntityType.tag:
      final t = await (db.select(db.tags)..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = t?.toJson(serializer: _isoSerializer);
      break;
    case SyncEntityType.entityTag:
      final parts = entityId.split(':');
      if (parts.length == 3) {
        final e = await (db.select(db.entityTags)
              ..where((x) => x.entityId.equals(parts[1]) &
                  x.tagId.equals(parts[2]) &
                  x.entityKind.equalsNullable(int.parse(parts[0]))))
            .getSingleOrNull();
        row = e?.toJson(serializer: _isoSerializer);
      }
      break;
    case SyncEntityType.reminder:
      final r = await (db.select(db.reminders)
            ..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = r?.toJson(serializer: _isoSerializer);
      break;
    case SyncEntityType.recurrenceRule:
      final r = await (db.select(db.recurrenceRules)
            ..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = r?.toJson(serializer: _isoSerializer);
      break;
    case SyncEntityType.taskOccurrence:
      final o = await (db.select(db.taskOccurrences)
            ..where((x) => x.id.equals(entityId)))
          .getSingleOrNull();
      row = o?.toJson(serializer: _isoSerializer);
      break;
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
