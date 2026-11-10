/// Задачи (§3, §4, §6): дерево в одном списке, запрет циклов, перенос ветки
/// целиком, выполнение, срок как DueSpec.
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';
import 'outbox_ledger.dart';

class TasksService {
  final AppDatabase _db;
  final OutboxLedger _ledger;
  final Uuid _uuid;

  TasksService(this._db, this._ledger, {Uuid? uuid})
      : _uuid = uuid ?? const Uuid();

  /// Создание задачи; подзадача всегда в списке родителя (§3).
  Future<Task> create(
    String listId, {
    String? parentId,
    required String text,
    String description = '',
    DueSpec due = const DueSpec.none(),
    Priority priority = Priority.normal,
  }) {
    return _db.transaction(() async {
      await _ensureListExists(listId);
      if (parentId != null) {
        final parent = await _get(parentId);
        if (parent.listId != listId) {
          throw ArgumentError.value(listId, 'listId',
              'parent belongs to another list (§3)');
        }
      }
      final order = await _nextSiblingOrder(listId, parentId);
      final id = _uuid.v4();
      await _db.into(_db.tasks).insert(TasksCompanion.insert(
            id: id,
            listId: listId,
            content: text,
            parentId: Value(parentId),
            description: Value(description),
            priority: Value(priority),
            dueKind: Value(due.kind),
            dueDate: Value(due.date),
            dueMinutes: Value(due.minutes),
            manualOrder: Value(order),
            modifiedAt: Value(DateTime.now().toUtc()),
          ));
      final created = await _get(id);
      await _ledger.recordUpsert(SyncEntityType.task, id, created.toJson());
      return created;
    });
  }

  Future<void> updateText(String id, String text) =>
      _mutate(id, (t) => TasksCompanion(content: Value(text)));

  Future<void> updateDescription(String id, String description) =>
      _mutate(id, (t) => TasksCompanion(description: Value(description)));

  /// Срок: дата без времени и локальная дата-время — разные типы (§3).
  Future<void> setDue(String id, DueSpec due) => _mutate(
        id,
        (t) => TasksCompanion(
          dueKind: Value(due.kind),
          dueDate: Value(due.date),
          dueMinutes: Value(due.minutes),
        ),
      );

  Future<void> setPriority(String id, Priority priority) =>
      _mutate(id, (t) => TasksCompanion(priority: Value(priority)));

  /// Отметка выполнения. Подтверждение «выполнить всю ветку» — решение UI
  /// через [hasIncompleteDescendants] (§6); сервис выполняет ровно то,
  /// что сказано.
  Future<void> setCompleted(String id, bool completed) => _mutate(
        id,
        (t) => TasksCompanion(
            completedAt:
                Value(completed ? DateTime.now().toUtc() : null)),
      );

  /// Есть ли незавершённые потомки — для подтверждения (§6).
  Future<bool> hasIncompleteDescendants(String id) async {
    final row = await _db
        .customSelect(
      'WITH RECURSIVE sub(id) AS ('
      'SELECT id FROM tasks WHERE id = ? '
      'UNION ALL '
      'SELECT c.id FROM tasks c JOIN sub ON c.parent_id = sub.id) '
      'SELECT COUNT(*) AS n FROM sub JOIN tasks x ON x.id = sub.id '
      'WHERE x.completed_at IS NULL',
      variables: [Variable(id)],
      readsFrom: {_db.tasks},
    )
        .getSingle();
    // сама задача тоже попадает в выборку; исключаем её
    final self = await _get(id);
    final n = row.data['n'] as int;
    return self.completedAt == null ? n > 1 : n > 0;
  }

