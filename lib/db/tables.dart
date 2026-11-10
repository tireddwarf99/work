/// Схема хранения (§3): базовые сущности, служебные таблицы синхронизации.
///
/// Постоянные UUID не зависят от пути, заголовка и позиции. Служебные колонки
/// синхронизации вынесены в [SyncColumns]; Soft delete — `deletedAt`, физическое
/// удаление порождает запись в `DeletionMarkers` (§10).
library;

import 'package:drift/drift.dart';

import '../domain/due_spec.dart';

/// Общие служебные колонки синхронизируемых таблиц (§10).
mixin SyncColumns on Table {
  /// Ревизия записи; растёт при каждой локальной мутации.
  IntColumn get revision => integer().withDefault(const Constant(1))();

  /// Ревизия общей базы, от которой выполнено изменение (для автослияния).
  IntColumn get baseRevision => integer().withDefault(const Constant(0))();

  /// UTC-момент последней мутации.
  DateTimeColumn get modifiedAt =>
      dateTime().withDefault(currentDateAndTime)();

  /// Идентификатор устройства, выполнившего мутацию.
  TextColumn get deviceId => text().withDefault(const Constant(''))();

  /// Soft delete: момент перемещения в корзину (§11).
  DateTimeColumn get deletedAt => dateTime().nullable()();
}

