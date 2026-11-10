/// Корзина (§11): 30 дней от исходного удаления, без продления из-за
/// синхронизации. Восстановление прежней структуры; исчезнувшая папка —
/// восстановление в «Без папки» с пояснением.
library;

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';
import 'outbox_ledger.dart';

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
  /// в папке, которая окончательно удалена, — тогда она восстановлена в
  /// «Без папки» (UI показывает пояснение, §11).
  Future<bool> restoreNote(String noteId) {
    return _db.transaction(() async {
      final note = await (_db.select(_db.notes)
            ..where((n) => n.id.equals(noteId)))
          .getSingle();
      var movedToNoFolder = false;
      String? folderId = note.folderId;
      final originalFolderId = folderId;
      if (originalFolderId != null) {
        final folder = await (_db.select(_db.folders)
              ..where((f) => f.id.equals(originalFolderId)))
            .getSingleOrNull();
        if (folder == null || folder.deletedAt != null) {
          folderId = null;
          movedToNoFolder = true;
        }
      }
      await (_db.update(_db.notes)..where((n) => n.id.equals(noteId))).write(
        NotesCompanion(
          deletedAt: Value(null),
          folderId: Value(folderId),
          modifiedAt: Value(DateTime.now().toUtc()),
        ),
      );
      await _bumpAndRecord(SyncEntityType.note, noteId, 'notes');
      return movedToNoFolder;
    });
  }

  /// Восстановление папки вместе с деревом (§11).
  Future<void> restoreFolder(String folderId) {
    return _db.transaction(() async {
      final ids = await _folderSubtreeIds(folderId);
      await (_db.update(_db.folders)..where((f) => f.id.isIn(ids))).write(
        FoldersCompanion(
          deletedAt: Value(null),
          modifiedAt: Value(DateTime.now().toUtc()),
        ),
      );
      for (final id in ids) {
        await _bumpAndRecord(SyncEntityType.folder, id, 'folders');
      }
    });
  }

  /// Физическое удаление просроченных записей (§10, §11): компактные маркеры
  /// без текста остаются, чтобы давно офлайн-устройство не воскресило данные.
  Future<int> purgeExpired({DateTime? now}) {
    return _db.transaction(() async {
      final at = (now ?? DateTime.now()).toUtc();
      final cutoff = at.subtract(retention);
      var purged = 0;

      final notes = await (_db.select(_db.notes)
            ..where((n) => n.deletedAt.isNotNull() & n.deletedAt.isSmallerOrEqualValue(cutoff)))
          .get();
      for (final n in notes) {
        await _writeMarker(SyncEntityType.note, n.id, n.deletedAt!, n.revision);
        await (_db.delete(_db.notes)..where((x) => x.id.equals(n.id))).go();
        await _ledger.recordDeletion(SyncEntityType.note, n.id);
        purged++;
      }

      final folders = await (_db.select(_db.folders)
            ..where((f) => f.deletedAt.isNotNull() & f.deletedAt.isSmallerOrEqualValue(cutoff)))
          .get();
      for (final f in folders) {
        await _writeMarker(SyncEntityType.folder, f.id, f.deletedAt!, f.revision);
        await (_db.delete(_db.folders)..where((x) => x.id.equals(f.id))).go();
        await _ledger.recordDeletion(SyncEntityType.folder, f.id);
        purged++;
      }

      final lists = await (_db.select(_db.taskLists)
            ..where((l) => l.deletedAt.isNotNull() & l.deletedAt.isSmallerOrEqualValue(cutoff)))
          .get();
      for (final l in lists) {
        await _writeMarker(SyncEntityType.taskList, l.id, l.deletedAt!, l.revision);
        await (_db.delete(_db.taskLists)..where((x) => x.id.equals(l.id))).go();
        await _ledger.recordDeletion(SyncEntityType.taskList, l.id);
        purged++;
      }

      final tasks = await (_db.select(_db.tasks)
            ..where((t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerOrEqualValue(cutoff)))
          .get();
      for (final t in tasks) {
        await _writeMarker(SyncEntityType.task, t.id, t.deletedAt!, t.revision);
        await (_db.delete(_db.tasks)..where((x) => x.id.equals(t.id))).go();
        await _ledger.recordDeletion(SyncEntityType.task, t.id);
        purged++;
      }

      // Tags: удаление тега снимает метки сразу (§11), физическая строка
      // помечается как удалённая при удалении.
      final tags = await (_db.select(_db.tags)
            ..where((t) => t.deletedAt.isNotNull() & t.deletedAt.isSmallerOrEqualValue(cutoff)))
          .get();
      for (final t in tags) {
        await _writeMarker(SyncEntityType.tag, t.id, t.deletedAt!, t.revision);
        await (_db.delete(_db.tags)..where((x) => x.id.equals(t.id))).go();
        await _ledger.recordDeletion(SyncEntityType.tag, t.id);
        purged++;
      }

      return purged;
    });
  }

  /// Восстановленная запись уходит в облако: bump ревизии + outbox в той
  /// же транзакции (§10).
  Future<void> _bumpAndRecord(
      SyncEntityType type, String entityId, String table) async {
    await _db.customStatement(
        'UPDATE $table SET revision = revision + 1 WHERE id = ?', [entityId]);
    final payload = await _entityPayload(type, entityId);
    if (payload == null) return;
    await _ledger.recordUpsert(type, entityId, payload);
  }

  Future<Map<String, Object?>?> _entityPayload(
      SyncEntityType type, String entityId) async {
    switch (type) {
      case SyncEntityType.note:
        final row = await (_db.select(_db.notes)
              ..where((n) => n.id.equals(entityId)))
            .getSingleOrNull();
        return row?.toJson();
      case SyncEntityType.folder:
        final row = await (_db.select(_db.folders)
              ..where((f) => f.id.equals(entityId)))
            .getSingleOrNull();
        return row?.toJson();
      default:
        return null;
    }
  }

  Future<void> _writeMarker(
      SyncEntityType type, String id, DateTime deletedAt, int revision) async {
    await _db.into(_db.deletionMarkers).insertOnConflictUpdate(
          DeletionMarkersCompanion.insert(
            entityId: id,
            entityType: type,
            deletedAtUtc: deletedAt.toUtc().toIso8601String(),
            revision: revision,
          ),
        );
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
