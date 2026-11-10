/// Реактивные выборки для UI: одна запись по id, подзадачи, списки в заметках,
/// теги сущности. Сервисы данных отдают их только разовыми запросами.
library;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';
import 'providers.dart';

/// Список задач по id; null — списка нет или он в корзине.
final taskListProvider =
    StreamProvider.autoDispose.family<TaskList?, String>((ref, id) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.taskLists)
        ..where((l) => l.id.equals(id) & l.deletedAt.isNull()))
      .watchSingleOrNull();
});

/// Заметка по id; null — заметки нет.
final noteProvider = StreamProvider.autoDispose.family<Note?, String>((ref, id) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.notes)..where((n) => n.id.equals(id)))
      .watchSingleOrNull();
});

/// Задача по id; null — задачи нет или она в корзине.
final taskProvider = StreamProvider.autoDispose.family<Task?, String>((ref, id) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.tasks)
        ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
      .watchSingleOrNull();
});

/// Непосредственные подзадачи в ручном порядке.
final subtasksProvider =
    StreamProvider.autoDispose.family<List<Task>, String>((ref, parentId) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.tasks)
        ..where((t) => t.parentId.equals(parentId) & t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.manualOrder)]))
      .watch();
});

/// Списки, встроенные в живые заметки любой папки (§4); списки из заметок
/// в корзине не показываются.
final embeddedListsProvider = StreamProvider.autoDispose<List<TaskList>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final query = db.select(db.taskLists).join([
    innerJoin(db.notes, db.notes.id.equalsExp(db.taskLists.noteId)),
  ])
    ..where(db.taskLists.deletedAt.isNull() & db.notes.deletedAt.isNull())
    ..orderBy([OrderingTerm.asc(db.taskLists.manualOrder)]);
  return query.watch().map(
      (rows) => [for (final row in rows) row.readTable(db.taskLists)]);
});

/// Идентификатор сущности с тегами.
typedef TagTarget = ({EntityKind kind, String id});

/// Теги сущности; после изменения обновляется через `ref.invalidate`.
final tagsForProvider =
    FutureProvider.autoDispose.family<List<Tag>, TagTarget>((ref, target) {
  return ref.watch(tagsServiceProvider).tagsFor(target.kind, target.id);
});

/// Папка по id; null — папки нет или она в корзине.
final folderProvider =
    StreamProvider.autoDispose.family<Folder?, String>((ref, id) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.folders)
        ..where((f) => f.id.equals(id) & f.deletedAt.isNull()))
      .watchSingleOrNull();
});