@TableIndex(name: 'idx_folders_parent', columns: {#parentId})
class Folders extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get parentId => text().nullable().references(Folders, #id)();
  TextColumn get name => text()();
  IntColumn get manualOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_notes_folder_pin', columns: {#folderId, #pinned, #pinOrder})
@TableIndex(name: 'idx_notes_modified', columns: {#modifiedAt})
class Notes extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get folderId => text().nullable().references(Folders, #id)();

  /// Необязательный заголовок (§3).
  TextColumn get title => text().nullable()();

  /// Документ Quill Delta JSON с версией формата (§3).
  TextColumn get delta => text().withDefault(const Constant(''))();
  IntColumn get deltaFormatVersion => integer().withDefault(const Constant(1))();

  /// Простой текст документа для FTS; поддерживается сервисом заметок.
  TextColumn get searchText => text().withDefault(const Constant(''))();

  /// Закреплённые выше остальных; порядок закрепления ручной (§4).
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  IntColumn get pinOrder => integer().nullable()();
  IntColumn get manualOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_task_lists_note', columns: {#noteId})
class TaskLists extends Table with SyncColumns {
  TextColumn get id => text()();

  /// Необязательный заголовок; NULL отображается как «Без названия» (§4).
  TextColumn get title => text().nullable()();

  /// Самостоятельный список либо встроенный в заметку (§3).
  TextColumn get noteId => text().nullable().references(Notes, #id)();
  TextColumn get embedBlockId => text().nullable()();
  IntColumn get manualOrder => integer().withDefault(const Constant(0))();
  IntColumn get sortMode => intEnum<SortMode>()
      .withDefault(const Constant(0))();

  /// Системный список «Входящие» (§3): постоянный, без создания.
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_tasks_list_parent', columns: {#listId, #parentId})
@TableIndex(name: 'idx_tasks_due', columns: {#dueKind, #dueDate})
@TableIndex(name: 'idx_tasks_completed', columns: {#completedAt})
@TableIndex(name: 'idx_tasks_priority', columns: {#priority})
@TableIndex(name: 'idx_tasks_series', columns: {#seriesId})
class Tasks extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get listId => text().references(TaskLists, #id)();

  /// Родитель в том же списке; вся ветка принадлежит одному списку (§3).
  TextColumn get parentId => text().nullable().references(Tasks, #id)();

  /// Текст задачи — не дублируется в тексте заметки (embed хранит id).
  /// SQL-колонка называется `text` (её ждут FTS-триггеры).
  TextColumn get content => text().named('text')();

  /// Простое текстовое описание (§3).
  TextColumn get description => text().withDefault(const Constant(''))();

  /// Момент выполнения; NULL — не выполнена.
  DateTimeColumn get completedAt => dateTime().nullable()();

  IntColumn get priority => intEnum<Priority>()
      .withDefault(const Constant(1))();

  /// Срок: kind + календарная дата + минуты локального дня (§3).
  IntColumn get dueKind => intEnum<DueKind>()
      .withDefault(const Constant(0))();
  TextColumn get dueDate => text().nullable()();
  IntColumn get dueMinutes => integer().nullable()();

  IntColumn get manualOrder => integer().withDefault(const Constant(0))();

  /// Повторение задаётся только корневой задаче (§3).
  TextColumn get seriesId => text().nullable()();
  IntColumn get ordinal => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_tags_order', columns: {#manualOrder})
class Tags extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get manualOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Метки заметок и задач; теги заметки не наследуются задачами (§3).
@TableIndex(name: 'idx_entity_tags_tag', columns: {#tagId})
class EntityTags extends Table with SyncColumns {
  TextColumn get entityId => text()();
  TextColumn get tagId => text().references(Tags, #id)();
  IntColumn get entityKind => intEnum<EntityKind>()();

  @override
  Set<Column> get primaryKey => {entityId, tagId, entityKind};
}

@TableIndex(name: 'idx_recurrence_task', columns: {#taskId}, unique: true)
class RecurrenceRules extends Table with SyncColumns {
  TextColumn get id => text()();

  /// Только корневая задача (§3).
  TextColumn get taskId => text().references(Tasks, #id)();
  IntColumn get kind => intEnum<RecurrenceKind>()();

  /// Паттерн правила в JSON: календарное расписание или интервал (§6).
  TextColumn get pattern => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Детерминированное выполнение серии: id = hash(seriesId, ordinal) — два
/// устройства не создают две следующие задачи одной серии (§6).
@TableIndex(name: 'idx_occurrences_series', columns: {#seriesId, #ordinal}, unique: true)
class TaskOccurrences extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get seriesId => text()();
  IntColumn get ordinal => integer()();

  /// Запланированный срок выполнения (тип как у задачи).
  TextColumn get dueDate => text().nullable()();
  IntColumn get dueMinutes => integer().nullable()();

  /// Заполняются только для выполненных/пропущенных выполнений (§3).
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get skippedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_reminders_task', columns: {#taskId})
class Reminders extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get taskId => text().references(Tasks, #id)();
  IntColumn get kind => intEnum<ReminderKind>()();

  /// Относительное: за столько минут до срока (§7).
  IntColumn get offsetMinutes => integer().nullable()();

  /// Абсолютное: конкретная локальная дата-время (§7).
  TextColumn get localDate => text().nullable()();
  IntColumn get localMinutes => integer().nullable()();

  /// Отсрочка конкретного напоминания (§7) — локальный момент ISO.
  TextColumn get snoozedUntil => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Нерешённые конфликты слияния (§10).
class Conflicts extends Table {
  TextColumn get id => text()();
  IntColumn get entityType => intEnum<SyncEntityType>()();
  TextColumn get entityId => text()();
  TextColumn get kind => text()();
  TextColumn get basePayload => text().nullable()();
  TextColumn get localPayload => text()();
  TextColumn get remotePayload => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Исходящие операции: мутация и запись outbox — одна транзакция (§10).
class OutboxEntries extends Table {
  TextColumn get operationId => text()();
  IntColumn get entityType => intEnum<SyncEntityType>()();
  TextColumn get entityId => text()();
  TextColumn get changeKind => text()(); // 'upsert' | 'delete'
  TextColumn get payload => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {operationId};
}

/// Состояние синхронизации: одна строка (id = 1) (§10).
class SyncState extends Table {
  IntColumn get id => integer()();
  IntColumn get workspaceEpoch => integer().withDefault(const Constant(1))();
  IntColumn get commitCursor => integer().withDefault(const Constant(0))();
  IntColumn get serverOffsetMs => integer().withDefault(const Constant(0))();

  /// Монотонный локальный счётчик для упорядочивания событий (§10).
  IntColumn get localCounter => integer().withDefault(const Constant(0))();
  TextColumn get deviceId => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Компактные маркеры удаления без текста (§10); не удаляются по сроку 30 дней.
class DeletionMarkers extends Table {
  TextColumn get entityId => text()();
  IntColumn get entityType => intEnum<SyncEntityType>()();
  TextColumn get deletedAtUtc => text()();
  IntColumn get revision => integer()();

  @override
  Set<Column> get primaryKey => {entityType, entityId};
}

/// Последняя общая подтверждённая база записи (§10): снапшот payload +
/// ревизия базы для трёхстороннего автослияния.
class SyncBase extends Table {
  TextColumn get entityId => text()();
  IntColumn get entityType => intEnum<SyncEntityType>()();
  TextColumn get payload => text()();

  /// Ревизия сущности, зафиксированная в этой базе.
  IntColumn get baseRevision => integer()();

  @override
  Set<Column> get primaryKey => {entityType, entityId};
}

/// Настройки конкретного устройства (§8): тема, уведомления, автозапуск.
class DeviceSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Общие синхронизируемые настройки и сортировки (§8).
class SharedSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
