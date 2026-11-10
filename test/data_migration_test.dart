/// Миграции схемы: апгрейд со старых версий сохраняет данные и приводит
/// FTS-индекс и служебные таблицы к актуальному виду.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/data/notes_service.dart';
import 'package:notes_app/data/outbox_ledger.dart';
import 'package:notes_app/data/search_service.dart';
import 'package:notes_app/db/app_database.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('notes_migration_');
    file = File('${dir.path}/db.sqlite');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  AppDatabase open() => AppDatabase.forTesting(NativeDatabase(file));

  /// Приводит базу к виду старой версии: убирает таблицы новых версий,
  /// возвращает FTS старого формата (rowid) и выставляет user_version.
  Future<void> downgrade(AppDatabase db, int version) async {
    await db.customStatement('DROP TABLE sync_base');
    for (final name in [
      'trg_notes_fts_ai',
      'trg_notes_fts_ad',
      'trg_notes_fts_au',
      'trg_tasks_fts_ai',
      'trg_tasks_fts_ad',
      'trg_tasks_fts_au',
    ]) {
      await db.customStatement('DROP TRIGGER $name');
    }
    await db.customStatement('DROP TABLE notes_fts');
    await db.customStatement('DROP TABLE tasks_fts');
    await db.customStatement(
        "CREATE VIRTUAL TABLE notes_fts USING fts5(title, body, tokenize='unicode61')");
    await db.customStatement(
        "CREATE VIRTUAL TABLE tasks_fts USING fts5(text, description, tokenize='unicode61')");
    await db.customStatement('PRAGMA user_version = $version');
  }

  for (final from in [1, 2]) {
    test('апгрейд v$from → v3: данные целы, sync_base и FTS обновлены',
        () async {
      var db = open();
      final note = await NotesService(db, OutboxLedger(db)).create(title: 'Ключ');
      await db.customStatement(
          "UPDATE notes SET search_text = 'старый контент' WHERE id = ?",
          [note.id]);
      await downgrade(db, from);
      await db.close();

      db = open();
      addTearDown(db.close);
      expect((await db.select(db.syncBase).get()), isEmpty);

      final search = SearchService(db);
      final byTitle = await search.notes('ключ');
      expect(byTitle.single.id, note.id);
      expect((await search.notes('контент')).single.id, note.id);

      final version =
          await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data.values.single, db.schemaVersion);

      // триггеры нового формата работают после миграции
      await NotesService(db, OutboxLedger(db))
          .saveContent(note.id, delta: '{"ops":[{"insert":"свежий\\n"}]}');
      expect(await search.notes('контент'), isEmpty);
      expect((await search.notes('свеж')).single.id, note.id);
    });
  }

  test('новая база создаётся сразу в актуальной версии', () async {
    final db = open();
    addTearDown(db.close);
    expect(db.schemaVersion, 3);
    expect(await db.select(db.syncBase).get(), isEmpty);
    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE name LIKE '%_fts'")
        .get();
    expect(tables.map((r) => r.data['name']),
        containsAll(['notes_fts', 'tasks_fts']));
  });
}