  /// Перенос задачи с веткой в другой список и/или под нового родителя.
  /// Возможен независимо от сортировки (§4); циклический перенос запрещён.
  Future<void> moveBranch(
    String id, {
    required String newListId,
    String? newParentId,
  }) {
    return _db.transaction(() async {
      if (newParentId == id) {
        throw ArgumentError('cannot attach task to itself');
      }
      if (newParentId != null) {
        final parent = await _get(newParentId);
        if (parent.listId != newListId) {
          throw ArgumentError.value(newListId, 'newListId',
              'new parent belongs to another list (§3)');
        }
        if (await _isDescendant(newParentId, id)) {
          throw StateError('cannot move task inside its own subtree (§4)');
        }
      }
      final now = DateTime.now().toUtc();
      // Переносим ветку целиком: идентификаторы, структура, сроки и
      // напоминания сохраняются; источник обновляется (§4).
      final subIds = await _subtreeIds(id);
      await (_db.update(_db.tasks)..where((t) => t.id.isIn(subIds))).write(
        TasksCompanion(listId: Value(newListId), modifiedAt: Value(now)),
      );
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          parentId: Value(newParentId),
          modifiedAt: Value(now),
        ),
      );
      for (final tid in subIds) {
        await _ledger.recordUpsert(
            SyncEntityType.task, tid, (await _get(tid)).toJson());
      }
    });
  }

  /// Ручной порядок среди соседей: ставим задачу после [afterId]
  /// (null — в начало). Доступно в ручном режиме; перенос между списками
  /// и смена родителя — независимо от сортировки (§4).
  Future<void> reorder(String id, {String? afterId}) {
    return _db.transaction(() async {
      final task = await _get(id);
      final siblings = await _siblingsOrdered(task.listId, task.parentId);
      siblings.removeWhere((t) => t.id == id);
      final anchorIndex =
          afterId == null ? -1 : siblings.indexWhere((t) => t.id == afterId);
      if (afterId != null && anchorIndex < 0) {
        throw ArgumentError.value(afterId, 'afterId', 'not a sibling');
      }
      siblings.insert(anchorIndex + 1, task);
      await _renumber(siblings);
      await _ledger.recordUpsert(
          SyncEntityType.task, id, (await _get(id)).toJson());
    });
  }

  /// Корзина: вся ветка целиком, восстановление целиком (§11).
  Future<void> moveBranchToTrash(String id) {
    return _db.transaction(() async {
      final now = DateTime.now().toUtc();
      final subIds = await _subtreeIds(id);
      await (_db.update(_db.tasks)..where((t) => t.id.isIn(subIds)))
          .write(TasksCompanion(deletedAt: Value(now), modifiedAt: Value(now)));
      for (final tid in subIds) {
        await _ledger.recordDeletion(SyncEntityType.task, tid);
      }
    });
  }

  /// Восстановление ветки целиком (§11).
  Future<void> restoreBranchFromTrash(String id) {
    return _db.transaction(() async {
      final subIds = await _subtreeIds(id);
      await (_db.update(_db.tasks)..where((t) => t.id.isIn(subIds)))
          .write(TasksCompanion(deletedAt: Value(null), modifiedAt: Value(DateTime.now().toUtc())));
      for (final tid in subIds) {
        await _ledger.recordUpsert(
            SyncEntityType.task, tid, (await _get(tid)).toJson());
      }
    });
  }

  Future<Task> get(String id) => _get(id);
  /// Все активные задачи списка в ручном порядке (для embed-карточки).
  Stream<List<Task>> watchActiveInList(String listId) =>
      (_db.select(_db.tasks)
            ..where((t) => t.listId.equals(listId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.manualOrder)]))
          .watch();

  /// Выполненные корневые задачи списка (область «Виконані», §4).
  Stream<List<Task>> watchCompletedRoots(String listId) =>
      (_db.select(_db.tasks)
            ..where((t) =>
                t.listId.equals(listId) &
                t.deletedAt.isNull() &
                t.parentId.isNull() &
                t.completedAt.isNotNull())
            ..orderBy([(t) => OrderingTerm.desc(t.completedAt)]))
          .watch();


  /// Активные (не в корзине) задачи списка в ручном порядке.
  Future<List<Task>> listActiveInList(String listId) =>
      (_db.select(_db.tasks)
            ..where((t) => t.listId.equals(listId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.manualOrder)]))
          .get();

  /// Выполненные корневые задачи списка — для сворачиваемой области
  /// «Виконані» (§4); выполняют запрос, группировка на UI.
  Future<List<Task>> listCompletedRoots(String listId) =>
      (_db.select(_db.tasks)
            ..where((t) =>
                t.listId.equals(listId) &
                t.deletedAt.isNull() &
                t.parentId.isNull() &
                t.completedAt.isNotNull())
            ..orderBy([(t) => OrderingTerm.desc(t.completedAt)]))
          .get();

  Future<List<Task>> children(String parentId) =>
      (_db.select(_db.tasks)
            ..where((t) => t.parentId.equals(parentId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.asc(t.manualOrder)]))
          .get();

  // --- внутренние ---

  Future<void> _mutate(
      String id, TasksCompanion Function(Task current) build) {
    return _db.transaction(() async {
      final current = await _get(id);
      await (_db.update(_db.tasks)..where((t) => t.id.equals(id))).write(
        build(current).copyWith(modifiedAt: Value(DateTime.now().toUtc())),
      );
      await _db.customStatement(
          'UPDATE tasks SET revision = revision + 1 WHERE id = ?', [id]);
      await _ledger.recordUpsert(
          SyncEntityType.task, id, (await _get(id)).toJson());
    });
  }

  Future<Task> _get(String id) async =>
      await (_db.select(_db.tasks)..where((t) => t.id.equals(id)))
          .getSingle();

  Future<void> _ensureListExists(String listId) async {
    final exists = await (_db.select(_db.taskLists)
          ..where((l) => l.id.equals(listId)))
        .getSingleOrNull();
    if (exists == null) {
      throw ArgumentError.value(listId, 'listId', 'task list does not exist');
    }
  }

  Future<int> _nextSiblingOrder(String listId, String? parentId) async {
    final maxExp = _db.tasks.manualOrder.max();
    final q = _db.selectOnly(_db.tasks)..addColumns([maxExp]);
    q.where(_db.tasks.listId.equals(listId) &
        (parentId == null
            ? _db.tasks.parentId.isNull()
            : _db.tasks.parentId.equals(parentId)));
    return (await q.getSingle().then((r) => r.read(maxExp)) ?? 0) + 1;
  }

  Future<List<Task>> _siblingsOrdered(String listId, String? parentId) =>
      (_db.select(_db.tasks)
            ..where((t) => t.listId.equals(listId) &
                (parentId == null
                    ? t.parentId.isNull()
                    : t.parentId.equals(parentId)))
            ..orderBy([(t) => OrderingTerm.asc(t.manualOrder)]))
          .get();

  Future<void> _renumber(List<Task> siblings) async {
    for (var i = 0; i < siblings.length; i++) {
      await (_db.update(_db.tasks)..where((t) => t.id.equals(siblings[i].id)))
          .write(TasksCompanion(manualOrder: Value(i + 1)));
    }
  }

  Future<bool> _isDescendant(String candidateId, String ancestorId) async {
    var current = candidateId;
    for (var i = 0; i < 4096; i++) {
      if (current == ancestorId) return true;
      final t = await (_db.select(_db.tasks)
            ..where((t) => t.id.equals(current)))
          .getSingleOrNull();
      final parent = t?.parentId;
      if (parent == null) return false;
      current = parent;
    }
    return true;
  }

  Future<List<String>> _subtreeIds(String rootId) async {
    final rows = await _db
        .customSelect(
      'WITH RECURSIVE sub(id) AS ('
      'SELECT id FROM tasks WHERE id = ? '
      'UNION ALL '
      'SELECT c.id FROM tasks c JOIN sub ON c.parent_id = sub.id) '
      'SELECT id FROM sub',
      variables: [Variable(rootId)],
      readsFrom: {_db.tasks},
    )
        .get();
    return rows.map((r) => r.data['id'] as String).toList();
  }
}
