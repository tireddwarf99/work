/// Папки (§4): вложенные папки, заметка в одной папке или «Без папки».
library;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';
import 'outbox_ledger.dart';

class FoldersService {
  final AppDatabase _db;
  final OutboxLedger _ledger;
  final Uuid _uuid;

  FoldersService(this._db, this._ledger, {Uuid? uuid})
      : _uuid = uuid ?? const Uuid();

  Future<Folder> create(String name, {String? parentId}) {
    return _db.transaction(() async {
      final order = await _nextOrder(parentId);
      final id = _uuid.v4();
      final now = DateTime.now().toUtc();
      final row = FoldersCompanion.insert(
        id: id,
        name: name,
        parentId: Value(parentId),
        manualOrder: Value(order),
        modifiedAt: Value(now),
      );
      await _db.into(_db.folders).insert(row);
      final created = await _get(id);
      await _ledger.recordUpsert(SyncEntityType.folder, id, created.toJson());
      return created;
    });
  }

  Future<void> rename(String id, String name) {
    return _db.transaction(() async {
      await (_db.update(_db.folders)..where((f) => f.id.equals(id))).write(
        FoldersCompanion(name: Value(name), modifiedAt: Value(DateTime.now().toUtc())),
      );
      await _ledger.recordUpsert(SyncEntityType.folder, id,
          (await _get(id)).toJson());
    });
  }

  /// Перемещение папки; цикл «папка внутри себя» запрещён (§4).
  Future<void> move(String id, String? newParentId) {
    return _db.transaction(() async {
      if (newParentId != null) {
        if (newParentId == id ||
            await _isDescendant(newParentId, id)) {
          throw StateError('cannot move folder inside itself');
        }
      }
      await (_db.update(_db.folders)..where((f) => f.id.equals(id))).write(
        FoldersCompanion(
            parentId: Value(newParentId),
            modifiedAt: Value(DateTime.now().toUtc())),
      );
      await _ledger.recordUpsert(
          SyncEntityType.folder, id, (await _get(id)).toJson());
    });
  }

  /// Корзина: мягкое удаление всего дерева (§11) — подтверждение на UI.
  Future<void> moveToTrash(String id) {
    return _db.transaction(() async {
      final now = DateTime.now().toUtc();
      final ids = await _subtreeIds(id);
      await (_db.update(_db.folders)..where((f) => f.id.isIn(ids)))
          .write(FoldersCompanion(deletedAt: Value(now), modifiedAt: Value(now)));
      for (final fid in ids) {
        await _ledger.recordDeletion(SyncEntityType.folder, fid);
      }
    });
  }

  Future<Folder> get(String id) => _get(id);

  Future<List<Folder>> watchAllOnce({bool includeTrashed = false}) =>
      (_db.select(_db.folders)
            ..where((f) =>
                includeTrashed ? const Constant(true) : f.deletedAt.isNull())
            ..orderBy([(f) => OrderingTerm.asc(f.manualOrder)]))
          .get();

  /// Реактивный перечень папок для навигации (§4).
  Stream<List<Folder>> watchAll({bool includeTrashed = false}) =>
      (_db.select(_db.folders)
            ..where((f) =>
                includeTrashed ? const Constant(true) : f.deletedAt.isNull())
            ..orderBy([(f) => OrderingTerm.asc(f.manualOrder)]))
          .watch();

  Future<bool> isDescendantOf(String candidateId, String ancestorId) =>
      _isDescendant(candidateId, ancestorId);

  // --- внутренние ---

  Future<int> _nextOrder(String? parentId) async {
    final maxExp = _db.folders.manualOrder.max();
    final query = _db.selectOnly(_db.folders)
      ..addColumns([maxExp]);
    if (parentId == null) {
      query.where(_db.folders.parentId.isNull());
    } else {
      query.where(_db.folders.parentId.equals(parentId));
    }
    final row = await query.getSingle();
    return (row.read(maxExp) ?? 0) + 1;
  }

  Future<Folder> _get(String id) async =>
      await (_db.select(_db.folders)..where((f) => f.id.equals(id)))
          .getSingle();

  Future<bool> _isDescendant(String candidateId, String ancestorId) async {
    var current = candidateId;
    for (var i = 0; i < 512; i++) {
      final f = await (_db.select(_db.folders)
            ..where((f) => f.id.equals(current)))
          .getSingleOrNull();
      if (f == null) return false;
      if (f.parentId == ancestorId) return true;
      final parent = f.parentId;
      if (parent == null) return false;
      current = parent;
    }
    return true;
  }

  Future<List<String>> _subtreeIds(String rootId) async {
    final result = await _db
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
    return result.map((r) => r.data['id'] as String).toList();
  }
}
