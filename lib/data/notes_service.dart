/// Заметки (§4): редактирование с версионированием формата Delta, закрепление,
/// перемещение между папками. Автосохранение — дебаунс 500 мс на UI-стороне
/// (этап 2); облако в подтверждении локального сохранения не участвует (§4).
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';
import 'outbox_ledger.dart';

class NotesService {
  final AppDatabase _db;
  final OutboxLedger _ledger;
  final Uuid _uuid;

  NotesService(this._db, this._ledger, {Uuid? uuid})
      : _uuid = uuid ?? const Uuid();

  Future<Note> create({String? folderId, String? title}) {
    return _db.transaction(() async {
      final id = _uuid.v4();
      await _db.into(_db.notes).insert(NotesCompanion.insert(
            id: id,
            folderId: Value(folderId),
            title: Value(title),
            manualOrder: Value(await _nextManualOrder(folderId)),
            modifiedAt: Value(DateTime.now().toUtc()),
          ));
      await _ledger.recordSnapshot(SyncEntityType.note, id);
      return _get(id);
    });
  }

  /// Сохранение содержимого: Delta JSON + версия формата + простой текст
  /// для поиска. Вызывается дебаунсом редактора (этап 2).
  Future<void> saveContent(
    String id, {
    required String delta,
    String? title,
  }) {
    return _db.transaction(() async {
      await (_db.update(_db.notes)..where((n) => n.id.equals(id))).write(
        NotesCompanion(
          delta: Value(delta),
          deltaFormatVersion: const Value(kNoteDeltaFormatVersion),
          searchText: Value(deltaToPlainText(delta)),
          title: title == null ? const Value.absent() : Value(title),
        ),
      );
      await _ledger.recordChange(SyncEntityType.note, id);
    });
  }

  /// Закрепление: порядок закрепления хранится у заметки (§4) и применяется
  /// в текущей папке/подборке.
  Future<void> setPinned(String id, bool pinned) {
    return _db.transaction(() async {
      int? pinOrder;
      if (pinned) {
        final maxExp = _db.notes.pinOrder.max();
        final q = _db.selectOnly(_db.notes)..addColumns([maxExp]);
        pinOrder = (await q.getSingle().then((r) => r.read(maxExp)) ?? 0) + 1;
      }
      await (_db.update(_db.notes)..where((n) => n.id.equals(id))).write(
        NotesCompanion(pinned: Value(pinned), pinOrder: Value(pinOrder)),
      );
      await _ledger.recordChange(SyncEntityType.note, id);
    });
  }

  /// Перемещение в другую папку или «Без папки» (folderId = null).
  Future<void> moveToFolder(String id, String? folderId) {
    return _db.transaction(() async {
      await (_db.update(_db.notes)..where((n) => n.id.equals(id))).write(
        NotesCompanion(
          folderId: Value(folderId),
          manualOrder: Value(await _nextManualOrder(folderId)),
        ),
      );
      await _ledger.recordChange(SyncEntityType.note, id);
    });
  }

  /// Перечень заметок: закреплённые выше, их порядок ручной; остальные —
  /// по последнему изменению, свежие выше (§4).
  Future<List<Note>> listInFolder(String? folderId,
          {bool includeTrashed = false}) =>
      _inFolder(folderId, includeTrashed).get();

  Future<Note> get(String id) => _get(id);

  /// Реактивная одна заметка.
  Stream<Note> watchSingle(String id) =>
      (_db.select(_db.notes)..where((n) => n.id.equals(id))).watchSingle();

  /// Реактивный перечень заметок папки для UI (§4: закреплённые выше).
  Stream<List<Note>> watchInFolder(String? folderId,
          {bool includeTrashed = false}) =>
      _inFolder(folderId, includeTrashed).watch();

  /// Ручной порядок закреплённых (§4): ставим заметку после [afterId]
  /// (null — в начало); порядок синхронизируется через outbox.
  Future<void> reorderPinned(String id, {String? afterId}) {
    return _db.transaction(() async {
      final note = await _get(id);
      final pinned = await (_db.select(_db.notes)
            ..where((n) => n.pinned.equals(true) & n.deletedAt.isNull())
            ..orderBy([(n) => OrderingTerm.asc(n.pinOrder)]))
          .get();
      pinned.removeWhere((n) => n.id == id);
      final anchorIndex =
          afterId == null ? -1 : pinned.indexWhere((n) => n.id == afterId);
      if (afterId != null && anchorIndex < 0) {
        throw ArgumentError.value(afterId, 'afterId', 'not a pinned note');
      }
      pinned.insert(anchorIndex + 1, note);
      for (var i = 0; i < pinned.length; i++) {
        final current = pinned[i];
        if (current.id != id && current.pinOrder == i + 1) continue;
        await (_db.update(_db.notes)..where((n) => n.id.equals(current.id)))
            .write(NotesCompanion(pinOrder: Value(i + 1)));
        await _ledger.recordChange(SyncEntityType.note, current.id);
      }
    });
  }

  /// Корзина: мягкое удаление заметки (§11); встроенные списки решает
  /// пользователь (§11), работа со списками — TaskListsService.
  Future<void> moveToTrash(String id) {
    return _db.transaction(() async {
      await (_db.update(_db.notes)..where((n) => n.id.equals(id)))
          .write(NotesCompanion(deletedAt: Value(DateTime.now().toUtc())));
      await _ledger.recordTrashed(SyncEntityType.note, id);
    });
  }

  /// Извлечение простого текста из Quill Delta JSON — для FTS.
  static String deltaToPlainText(String deltaJson) {
    if (deltaJson.isEmpty) return '';
    try {
      final doc = jsonDecode(deltaJson);
      if (doc is! Map<String, Object?> || doc['ops'] is! List) return '';
      final buffer = StringBuffer();
      for (final op in doc['ops'] as List) {
        if (op is Map<String, Object?>) {
          final insert = op['insert'];
          if (insert is String) buffer.write(insert);
        }
      }
      return buffer.toString();
    } on FormatException {
      return '';
    }
  }

  // --- внутренние ---

  Future<Note> _get(String id) async =>
      await (_db.select(_db.notes)..where((n) => n.id.equals(id)))
          .getSingle();

  SimpleSelectStatement<$NotesTable, Note> _inFolder(
          String? folderId, bool includeTrashed) =>
      _db.select(_db.notes)
        ..where((n) =>
            n.folderId.equalsNullable(folderId) &
            (includeTrashed ? const Constant(true) : n.deletedAt.isNull()))
        ..orderBy([
          (n) => OrderingTerm.desc(n.pinned),
          (n) => OrderingTerm.asc(n.pinOrder, nulls: NullsOrder.last),
          (n) => OrderingTerm.desc(n.modifiedAt),
        ]);

  Future<int> _nextManualOrder(String? folderId) async {
    final maxExp = _db.notes.manualOrder.max();
    final q = _db.selectOnly(_db.notes)..addColumns([maxExp]);
    q.where(folderId == null
        ? _db.notes.folderId.isNull()
        : _db.notes.folderId.equals(folderId));
    return (await q.getSingle().then((r) => r.read(maxExp)) ?? 0) + 1;
  }
}

/// Версия формата заметки (§3): Delta JSON; изменение формата — миграция.
const int kNoteDeltaFormatVersion = 1;
