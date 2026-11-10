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
      final order = await _nextStandaloneOrder();
      final id = _uuid.v4();
      await _db.into(_db.taskLists).insert(TaskListsCompanion.insert(
            id: id,
            title: Value(title),
            manualOrder: Value(order),
            modifiedAt: Value(DateTime.now().toUtc()),
          ));
      final created = await _get(id);
      await _ledger.recordUpsert(SyncEntityType.taskList, id, created.toJson());
      return created;
    });
  }

  /// Встроенный список в заметку: embed хранит стабильные block_id (§3).
  Future<TaskList> createInNote(String noteId, String embedBlockId,
      {String? title}) {
    return _db.transaction(() async {
      final note = await (_db.select(_db.notes)
            ..where((n) => n.id.equals(noteId)))
          .getSingleOrNull();
      if (note == null) {
        throw ArgumentError.value(noteId, 'noteId', 'note does not exist');
      }
      final id = _uuid.v4();
      await _db.into(_db.taskLists).insert(TaskListsCompanion.insert(
            id: id,
            title: Value(title),
            noteId: Value(noteId),
            embedBlockId: Value(embedBlockId),
            modifiedAt: Value(DateTime.now().toUtc()),
          ));
      final created = await _get(id);
      await _ledger.recordUpsert(SyncEntityType.taskList, id, created.toJson());
      return created;
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
      if (noteId != null) {
        final note = await (_db.select(_db.notes)
              ..where((n) => n.id.equals(noteId)))
            .getSingleOrNull();
        if (note == null) {
          throw ArgumentError.value(noteId, 'noteId', 'note does not exist');
        }
      }
      await (_db.update(_db.taskLists)..where((l) => l.id.equals(listId)))
          .write(TaskListsCompanion(
        noteId: Value(noteId),
        embedBlockId: Value(embedBlockId),
        modifiedAt: Value(DateTime.now().toUtc()),
      ));
      await _ledger.recordUpsert(
          SyncEntityType.taskList, listId, (await _get(listId)).toJson());
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
        await (_db.update(_db.taskLists)
              ..where((l) => l.id.equals(lists[i].id)))
            .write(TaskListsCompanion(manualOrder: Value(i + 1)));
      }
      await _ledger.recordUpsert(
          SyncEntityType.taskList, listId, (await _get(listId)).toJson());
    });
  }

  /// «Входящие» сверху, самостоятельные в ручном порядке (§4).
  Future<List<TaskList>> listStandalone() =>
      (_db.select(_db.taskLists)
            ..where((l) =>
                l.deletedAt.isNull() &
                l.noteId.isNull() &
                l.isSystem.equals(false))
            ..orderBy([(l) => OrderingTerm.asc(l.manualOrder)]))
          .get();

  /// Список «Входящие» (системный, §3).
  Future<TaskList> inbox() => _get(inboxListId);
  /// Реактивные самостоятельные списки (§4).
  Stream<List<TaskList>> watchStandalone() =>
      (_db.select(_db.taskLists)
            ..where((l) =>
                l.deletedAt.isNull() &
                l.noteId.isNull() &
                l.isSystem.equals(false))
            ..orderBy([(l) => OrderingTerm.asc(l.manualOrder)]))
          .watch();

  /// Реактивные списки, встроенные в заметку.
  Stream<List<TaskList>> watchInNote(String noteId) =>
      (_db.select(_db.taskLists)
            ..where((l) => l.noteId.equals(noteId) & l.deletedAt.isNull())
            ..orderBy([(l) => OrderingTerm.asc(l.manualOrder)]))
          .watch();


  /// Списки, встроенные в заметку.
  Future<List<TaskList>> listInNote(String noteId) =>
      (_db.select(_db.taskLists)
            ..where((l) => l.noteId.equals(noteId) & l.deletedAt.isNull())
            ..orderBy([(l) => OrderingTerm.asc(l.manualOrder)]))
          .get();

  Future<TaskList> get(String id) => _get(id);

  Future<void> moveToTrash(String listId) {
    return _db.transaction(() async {
      final now = DateTime.now().toUtc();
      await (_db.update(_db.taskLists)..where((l) => l.id.equals(listId)))
          .write(TaskListsCompanion(deletedAt: Value(now), modifiedAt: Value(now)));
      await _ledger.recordDeletion(SyncEntityType.taskList, listId);
      // Задачи списка уходят в корзину отдельно решением пользователя (§11);
      // самостоятельный список без задач сохраняется в корзине как строка.
    });
  }

  Future<void> restoreFromTrash(String listId) {
    return _db.transaction(() async {
      await (_db.update(_db.taskLists)..where((l) => l.id.equals(listId)))
          .write(TaskListsCompanion(
              deletedAt: Value(null),
              modifiedAt: Value(DateTime.now().toUtc())));
      await _ledger.recordUpsert(
          SyncEntityType.taskList, listId, (await _get(listId)).toJson());
    });
  }

  // --- внутренние ---

  Future<void> _mutate(String listId, TaskListsCompanion changes) {
    return _db.transaction(() async {
      await (_db.update(_db.taskLists)..where((l) => l.id.equals(listId)))
          .write(changes.copyWith(
              modifiedAt: Value(DateTime.now().toUtc())));
      await _db.customStatement(
          'UPDATE task_lists SET revision = revision + 1 WHERE id = ?',
          [listId]);
      await _ledger.recordUpsert(
          SyncEntityType.taskList, listId, (await _get(listId)).toJson());
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
