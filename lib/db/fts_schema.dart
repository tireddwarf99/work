/// Локальный полнотекстовый поиск — FTS5 с Unicode-токенизацией (§2).
///
/// Индекс — обычные fts5-таблицы, поддерживаемые триггерами от базовых
/// таблиц. Строки индекса связаны с сущностями по UUID (колонка `*_id`), а не
/// по неявному rowid: у таблиц с TEXT-ключом rowid не стабилен (VACUUM может
/// его перенумеровать). SQL сосредоточен здесь; морфология не обещается (§2).
library;

import 'package:drift/drift.dart';

/// Сборка/пересборка FTS-индексов и триггеров поддержки.
extension FtsSchema on DatabaseConnectionUser {
  Future<void> createFtsSchema() async {
    await customStatement(
        'CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5('
        "note_id UNINDEXED, title, body, tokenize='unicode61')");
    await customStatement(
        'CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5('
        "task_id UNINDEXED, text, description, tokenize='unicode61')");
    for (final statement in _triggers) {
      await customStatement(statement);
    }
  }

  /// Миграция формата индекса: старые таблицы и триггеры удаляются, индекс
  /// создаётся заново и заполняется из базовых таблиц.
  Future<void> recreateFtsSchema() async {
    for (final name in _triggerNames) {
      await customStatement('DROP TRIGGER IF EXISTS $name');
    }
    await customStatement('DROP TABLE IF EXISTS notes_fts');
    await customStatement('DROP TABLE IF EXISTS tasks_fts');
    await createFtsSchema();
    await rebuildFts();
  }

  /// Полная пересборка содержимого индекса из базовых таблиц.
  Future<void> rebuildFts() async {
    await customStatement('DELETE FROM notes_fts');
    await customStatement('INSERT INTO notes_fts(note_id, title, body) '
        "SELECT id, coalesce(title, ''), search_text FROM notes");
    await customStatement('DELETE FROM tasks_fts');
    await customStatement('INSERT INTO tasks_fts(task_id, text, description) '
        'SELECT id, text, description FROM tasks');
  }
}

const _triggerNames = [
  'trg_notes_fts_ai',
  'trg_notes_fts_ad',
  'trg_notes_fts_au',
  'trg_tasks_fts_ai',
  'trg_tasks_fts_ad',
  'trg_tasks_fts_au',
];

// Индекс обновляется только при смене индексируемых колонок: правки
// ревизии, порядка и закрепления его не трогают.
const _triggers = [
  '''
  CREATE TRIGGER IF NOT EXISTS trg_notes_fts_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(note_id, title, body)
    VALUES (new.id, coalesce(new.title, ''), new.search_text);
  END''',
  '''
  CREATE TRIGGER IF NOT EXISTS trg_notes_fts_ad AFTER DELETE ON notes BEGIN
    DELETE FROM notes_fts WHERE note_id = old.id;
  END''',
  '''
  CREATE TRIGGER IF NOT EXISTS trg_notes_fts_au
  AFTER UPDATE OF id, title, search_text ON notes BEGIN
    DELETE FROM notes_fts WHERE note_id = old.id;
    INSERT INTO notes_fts(note_id, title, body)
    VALUES (new.id, coalesce(new.title, ''), new.search_text);
  END''',
  '''
  CREATE TRIGGER IF NOT EXISTS trg_tasks_fts_ai AFTER INSERT ON tasks BEGIN
    INSERT INTO tasks_fts(task_id, text, description)
    VALUES (new.id, new.text, new.description);
  END''',
  '''
  CREATE TRIGGER IF NOT EXISTS trg_tasks_fts_ad AFTER DELETE ON tasks BEGIN
    DELETE FROM tasks_fts WHERE task_id = old.id;
  END''',
  '''
  CREATE TRIGGER IF NOT EXISTS trg_tasks_fts_au
  AFTER UPDATE OF id, text, description ON tasks BEGIN
    DELETE FROM tasks_fts WHERE task_id = old.id;
    INSERT INTO tasks_fts(task_id, text, description)
    VALUES (new.id, new.text, new.description);
  END''',
];
