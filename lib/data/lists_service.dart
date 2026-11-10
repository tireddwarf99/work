/// Списки задач (§3, §4): самостоятельные и встроенные в заметки, «Входящие»,
/// перенос между заметками, выбранная сортировка.
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';
import 'outbox_ledger.dart';

class TaskListsService {
  final AppDatabase _db;
  final OutboxLedger _ledger;
  final Uuid _uuid;

  TaskListsService(this._db, this._ledger, {Uuid? uuid})
      : _uuid = uuid ?? const Uuid();

  /// Самостоятельный список; неназванные отображаются «Без названия» (§4).
  Future<TaskList> create({String? title}) {
    return _db.transaction(() async {
      final id = _uuid.v4();
      await _db.into(_db.taskLists).insert(TaskListsCompanion.insert(
            id: id,
            title: Value(title),
            manualOrder: Value(await _nextStandaloneOrder()),
            modifiedAt: Value(DateTime.now().toUtc()),
          ));
      await _ledger.recordSnapshot(SyncEntityType.taskList, id);
      return _get(id);
    });
  }

  /// Встроенный список в заметку: embed хранит стабильные block_id (§3).
  Future<TaskList> createInNote(String noteId, String embedBlockId,
      {String? title}) {
    return _db.transaction(() async {
      await _requireNote(noteId);
      final id = _uuid.v4();
      await _db.into(_db.taskLists).insert(TaskListsCompanion.insert(
            id: id,
            title: Value(title),
            noteId: Value(noteId),
            embedBlockId: Value(embedBlockId),
            modifiedAt: Value(DateTime.now().toUtc()),
          ));
      await _ledger.recordSnapshot(SyncEntityType.taskList, id);
      return _get(id);
    });
  }

  /// Перенос списка между заметками и в самостоятельные/обратно (§4):
  /// идентификаторы, задачи, структура, сроки и напоминания сохраняются.
  Future<void> moveEmbed(String listId, String? noteId, String? embedBlockId) {
    return _db.transaction(() async {
      if ((noteId == null) != (embedBlockId == null)) {
        throw ArgumentError(
            'noteId and embedBlockId must be set together (§3)');
      }
      if (noteId != null) await _requireNote(noteId);
      await _mutate(
        listId,
        TaskListsCompanion(
            noteId: Value(noteId), embedBlockId: Value(embedBlockId)),
      );
    });
  }

  Future<void> rename(String listId, String? title) =>
      _mutate(listId, TaskListsCompanion(title: Value(title)));

  Future<void> setSortMode(String listId, SortMode mode) =>
      _mutate(listId, TaskListsCompanion(sortMode: Value(mode)));

  /// Ручной порядок самостоятельных списков (§4): «Входящие» всегда сверху.
  Future<void> reorder(String listId, {String? afterId}) {
    return _db.transaction(() async {
      final lists = await listStandalone();
      lists.removeWhere((l) => l.id == listId);
      final anchorIndex =
          afterId == null ? -1 : lists.indexWhere((l) => l.id == afterId);
      if (afterId != null && anchorIndex < 0) {
        throw ArgumentError.value(afterId, 'afterId', 'not found in order');
      }
      lists.insert(anchorIndex + 1, await _get(listId));
      for (var i = 0; i < lists.length; i++) {
        final current = lists[i];
        if (current.id != listId && current.manualOrder == i + 1) continue;
        await _mutate(
            current.id, TaskListsCompanion(manualOrder: Value(i + 1)));
      }
    });
  }

  /// «Входящие» сверху, самостоятельные в ручном порядке (§4).
  Future<List<TaskList>> listStandalone() => _standalone().get();

  /// Список «Входящие» (системный, §3).
  Future<TaskList> inbox() => _get(inboxListId);

  /// Реактивные самостоятельные списки (§4).
  Stream<List<TaskList>> watchStandalone() => _standalone().watch();

  /// Реактивные списки, встроенные в заметку.
  Stream<List<TaskList>> watchInNote(String noteId) =>
      _inNote(noteId).watch();

  /// Списки, встроенные в заметку.
  Future<List<TaskList>> listInNote(String noteId) => _inNote(noteId).get();

  Future<TaskList> get(String id) => _get(id);

