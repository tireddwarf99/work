/// Интеграционные проверки слоя данных этапа 1 (in-memory SQLite):
/// CRUD, дерево задач, запрет циклов, FTS-поиск, корзина и маркеры.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/data/folders_service.dart';
import 'package:notes_app/data/lists_service.dart';
import 'package:notes_app/data/notes_service.dart';
import 'package:notes_app/data/outbox_ledger.dart';
import 'package:notes_app/data/search_service.dart';
import 'package:notes_app/data/settings_service.dart';
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
  late SettingsService settings;

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
    settings = SettingsService(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('bootstrap', () {
    test('создаёт sync_state и системный список «Входящие»', () async {
      final inbox = await lists.inbox();
      expect(inbox.id, inboxListId);
      expect(inbox.isSystem, isTrue);

      final state = await db.select(db.syncState).getSingle();
      expect(state.deviceId, isNotEmpty);
      expect(state.workspaceEpoch, 1);
    });
  });

  group('заметки', () {
    test('создание, сохранение контента, поиск по FTS', () async {
      final note = await notes.create(
        folderId: null,
        title: 'Плани на тиждень',
      );
      await notes.saveContent(
        note.id,
        delta: '{"ops":[{"insert":"Сібрати важливі справи\\n"}]}',
      );

      final found = await search.notes('важливі');
      expect(found, hasLength(1));
      expect(found.single.id, note.id);
    });

    test('закрепление поднимает заметку; порядок закрепления ручной', () async {
      final a = await notes.create(title: 'A');
      final b = await notes.create(title: 'B');
      await notes.setPinned(a.id, true);
      await notes.setPinned(b.id, true);

      final list = await notes.listInFolder(null);
      // pinOrder возрастает: первой идёт ранее закреплённая; порядок ручной
      // и синхронизируемый (§4).
      expect(list.first.id, a.id);
      expect(list.first.pinOrder, 1);
      expect(list.skip(1).first.id, b.id);
    });

    test(
      'обновление контента повторно находит заметку (триггер FTS)',
      () async {
        final note = await notes.create(title: 'T');
        await notes.saveContent(
          note.id,
          delta: '{"ops":[{"insert":"старый текст\\n"}]}',
        );
        expect((await search.notes('старый')), hasLength(1));

        await notes.saveContent(
          note.id,
          delta: '{"ops":[{"insert":"новый текст\\n"}]}',
        );
        expect((await search.notes('старый')), isEmpty);
        expect((await search.notes('новый')), hasLength(1));
      },
    );

    test('дубликат слова в запросе не ломает выборку', () async {
      final note = await notes.create(title: 'Т');
      await notes.saveContent(
        note.id,
        delta: '{"ops":[{"insert":"пошук по нотатках\\n"}]}',
      );
      expect((await search.notes('пошук нотатках')), hasLength(1));
      expect((await search.notes('   ')), isEmpty);
    });
  });

  group('задачи и дерево', () {
    test('создание с сроком обоих типов и поиск задач', () async {
      final list = await lists.create(title: 'Список');
      await tasks.create(
        list.id,
        text: 'Замовити фільтр для води',
        due: const DueSpec.at('2026-11-02', 18 * 60),
      );
      await tasks.create(
        list.id,
        text: 'Подзвонити до сервісу',
        due: const DueSpec.dateOnly('2026-11-03'),
        priority: Priority.high,
      );

      final found = await search.tasks('фільтр');
      expect(found, hasLength(1));
      expect(found.single.dueKind, DueKind.dateTime);
      expect(found.single.dueMinutes, 18 * 60);

      // Морфология не обещается (§2): точный токен — «сервісу».
      final byPriority = await search.tasks('сервісу');
      expect(byPriority.single.priority, Priority.high);
    });

    test('подзадача обязана быть в списке родителя (§3)', () async {
      final listA = await lists.create(title: 'A');
      final listB = await lists.create(title: 'B');
      final parent = await tasks.create(listA.id, text: 'parent');
      expect(
        () => tasks.create(listB.id, text: 'child', parentId: parent.id),
        throwsArgumentError,
      );
    });

    test('перенос ветки в другой список сохраняет вложенность (§4)', () async {
      final from = await lists.create(title: 'from');
      final to = await lists.create(title: 'to');
      final root = await tasks.create(from.id, text: 'root');
      final child = await tasks.create(
        from.id,
        text: 'child',
        parentId: root.id,
      );
      final grand = await tasks.create(
        from.id,
        text: 'grand',
        parentId: child.id,
      );

      await tasks.moveBranch(root.id, newListId: to.id);

      final movedGrand = await tasks.get(grand.id);
      expect(movedGrand.listId, to.id);
      expect(movedGrand.parentId, child.id);
      expect((await tasks.children(child.id)), hasLength(1));
      expect((await tasks.listActiveInList(from.id)), isEmpty);
    });

    test('циклический перенос запрещён (§4)', () async {
      final list = await lists.create(title: 'L');
      final root = await tasks.create(list.id, text: 'root');
      final child = await tasks.create(
        list.id,
        text: 'child',
        parentId: root.id,
      );

      expect(
        () => tasks.moveBranch(
          root.id,
          newListId: list.id,
          newParentId: child.id,
        ),
        throwsStateError,
      );
    });

    test('переупорядочивание соседей не меняет структуру дерева', () async {
      final list = await lists.create(title: 'L');
      final a = await tasks.create(list.id, text: 'a');
      final b = await tasks.create(list.id, text: 'b');
      final c = await tasks.create(list.id, text: 'c');

      await tasks.reorder(c.id, afterId: a.id);
      final ordered = await tasks.listActiveInList(list.id);
      expect(ordered.map((t) => t.id).toList(), [a.id, c.id, b.id]);

      await tasks.reorder(c.id); // в начало
      final again = await tasks.listActiveInList(list.id);
      expect(again.map((t) => t.id).toList(), [c.id, a.id, b.id]);
    });

    test(
      'выполнение родителя и проверка незавершённых потомков (§6)',
      () async {
        final list = await lists.create(title: 'L');
        final root = await tasks.create(list.id, text: 'root');
        final child = await tasks.create(
          list.id,
          text: 'child',
          parentId: root.id,
        );

        // Незавершённый потомок → UI запрашивает подтверждение ветки.
        expect(await tasks.hasIncompleteDescendants(root.id), isTrue);

        await tasks.setCompleted(child.id, true);
        expect(await tasks.hasIncompleteDescendants(root.id), isFalse);
        // Пустой/уже завершённый родитель подтверждения не требует (§6).
        await tasks.setCompleted(root.id, true);
        expect((await tasks.get(root.id)).completedAt, isNotNull);
      },
    );
  });

  group('списки', () {
    test('«Входящие» сверху и не в перечне самостоятельных', () async {
      final standalone = await lists.create(title: 'Мій список');
      final all = await lists.listStandalone();
      expect(all.map((l) => l.id), [standalone.id]);
      expect((await lists.inbox()).id, inboxListId);
    });

    test(
      'встроенный список переносится и становится самостоятельным (§4)',
      () async {
        final note = await notes.create(title: 'N');
        final list = await lists.createInNote(
          note.id,
          'block-1',
          title: 'Справи',
        );
        expect(list.noteId, note.id);
        expect(list.embedBlockId, 'block-1');

        await lists.moveEmbed(list.id, null, null);
        final moved = await lists.get(list.id);
        expect(moved.noteId, isNull);
        expect(moved.embedBlockId, isNull);
      },
    );
  });

  group('теги', () {
    test('метки заметки и задачи раздельные (entity_kind)', () async {
      final tag = await tags.create('дім');
      final note = await notes.create(title: 'N');
      final list = await lists.create(title: 'L');
      final task = await tasks.create(list.id, text: 'T');

      await tags.attach(EntityKind.note, note.id, tag.id);
      await tags.attach(EntityKind.task, task.id, tag.id);

      final noteTags = await tags.tagsFor(EntityKind.note, note.id);
      final taskTags = await tags.tagsFor(EntityKind.task, task.id);
      expect(noteTags, hasLength(1));
      expect(taskTags, hasLength(1));
      // Снятие метки с задачи не трогает заметку.
      await tags.detach(EntityKind.task, task.id, tag.id);
      expect(await tags.tagsFor(EntityKind.task, task.id), isEmpty);
      expect(await tags.tagsFor(EntityKind.note, note.id), hasLength(1));
    });

    test('удаление тега снимает метки, записи остаются (§11)', () async {
      final tag = await tags.create('ідеї');
      final note = await notes.create(title: 'N');
      await tags.attach(EntityKind.note, note.id, tag.id);

      await tags.delete(tag.id);
      expect(await tags.tagsFor(EntityKind.note, note.id), isEmpty);
      expect(await notes.get(note.id), isNotNull);
    });
  });

  group('папки', () {
    test('вложенность и запрет перемещения внутрь себя (§4)', () async {
      final root = await folders.create('Особисте');
      final child = await folders.create('Робота', parentId: root.id);

      expect(await folders.isDescendantOf(child.id, root.id), isTrue);
      expect(() => folders.move(root.id, child.id), throwsStateError);
    });

    test('корзина папки затрагивает всё дерево (§11)', () async {
      final root = await folders.create('Особисте');
      final child = await folders.create('Робота', parentId: root.id);
      await notes.create(folderId: child.id, title: 'N');

      await folders.moveToTrash(child.id);
      final active = await folders.listAll();
      expect(active.map((f) => f.id), [root.id]);
    });
  });

  group('корзина и маркеры удаления', () {
    test(
      'ветка задач уходит в корзину целиком и восстанавливается (§11)',
      () async {
        final list = await lists.create(title: 'L');
        final root = await tasks.create(list.id, text: 'root');
        final child = await tasks.create(
          list.id,
          text: 'child',
          parentId: root.id,
        );

        await tasks.moveBranchToTrash(root.id);
        expect((await tasks.listActiveInList(list.id)), isEmpty);

        await tasks.restoreBranchFromTrash(root.id);
        expect(await tasks.get(child.id), isNotNull);
        expect((await tasks.listActiveInList(list.id)), hasLength(2));
      },
    );

    test(
      'восстановление заметки из удалённой папки → «Без папки» (§11)',
      () async {
        final folder = await folders.create('Тимчасова');
        final note = await notes.create(folderId: folder.id, title: 'N');

        await folders.moveToTrash(folder.id);
        await notes.moveToTrash(note.id);
        final moved = await trash.restoreNote(note.id);
        expect(moved, isTrue);

        final restored = await notes.get(note.id);
        expect(restored.folderId, isNull);
        expect(restored.deletedAt, isNull);
      },
    );

    test(
      'просроченные записи удаляются физически и остаются маркерами (§10)',
      () async {
        final note = await notes.create(title: 'N');
        await db.customStatement(
          'UPDATE notes SET deleted_at = ? WHERE id = ?',
          [
            DateTime.now()
                    .toUtc()
                    .subtract(const Duration(days: 31))
                    .millisecondsSinceEpoch ~/
                1000,
            note.id,
          ],
        );

        final purged = await trash.purgeExpired();
        expect(purged, 1);

        final marker = await (db.select(
          db.deletionMarkers,
        )..where((m) => m.entityId.equals(note.id))).getSingleOrNull();
        expect(marker, isNotNull);
        expect(marker!.entityType, SyncEntityType.note);

        final gone = await (db.select(
          db.notes,
        )..where((n) => n.id.equals(note.id))).getSingleOrNull();
        expect(gone, isNull);
      },
    );

    test('свежие записи корзины не удаляются (30 дней, §11)', () async {
      final note = await notes.create(title: 'N');
      await db.customStatement('UPDATE notes SET deleted_at = ? WHERE id = ?', [
        DateTime.now()
                .toUtc()
                .subtract(const Duration(days: 5))
                .millisecondsSinceEpoch ~/
            1000,
        note.id,
      ]);
      expect(await trash.purgeExpired(), 0);
      expect(await notes.get(note.id), isNotNull);
    });
  });

  group('outbox', () {
    test('мутация и запись outbox — одна транзакция (§10)', () async {
      final note = await notes.create(title: 'N');
      final pending = await ledger.pending();
      expect(pending, hasLength(1));
      expect(pending.single.entityId, note.id);
      expect(pending.single.changeKind, 'upsert');
    });
  });

  group('настройки', () {
    test('device и shared изолированы (§8)', () async {
      await settings.setDevice('theme', 'dark');
      await settings.setShared('list_sort_inbox', 'due');
      expect(await settings.getDevice('theme'), '"dark"');
      expect(await settings.getShared('theme'), isNull);
      expect(await settings.getShared('list_sort_inbox'), '"due"');
    });

    test(
      'getString/setString и getDevice/setDevice — один формат (JSON)',
      () async {
        await settings.setString('sync.workspace_uid', 'uid-123');
        expect(await settings.getString('sync.workspace_uid'), 'uid-123');
        expect(await settings.getString('theme'), isNull);

        await settings.setDevice('theme', 'dark');
        expect(await settings.getString('theme'), 'dark');
        await settings.setString('locale', '');
        expect(await settings.getString('locale'), '');
        expect(await settings.getDevice('locale'), '""');
      },
    );

    test(
      'значение без JSON-обёртки (старый формат) читается как есть',
      () async {
        await db.customStatement(
          "INSERT INTO device_settings (key, value) VALUES ('legacy', 'raw')",
        );
        expect(await settings.getString('legacy'), 'raw');
      },
    );

    test('null удаляет настройку', () async {
      await settings.setString('k', 'v');
      await settings.setString('k', null);
      expect(await settings.getString('k'), isNull);
      await settings.setShared('s', 1);
      await settings.setShared('s', null);
      expect(await settings.getShared('s'), isNull);
    });
  });
}
