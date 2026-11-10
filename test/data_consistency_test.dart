/// Согласованность локальных мутаций (§10): каждая мутация повышает ревизию,
/// обновляет `modified_at` и пишет в outbox снимок в формате синхронизации;
/// удаление тега, корзина списка, перенос ветки, поиск по префиксу.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/data/folders_service.dart';
import 'package:notes_app/data/lists_service.dart';
import 'package:notes_app/data/notes_service.dart';
import 'package:notes_app/data/outbox_ledger.dart';
import 'package:notes_app/data/search_service.dart';
import 'package:notes_app/data/tags_service.dart';
import 'package:notes_app/data/tasks_service.dart';
import 'package:notes_app/data/trash_service.dart';
import 'package:notes_app/db/app_database.dart';
import 'package:notes_app/domain/due_spec.dart';

void main() {
  late AppDatabase db;
  late OutboxLedger ledger;
  late NotesService notes;
  late TasksService tasks;
  late TaskListsService lists;
  late FoldersService folders;
  late TagsService tags;
  late TrashService trash;
  late SearchService search;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ledger = OutboxLedger(db);
    notes = NotesService(db, ledger);
    tasks = TasksService(db, ledger);
    lists = TaskListsService(db, ledger);
    folders = FoldersService(db, ledger);
    tags = TagsService(db, ledger);
    trash = TrashService(db, ledger);
    search = SearchService(db);
  });

  tearDown(() => db.close());

  group('ревизии и outbox', () {
    test('каждая мутация заметки повышает ревизию на 1', () async {
      final note = await notes.create(title: 'n');
      expect(note.revision, 1);

      await notes.saveContent(note.id, delta: '{"ops":[{"insert":"a\\n"}]}');
      expect((await notes.get(note.id)).revision, 2);
      await notes.setPinned(note.id, true);
      expect((await notes.get(note.id)).revision, 3);
      await notes.moveToTrash(note.id);
      final trashed = await notes.get(note.id);
      expect(trashed.revision, 4);
      expect(trashed.deletedAt, isNotNull);
      await trash.restoreNote(note.id);
      expect((await notes.get(note.id)).revision, 5);
    });

    test('мутации папок, списков, тегов и задач повышают ревизию', () async {
      final folder = await folders.create('f');
      await folders.rename(folder.id, 'g');
      await folders.moveToTrash(folder.id);
      expect((await folders.get(folder.id)).revision, 3);

      final list = await lists.create(title: 'L');
      await lists.rename(list.id, 'M');
      await lists.moveToTrash(list.id);
      await lists.restoreFromTrash(list.id);
      expect((await lists.get(list.id)).revision, 4);

      final tag = await tags.create('t');
      await tags.rename(tag.id, 'u');
      expect((await db.select(db.tags).getSingle()).revision, 2);

      final other = await lists.create(title: 'O');
      final task = await tasks.create(other.id, text: 'x');
      await tasks.updateText(task.id, 'y');
      expect((await tasks.get(task.id)).revision, 2);
    });

    test('снимок в outbox — в формате синхронизации (snake_case)', () async {
      final folder = await folders.create('f');
      final child = await folders.create('c', parentId: folder.id);
      final payload = jsonDecode(
        (await ledger.pending())
            .lastWhere((o) => o.entityId == child.id)
            .payload,
      ) as Map<String, Object?>;
      expect(payload['parent_id'], folder.id);
      expect(payload['manual_order'], 1);
      expect(payload['revision'], 1);
    });

    test('удаление в outbox несёт ревизию', () async {
      final note = await notes.create(title: 'n');
      await notes.moveToTrash(note.id);
      final op = (await ledger.pending()).last;
      expect(op.changeKind, 'delete');
      expect(jsonDecode(op.payload)['revision'], 2);
    });

    test('автосохранение — одна запись outbox и один шаг ревизии', () async {
      final note = await notes.create(title: 'n');
      final before = (await ledger.pending()).length;
      await notes.saveContent(note.id, delta: '{"ops":[{"insert":"a\\n"}]}');
      expect((await ledger.pending()).length, before + 1);
    });
  });

  group('папки', () {
    test('create и move проверяют существование родителя', () async {
      final folder = await folders.create('f');
      expect(() => folders.create('x', parentId: 'nope'), throwsArgumentError);
      expect(() => folders.move(folder.id, 'nope'), throwsArgumentError);
      expect(() => folders.move('nope', null), throwsArgumentError);
    });

    test('move ставит папку последней среди соседей нового родителя', () async {
      final a = await folders.create('a');
      final b = await folders.create('b');
      final c = await folders.create('c', parentId: b.id);
      await folders.move(a.id, b.id);
      final moved = await folders.get(a.id);
      expect(moved.manualOrder, isNot((await folders.get(c.id)).manualOrder));
      expect(moved.revision, 2);
    });
  });

  group('задачи', () {
    test('перенос ветки: порядок без коллизий, ревизии растут', () async {
      final a = await lists.create(title: 'A');
      final b = await lists.create(title: 'B');
      final existing = await tasks.create(b.id, text: 'e');
      final root = await tasks.create(a.id, text: 'root');
      final child = await tasks.create(a.id, text: 'c', parentId: root.id);

      await tasks.moveBranch(root.id, newListId: b.id);

      final moved = await tasks.get(root.id);
      expect(moved.listId, b.id);
      expect(moved.manualOrder, isNot(existing.manualOrder));
      expect((await tasks.get(child.id)).listId, b.id);
      expect(moved.revision, 2);
      expect((await tasks.get(child.id)).revision, 2);
    });

    test('перенос в несуществующий список — ArgumentError', () async {
      final a = await lists.create(title: 'A');
      final t = await tasks.create(a.id, text: 't');
      expect(
        () => tasks.moveBranch(t.id, newListId: 'nope'),
        throwsArgumentError,
      );
    });
  });

  group('списки в корзине', () {
    test('список уходит с задачами и возвращается только с ними', () async {
      final list = await lists.create(title: 'L');
      final early = await tasks.create(list.id, text: 'early');
      final kept = await tasks.create(list.id, text: 'kept');
      await tasks.moveBranchToTrash(early.id);
      // «early» удалена раньше списка: другое время удаления.
      await db.customStatement(
        'UPDATE tasks SET deleted_at = deleted_at - 100 WHERE id = ?',
        [early.id],
      );

      await lists.moveToTrash(list.id);
      expect((await tasks.get(kept.id)).deletedAt, isNotNull);

      await lists.restoreFromTrash(list.id);
      expect((await lists.get(list.id)).deletedAt, isNull);
      expect((await tasks.get(kept.id)).deletedAt, isNull);
      expect((await tasks.get(early.id)).deletedAt, isNotNull);
    });

    test('«Входящие» удалить нельзя', () async {
      expect(() => lists.moveToTrash(inboxListId), throwsArgumentError);
    });
  });

  group('теги', () {
    test('удаление тега: маркер и удаления в outbox, метки сняты', () async {
      final note = await notes.create(title: 'n');
      final tag = await tags.create('t');
      await tags.attach(EntityKind.note, note.id, tag.id);
      final before = (await ledger.pending()).length;

      await tags.delete(tag.id);

      expect(await db.select(db.tags).get(), isEmpty);
      expect(await db.select(db.entityTags).get(), isEmpty);
      final marker = await db.select(db.deletionMarkers).getSingle();
      expect(marker.entityType, SyncEntityType.tag);
      expect(marker.entityId, tag.id);
      final added = (await ledger.pending()).skip(before).toList();
      expect(added.map((o) => o.entityType), [
        SyncEntityType.entityTag,
        SyncEntityType.tag,
      ]);
      expect(added.every((o) => o.changeKind == 'delete'), isTrue);
    });

    test('detach несуществующей метки не пишет в outbox', () async {
      final note = await notes.create(title: 'n');
      final tag = await tags.create('t');
      final before = (await ledger.pending()).length;
      await tags.detach(EntityKind.note, note.id, tag.id);
      expect((await ledger.pending()).length, before);
    });
  });

  group('поиск', () {
    test('префиксное совпадение для поиска по мере набора', () async {
      final note = await notes.create(title: 'Плани на тиждень');
      await notes.saveContent(
        note.id,
        delta: '{"ops":[{"insert":"Сібрати важливі справи\\n"}]}',
      );
      expect(await search.notes('важл'), hasLength(1));
      expect(await search.notes('Пла тижд'), hasLength(1));
      expect(await search.notes('справи важ'), hasLength(1));
      expect(await search.notes('чужий'), isEmpty);
    });

    test('кавычки и операторы FTS нейтрализованы', () async {
      final note = await notes.create(title: 'alpha beta');
      expect(await search.notes('"alpha"'), hasLength(1));
      expect(await search.notes('alpha OR gamma'), isEmpty);
      expect(await search.notes('alpha" bet'), hasLength(1));
      expect(await search.notes('a*b'), isEmpty);
      expect(await search.notes('"'), isEmpty);
      expect(note.id, isNotEmpty);
    });

    test('индекс связан по id: переживает VACUUM и изменение rowid', () async {
      final a = await notes.create(title: 'первая');
      final b = await notes.create(title: 'вторая');
      await notes.saveContent(b.id, delta: '{"ops":[{"insert":"ключ\\n"}]}');
      await db.customStatement('DELETE FROM notes WHERE id = ?', [a.id]);
      await db.customStatement('VACUUM');
      final found = await search.notes('ключ');
      expect(found.single.id, b.id);
      expect(await search.notes('первая'), isEmpty);
    });

    test('смена порядка и закрепления не ломает индекс', () async {
      final note = await notes.create(title: 'заголовок');
      await notes.setPinned(note.id, true);
      await notes.moveToTrash(note.id);
      expect(await search.notes('заголовок'), isEmpty);
      await trash.restoreNote(note.id);
      expect(await search.notes('заголовок'), hasLength(1));
    });
  });
}
