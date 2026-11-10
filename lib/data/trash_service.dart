/// Корзина (§11): 30 дней от исходного удаления, без продления из-за
/// синхронизации. Восстановление прежней структуры; исчезнувшая папка —
/// восстановление в «Без папки» с пояснением.
library;

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';
import 'outbox_ledger.dart';
import 'tags_service.dart' show entityTagId;

class TrashService {
  final AppDatabase _db;
  final OutboxLedger _ledger;

  TrashService(this._db, this._ledger);

  /// Срок хранения: 30 дней от исходного удаления (§11).
  static const Duration retention = Duration(days: 30);

  /// Реактивное содержимое корзины (§11).
  Stream<List<Note>> watchTrashedNotes() =>
      (_db.select(_db.notes)
            ..where((n) => n.deletedAt.isNotNull())
            ..orderBy([(n) => OrderingTerm.desc(n.deletedAt)]))
          .watch();

  Stream<List<Folder>> watchTrashedFolders() =>
      (_db.select(_db.folders)
            ..where((f) => f.deletedAt.isNotNull())
            ..orderBy([(f) => OrderingTerm.desc(f.deletedAt)]))
          .watch();

  Stream<List<TaskList>> watchTrashedLists() =>
      (_db.select(_db.taskLists)
            ..where((l) => l.deletedAt.isNotNull())
            ..orderBy([(l) => OrderingTerm.desc(l.deletedAt)]))
          .watch();

