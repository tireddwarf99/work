/// Окончательное удаление просроченной корзины (§10, §11): порядок от
/// зависимых к родителям при включённых внешних ключах, сохранность живых
/// зависимых записей, маркеры.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/data/folders_service.dart';
import 'package:notes_app/data/lists_service.dart';
import 'package:notes_app/data/notes_service.dart';
import 'package:notes_app/data/outbox_ledger.dart';
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

  final longAgo = DateTime.now().toUtc().subtract(const Duration(days: 31));

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ledger = OutboxLedger(db);
    notes = NotesService(db, ledger);
    tasks = TasksService(db, ledger);
    lists = TaskListsService(db, ledger);
    folders = FoldersService(db, ledger);
    tags = TagsService(db, ledger);
    trash = TrashService(db, ledger);
  });

  tearDown(() => db.close());

  Future<void> expire(String table, Iterable<String> ids) async {
    for (final id in ids) {
      await db.customStatement(
        'UPDATE $table SET deleted_at = ? WHERE id = ?',
        [longAgo.millisecondsSinceEpoch ~/ 1000, id],
      );
    }
  }

  Future<Set<String>> markers() async => {
    for (final m in await db.select(db.deletionMarkers).get()) m.entityId,
  };

  test('внешние ключи включены', () async {
    final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(row.data.values.single, 1);
  });

  test('список с задачами удаляется вместе с ними, маркеры на всё', () async {
    final list = await lists.create(title: 'L');
    final root = await tasks.create(list.id, text: 'root');
    final child = await tasks.create(list.id, text: 'child', parentId: root.id);
    await lists.moveToTrash(list.id);
    await expire('task_lists', [list.id]);
    await expire('tasks', [root.id, child.id]);

    expect(await trash.purgeExpired(), 3);

    expect(await db.select(db.tasks).get(), isEmpty);
    expect((await db.select(db.taskLists).get()).map((l) => l.id), [
      inboxListId,
    ]);
    expect(await markers(), {list.id, root.id, child.id});
  });

  test(
    'задачи списка, не просроченные сами, удаляются с просроченным списком',
    () async {
      final list = await lists.create(title: 'L');
      final task = await tasks.create(list.id, text: 't');
      await expire('task_lists', [list.id]);

      expect(await trash.purgeExpired(), 2);
      expect(await db.select(db.tasks).get(), isEmpty);
      expect(await markers(), {list.id, task.id});
    },
  );

  test(
    'ветка задач удаляется от листьев к корню, метки и напоминания снимаются',
    () async {
      final list = await lists.create(title: 'L');
      final root = await tasks.create(list.id, text: 'root');
      final mid = await tasks.create(list.id, text: 'mid', parentId: root.id);
      final leaf = await tasks.create(list.id, text: 'leaf', parentId: mid.id);
      final tag = await tags.create('t');
      await tags.attach(EntityKind.task, leaf.id, tag.id);
      await db
          .into(db.reminders)
          .insert(
            RemindersCompanion.insert(
              id: 'r1',
              taskId: leaf.id,
              kind: ReminderKind.relative,
            ),
          );
      await tasks.moveBranchToTrash(root.id);
      await expire('tasks', [root.id, mid.id, leaf.id]);

      expect(await trash.purgeExpired(), 3);
      expect(await db.select(db.tasks).get(), isEmpty);
      expect(await db.select(db.reminders).get(), isEmpty);
      expect(await db.select(db.entityTags).get(), isEmpty);
      expect(await markers(), {root.id, mid.id, leaf.id});
    },
  );

  test(
    'живые подзадачи просроченной задачи поднимаются к её родителю',
    () async {
      final list = await lists.create(title: 'L');
      final root = await tasks.create(list.id, text: 'root');
      final mid = await tasks.create(list.id, text: 'mid', parentId: root.id);
      final leaf = await tasks.create(list.id, text: 'leaf', parentId: mid.id);
      await expire('tasks', [mid.id]);

      expect(await trash.purgeExpired(), 1);
      final moved = await tasks.get(leaf.id);
      expect(moved.parentId, root.id);
      expect(moved.deletedAt, isNull);
    },
  );

  test(
    'вложенные папки с заметками: живые заметки уходят в «Без папки»',
    () async {
      final root = await folders.create('root');
      final child = await folders.create('child', parentId: root.id);
      final inChild = await notes.create(folderId: child.id, title: 'a');
      final inRoot = await notes.create(folderId: root.id, title: 'b');
      await folders.moveToTrash(root.id);
      await expire('folders', [root.id, child.id]);

      expect(await trash.purgeExpired(), 2);

      expect(await db.select(db.folders).get(), isEmpty);
      final a = await notes.get(inChild.id);
      final b = await notes.get(inRoot.id);
      expect(a.folderId, isNull);
      expect(b.folderId, isNull);
      expect(a.manualOrder, isNot(b.manualOrder));
      expect(await markers(), {root.id, child.id});
    },
  );

  test(
    'живая подпапка просроченной папки поднимается на уровень выше',
    () async {
      final root = await folders.create('root');
      final mid = await folders.create('mid', parentId: root.id);
      final leaf = await folders.create('leaf', parentId: mid.id);
      await expire('folders', [mid.id]);

      expect(await trash.purgeExpired(), 1);
      expect((await folders.get(leaf.id)).parentId, root.id);
    },
  );

  test(
    'просроченная заметка: встроенный список становится самостоятельным',
    () async {
      final note = await notes.create(title: 'n');
      final embedded = await lists.createInNote(note.id, 'block-1');
      final task = await tasks.create(embedded.id, text: 't');
      await notes.moveToTrash(note.id);
      await expire('notes', [note.id]);

      expect(await trash.purgeExpired(), 1);

      final list = await lists.get(embedded.id);
      expect(list.noteId, isNull);
      expect(list.embedBlockId, isNull);
      expect((await tasks.get(task.id)).deletedAt, isNull);
      expect((await lists.listStandalone()).map((l) => l.id), [embedded.id]);
    },
  );

  test('в outbox попадают только затронутые живые записи', () async {
    final folder = await folders.create('f');
    final note = await notes.create(folderId: folder.id, title: 'n');
    await folders.moveToTrash(folder.id);
    await expire('folders', [folder.id]);
    final before = (await ledger.pending()).length;

    await trash.purgeExpired();
    final added = (await ledger.pending()).skip(before).toList();
    expect(added.map((o) => o.entityId), [note.id]);
    expect(added.single.changeKind, 'upsert');
  });

  test('повторный запуск ничего не удаляет', () async {
    final note = await notes.create(title: 'n');
    await expire('notes', [note.id]);
    expect(await trash.purgeExpired(), 1);
    expect(await trash.purgeExpired(), 0);
  });
}
