/// Поиск и фильтры (§4): по названию/тексту заметок и задач; фильтры папки,
/// тегов, выполненности, срока и приоритета. FTS5-запросы — параметры,
/// значения никогда не подставляются в строку SQL.
library;

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';

class NoteSearchFilters {
  final String? folderId;
  final String? tagId;
  final bool? completed;

  /// Для заметок не применяется; оставлен для единообразия запросов.
  const NoteSearchFilters({this.folderId, this.tagId, this.completed});
}

class TaskSearchFilters {
  final String? listId;
  final String? tagId;
  final bool? completed;
  final Priority? priority;
  final DueKind? dueKind;

  const TaskSearchFilters({
    this.listId,
    this.tagId,
    this.completed,
    this.priority,
    this.dueKind,
  });
}

class SearchService {
  final AppDatabase _db;

  SearchService(this._db);

  /// Поиск заметок по названию и тексту (FTS5, unicode61).
  Future<List<Note>> notes(String query, {NoteSearchFilters filters = const NoteSearchFilters()}) {
    final match = _ftsMatch(query);
    if (match == null) return Future.value(const []);
    final buffer = StringBuffer(
      'SELECT n.* FROM notes_fts f '
      'JOIN notes n ON n.rowid = f.rowid '
      'WHERE notes_fts MATCH ? AND n.deleted_at IS NULL',
    );
    final variables = <Variable>[Variable(match)];
    if (filters.folderId != null) {
      buffer.write(' AND n.folder_id = ?');
      variables.add(Variable(filters.folderId));
    }
    if (filters.tagId != null) {
      buffer.write(
          ' AND EXISTS (SELECT 1 FROM entity_tags et '
          'WHERE et.entity_id = n.id AND et.tag_id = ? '
          'AND et.entity_kind = 0)');
      variables.add(Variable(filters.tagId));
    }
    buffer.write(' ORDER BY rank LIMIT 200');
    return _db
        .customSelect(buffer.toString(),
            variables: variables, readsFrom: {_db.notes})
        .get()
        .then((rows) async => [for (final r in rows) await _db.notes.mapFromRow(r)]);
  }

  /// Поиск задач по тексту и описанию + фильтры (§4).
  Future<List<Task>> tasks(String query, {TaskSearchFilters filters = const TaskSearchFilters()}) {
    final match = _ftsMatch(query);
    if (match == null) return Future.value(const []);
    final buffer = StringBuffer(
      'SELECT t.* FROM tasks_fts f '
      'JOIN tasks t ON t.rowid = f.rowid '
      'WHERE tasks_fts MATCH ? AND t.deleted_at IS NULL',
    );
    final variables = <Variable>[Variable(match)];
    if (filters.listId != null) {
      buffer.write(' AND t.list_id = ?');
      variables.add(Variable(filters.listId));
    }
    if (filters.completed != null) {
      buffer.write(filters.completed!
          ? ' AND t.completed_at IS NOT NULL'
          : ' AND t.completed_at IS NULL');
    }
    if (filters.priority != null) {
      buffer.write(' AND t.priority = ?');
      variables.add(Variable(filters.priority!.index));
    }
    if (filters.dueKind != null) {
      buffer.write(' AND t.due_kind = ?');
      variables.add(Variable(filters.dueKind!.index));
    }
    if (filters.tagId != null) {
      buffer.write(
          ' AND EXISTS (SELECT 1 FROM entity_tags et '
          'WHERE et.entity_id = t.id AND et.tag_id = ? '
          'AND et.entity_kind = 1)');
      variables.add(Variable(filters.tagId));
    }
    buffer.write(' ORDER BY rank LIMIT 200');
    return _db
        .customSelect(buffer.toString(),
            variables: variables, readsFrom: {_db.tasks})
        .get()
        .then((rows) async => [for (final r in rows) await _db.tasks.mapFromRow(r)]);
  }

  /// Подготовка пользовательского ввода к FTS5 MATCH: слова в кавычках,
  /// спецсимволы FTS внутри слов удаляются. Пустой ввод — null (пустая выборка).
  String? _ftsMatch(String query) {
    final words = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => '"${w.replaceAll('"', '')}"')
        .toList();
    if (words.isEmpty) return null;
    return words.join(' ');
  }
}