  Stream<List<Task>> watchTrashedTasks() =>
      (_db.select(_db.tasks)
            ..where((t) => t.deletedAt.isNotNull())
            ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]))
          .watch();

  /// Восстановление заметки. Возвращает true, если заметка изначально была
  /// в папке, которая удалена, — тогда она восстановлена в «Без папки»
  /// (UI показывает пояснение, §11).
  Future<bool> restoreNote(String noteId) {
    return _db.transaction(() async {
      final note = await (_db.select(
        _db.notes,
      )..where((n) => n.id.equals(noteId))).getSingle();
      var movedToNoFolder = false;
      String? folderId = note.folderId;
      if (folderId != null) {
        final folder = await (_db.select(
          _db.folders,
        )..where((f) => f.id.equals(folderId!))).getSingleOrNull();
        if (folder == null || folder.deletedAt != null) {
          folderId = null;
          movedToNoFolder = true;
        }
      }
      await (_db.update(_db.notes)..where((n) => n.id.equals(noteId))).write(
        NotesCompanion(deletedAt: const Value(null), folderId: Value(folderId)),
      );
      await _ledger.recordChange(SyncEntityType.note, noteId);
      return movedToNoFolder;
    });
  }

  /// Восстановление папки вместе с деревом (§11).
  Future<void> restoreFolder(String folderId) {
    return _db.transaction(() async {
      final ids = await _folderSubtreeIds(folderId);
      await (_db.update(_db.folders)..where((f) => f.id.isIn(ids))).write(
        const FoldersCompanion(deletedAt: Value(null)),
      );
      for (final id in ids) {
        await _ledger.recordChange(SyncEntityType.folder, id);
      }
    });
  }

  /// Физическое удаление просроченных записей (§10, §11): компактные маркеры
  /// без текста остаются, чтобы давно офлайн-устройство не воскресило данные.
  ///
  /// Порядок — от зависимых к родителям (задачи → списки → заметки → папки),
  /// внешние ключи при этом соблюдаются. Всё, что нельзя удалять вместе с
  /// родителем, сохраняется: подзадачи и подпапки поднимаются на уровень
  /// выше, заметки удалённой папки уходят в «Без папки», списки удалённой
  /// заметки становятся самостоятельными. Задачи списка удаляются с ним.
  /// Возвращает число окончательно удалённых записей.
  Future<int> purgeExpired({DateTime? now}) {
    return _db.transaction(() async {
      final at = (now ?? DateTime.now()).toUtc();
      final cutoff = at.subtract(retention);

      final lists = await (_db.select(
        _db.taskLists,
      )..where((l) => l.deletedAt.isSmallerOrEqualValue(cutoff))).get();
      final tasks =
          await (_db.select(_db.tasks)..where(
                (t) =>
                    t.deletedAt.isSmallerOrEqualValue(cutoff) |
                    t.listId.isIn(lists.map((l) => l.id)),
              ))
              .get();
      final notes = await (_db.select(
        _db.notes,
      )..where((n) => n.deletedAt.isSmallerOrEqualValue(cutoff))).get();
      final folders = await (_db.select(
        _db.folders,
      )..where((f) => f.deletedAt.isSmallerOrEqualValue(cutoff))).get();

      await _purgeTasks(tasks, at);

      for (final list in lists) {
        await _finishPurge(
          SyncEntityType.taskList,
          list.id,
          list.deletedAt ?? at,
          list.revision,
        );
        await (_db.delete(
          _db.taskLists,
        )..where((l) => l.id.equals(list.id))).go();
      }

      var standaloneOrder = await _maxOrder(
        _db.taskLists,
        _db.taskLists.manualOrder,
        _db.taskLists.isSystem.equals(false),
      );
      var rootNoteOrder = await _maxOrder(
        _db.notes,
        _db.notes.manualOrder,
        _db.notes.folderId.isNull(),
      );

      for (final note in notes) {
        final embedded = await (_db.select(
          _db.taskLists,
        )..where((l) => l.noteId.equals(note.id))).get();
        for (final list in embedded) {
          await (_db.update(
            _db.taskLists,
          )..where((l) => l.id.equals(list.id))).write(
            TaskListsCompanion(
              noteId: const Value(null),
              embedBlockId: const Value(null),
              manualOrder: Value(++standaloneOrder),
            ),
          );
          await _ledger.recordChange(SyncEntityType.taskList, list.id);
        }
        await _dropLabels(EntityKind.note, note.id);
        await _finishPurge(
          SyncEntityType.note,
          note.id,
          note.deletedAt ?? at,
          note.revision,
        );
        await (_db.delete(_db.notes)..where((n) => n.id.equals(note.id))).go();
      }

      final folderIds = folders.map((f) => f.id).toSet();
      final byParent = {for (final f in folders) f.id: f.parentId};
      folders.sort(
        (a, b) => _depth(
          b.id,
          byParent,
          folderIds,
        ).compareTo(_depth(a.id, byParent, folderIds)),
      );
      for (final folder in folders) {
        final childFolders = await (_db.select(
          _db.folders,
        )..where((f) => f.parentId.equals(folder.id))).get();
        for (final child in childFolders) {
          await (_db.update(_db.folders)..where((f) => f.id.equals(child.id)))
              .write(FoldersCompanion(parentId: Value(folder.parentId)));
          await _ledger.recordChange(SyncEntityType.folder, child.id);
        }
        final inFolder = await (_db.select(
          _db.notes,
        )..where((n) => n.folderId.equals(folder.id))).get();
        for (final note in inFolder) {
          await (_db.update(
            _db.notes,
          )..where((n) => n.id.equals(note.id))).write(
            NotesCompanion(
              folderId: const Value(null),
              manualOrder: Value(++rootNoteOrder),
            ),
          );
          await _ledger.recordChange(SyncEntityType.note, note.id);
        }
        await _finishPurge(
          SyncEntityType.folder,
          folder.id,
          folder.deletedAt ?? at,
          folder.revision,
        );
        await (_db.delete(
          _db.folders,
        )..where((f) => f.id.equals(folder.id))).go();
      }

      return tasks.length + lists.length + notes.length + folders.length;
    });
  }

  // --- внутренние ---

  /// Удаление задач от глубоких к корневым; живые подзадачи удаляемой
  /// задачи поднимаются к её родителю.
  Future<void> _purgeTasks(List<Task> tasks, DateTime at) async {
    final ids = tasks.map((t) => t.id).toSet();
    final byParent = {for (final t in tasks) t.id: t.parentId};
    tasks.sort(
      (a, b) =>
          _depth(b.id, byParent, ids).compareTo(_depth(a.id, byParent, ids)),
    );
    for (final task in tasks) {
      final children = await (_db.select(
        _db.tasks,
      )..where((t) => t.parentId.equals(task.id))).get();
      for (final child in children) {
        await (_db.update(_db.tasks)..where((t) => t.id.equals(child.id)))
            .write(TasksCompanion(parentId: Value(task.parentId)));
        await _ledger.recordChange(SyncEntityType.task, child.id);
      }
      await (_db.delete(
        _db.reminders,
      )..where((r) => r.taskId.equals(task.id))).go();
      await (_db.delete(
        _db.recurrenceRules,
      )..where((r) => r.taskId.equals(task.id))).go();
      await _dropLabels(EntityKind.task, task.id);
      await _finishPurge(
        SyncEntityType.task,
        task.id,
        task.deletedAt ?? at,
        task.revision,
      );
      await (_db.delete(_db.tasks)..where((t) => t.id.equals(task.id))).go();
    }
  }

  /// Число предков записи внутри удаляемого набора — для порядка удаления.
  int _depth(String id, Map<String, String?> parentOf, Set<String> inSet) {
    var depth = 0;
    var parent = parentOf[id];
    while (parent != null && inSet.contains(parent)) {
      depth++;
      parent = parentOf[parent];
    }
    return depth;
  }

  /// Снятие меток удаляемой записи; удаления меток уходят в outbox.
  Future<void> _dropLabels(EntityKind kind, String entityId) async {
    final labels =
        await (_db.select(_db.entityTags)..where(
              (e) =>
                  e.entityId.equals(entityId) & e.entityKind.equalsValue(kind),
            ))
            .get();
    for (final label in labels) {
      await (_db.delete(_db.entityTags)..where(
            (e) =>
                e.entityId.equals(entityId) &
                e.tagId.equals(label.tagId) &
                e.entityKind.equalsValue(kind),
          ))
          .go();
      await _ledger.recordDeletion(
        SyncEntityType.entityTag,
        entityTagId(kind, entityId, label.tagId),
        revision: label.revision + 1,
      );
    }
  }

  /// Удаление записи в облаке уже передано при переносе в корзину; здесь
  /// остаётся только маркер без содержимого (§10).
  Future<void> _finishPurge(
    SyncEntityType type,
    String id,
    DateTime deletedAt,
    int revision,
  ) {
    return _ledger.writeDeletionMarker(
      type,
      id,
      deletedAt: deletedAt,
      revision: revision,
    );
  }

  Future<int> _maxOrder<T extends HasResultSet, D>(
    ResultSetImplementation<T, D> table,
    GeneratedColumn<int> order,
    Expression<bool> condition,
  ) async {
    final maxExp = order.max();
    final query = _db.selectOnly(table)
      ..addColumns([maxExp])
      ..where(condition);
    return (await query.getSingle()).read(maxExp) ?? 0;
  }

  Future<List<String>> _folderSubtreeIds(String rootId) async {
    final rows = await _db
        .customSelect(
          'WITH RECURSIVE sub(id) AS ('
          'SELECT id FROM folders WHERE id = ? '
          'UNION ALL '
          'SELECT f.id FROM folders f JOIN sub ON f.parent_id = sub.id) '
          'SELECT id FROM sub',
          variables: [Variable(rootId)],
          readsFrom: {_db.folders},
        )
        .get();
    return rows.map((r) => r.data['id'] as String).toList();
  }
}
