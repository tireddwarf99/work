/// Локальный полнотекстовый поиск — FTS5 с Unicode-токенизацией (§2).
///
/// Индекс — обычные fts5-таблицы, поддерживаемые триггерами от базовых
/// таблиц. SQL сосредоточен здесь; морфология не обещается (§2).
library;

import 'package:drift/drift.dart';

/// Сборка/пересборка FTS-индексов и триггеров поддержки.
extension FtsSchema on DatabaseConnectionUser {
  Future<void> createFtsSchema() async {
    await customStatement(
      "CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5("
      "title, body, tokenize='unicode61')",
    );
    await customStatement(
      "CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5("
      "text, description, tokenize='unicode61')",
    );
    await _createTriggers();
  }

  /// Полная пересборка индекса (используется миграциями и обслуживанием).
  Future<void> rebuildFts() async {
    await customStatement("INSERT INTO notes_fts(notes_fts) VALUES('rebuild')");
    await customStatement("INSERT INTO tasks_fts(tasks_fts) VALUES('rebuild')");
  }

  Future<void> _createTriggers() async {
    const statements = [
      '''
      CREATE TRIGGER IF NOT EXISTS trg_notes_fts_ai AFTER INSERT ON notes BEGIN
        INSERT INTO notes_fts(rowid, title, body)
        VALUES (new.rowid, coalesce(new.title, ''), new.search_text);
      END''',
      '''
      CREATE TRIGGER IF NOT EXISTS trg_notes_fts_ad AFTER DELETE ON notes BEGIN
        DELETE FROM notes_fts WHERE rowid = old.rowid;
      END''',
      '''
      CREATE TRIGGER IF NOT EXISTS trg_notes_fts_au AFTER UPDATE ON notes BEGIN
        DELETE FROM notes_fts WHERE rowid = old.rowid;
        INSERT INTO notes_fts(rowid, title, body)
        VALUES (new.rowid, coalesce(new.title, ''), new.search_text);
      END''',
      '''
      CREATE TRIGGER IF NOT EXISTS trg_tasks_fts_ai AFTER INSERT ON tasks BEGIN
        INSERT INTO tasks_fts(rowid, text, description)
        VALUES (new.rowid, new.text, new.description);
      END''',
      '''
      CREATE TRIGGER IF NOT EXISTS trg_tasks_fts_ad AFTER DELETE ON tasks BEGIN
        DELETE FROM tasks_fts WHERE rowid = old.rowid;
      END''',
      '''
      CREATE TRIGGER IF NOT EXISTS trg_tasks_fts_au AFTER UPDATE ON tasks BEGIN
        DELETE FROM tasks_fts WHERE rowid = old.rowid;
        INSERT INTO tasks_fts(rowid, text, description)
        VALUES (new.rowid, new.text, new.description);
      END''',
    ];
    for (final s in statements) {
      await customStatement(s);
    }
  }
}