  /// Корзина: список уходит вместе со всеми своими задачами (§11), в один
  /// момент — по нему восстановление отличает задачи, удалённые со списком,
  /// от удалённых раньше. «Входящие» удалить нельзя (§3).
  Future<void> moveToTrash(String listId) {
    return _db.transaction(() async {
      final list = await _get(listId);
      if (list.isSystem) {
        throw ArgumentError.value(listId, 'listId', 'system list (§3)');
      }
      final now = DateTime.now().toUtc();
      final taskIds = await _activeTaskIds(listId);
      await (_db.update(_db.tasks)..where((t) => t.id.isIn(taskIds)))
          .write(TasksCompanion(deletedAt: Value(now)));
      for (final id in taskIds) {
        await _ledger.recordTrashed(SyncEntityType.task, id);
      }
      await (_db.update(_db.taskLists)..where((l) => l.id.equals(listId)))
          .write(TaskListsCompanion(deletedAt: Value(now)));
      await _ledger.recordTrashed(SyncEntityType.taskList, listId);
    });
  }

  /// Восстановление списка и задач, удалённых вместе с ним (§11).
  Future<void> restoreFromTrash(String listId) {
    return _db.transaction(() async {
      final list = await _get(listId);
      final trashedAt = list.deletedAt;
      await (_db.update(_db.taskLists)..where((l) => l.id.equals(listId)))
          .write(TaskListsCompanion(deletedAt: Value(null)));
      await _ledger.recordChange(SyncEntityType.taskList, listId);
      if (trashedAt == null) return;
      final taskIds = await (_db.selectOnly(_db.tasks)
            ..addColumns([_db.tasks.id])
            ..where(_db.tasks.listId.equals(listId) &
                _db.tasks.deletedAt.equals(trashedAt)))
          .map((r) => r.read(_db.tasks.id)!)
          .get();
      await (_db.update(_db.tasks)..where((t) => t.id.isIn(taskIds)))
          .write(TasksCompanion(deletedAt: Value(null)));
      for (final id in taskIds) {
        await _ledger.recordChange(SyncEntityType.task, id);
      }
    });
  }

  // --- внутренние ---

  SimpleSelectStatement<$TaskListsTable, TaskList> _standalone() =>
      _db.select(_db.taskLists)
        ..where((l) =>
            l.deletedAt.isNull() &
            l.noteId.isNull() &
            l.isSystem.equals(false))
        ..orderBy([(l) => OrderingTerm.asc(l.manualOrder)]);

  SimpleSelectStatement<$TaskListsTable, TaskList> _inNote(String noteId) =>
      _db.select(_db.taskLists)
        ..where((l) => l.noteId.equals(noteId) & l.deletedAt.isNull())
        ..orderBy([(l) => OrderingTerm.asc(l.manualOrder)]);

  Future<List<String>> _activeTaskIds(String listId) =>
      (_db.selectOnly(_db.tasks)
            ..addColumns([_db.tasks.id])
            ..where(_db.tasks.listId.equals(listId) &
                _db.tasks.deletedAt.isNull()))
          .map((r) => r.read(_db.tasks.id)!)
          .get();

  Future<void> _requireNote(String noteId) async {
    final note = await (_db.select(_db.notes)
          ..where((n) => n.id.equals(noteId)))
        .getSingleOrNull();
    if (note == null) {
      throw ArgumentError.value(noteId, 'noteId', 'note does not exist');
    }
  }

  Future<void> _mutate(String listId, TaskListsCompanion changes) {
    return _db.transaction(() async {
      await (_db.update(_db.taskLists)..where((l) => l.id.equals(listId)))
          .write(changes);
      await _ledger.recordChange(SyncEntityType.taskList, listId);
    });
  }

  Future<TaskList> _get(String id) async =>
      await (_db.select(_db.taskLists)..where((l) => l.id.equals(id)))
          .getSingle();

  Future<int> _nextStandaloneOrder() async {
    final maxExp = _db.taskLists.manualOrder.max();
    final q = _db.selectOnly(_db.taskLists)
      ..addColumns([maxExp])
      ..where(_db.taskLists.isSystem.equals(false));
    return (await q.getSingle().then((r) => r.read(maxExp)) ?? 0) + 1;
  }
}
