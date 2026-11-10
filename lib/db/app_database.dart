/// База данных приложения (§2): общая локальная SQLite через Drift.
///
/// Тяжёлые запросы выполняются в фоновом isolate
/// (NativeDatabase.createInBackground). База — в приватной области данных
/// приложения, отдельно от установочных файлов (§2).
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../domain/due_spec.dart';
import 'fts_schema.dart';
import 'tables.dart';

part 'app_database.g.dart';

/// Постоянный идентификатор системного списка «Входящие» (§3, §4).
const String inboxListId = '00000000-0000-4000-8000-000000000001';

@DriftDatabase(tables: [
  Folders,
  Notes,
  TaskLists,
  Tasks,
  Tags,
  EntityTags,
  RecurrenceRules,
  TaskOccurrences,
  Reminders,
  Conflicts,
  OutboxEntries,
  SyncState,
  DeletionMarkers,
  DeviceSettings,
  SharedSettings,
  SyncBase,
])
class AppDatabase extends _$AppDatabase {
  /// Фабрика для приложения: приватная область данных + фоновый isolate.
  AppDatabase() : super(_openConnection());

  /// Фабрика для тестов: любая схема подключения (in-memory и т.п.).
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await createFtsSchema();
        },
        onUpgrade: (m, from, to) async {
          // v2: таблица sync_base — база для трёхстороннего слияния (§10).
          // Добавление таблицы не трогает существующие данные.
          if (from < 2) {
            await m.createTable(syncBase);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          await customStatement('PRAGMA journal_mode = WAL');
          await customStatement('PRAGMA synchronous = NORMAL');
          await _bootstrap();
        },
      );

  /// Единственная строка sync_state и постоянный список «Входящие» (§3).
  Future<void> _bootstrap() async {
    final state = await select(syncState).getSingleOrNull();
    if (state == null) {
      await into(syncState).insert(SyncStateCompanion.insert(
        id: const Value(1),
        deviceId: const Uuid().v4(),
      ));
    }
    final inbox = await (select(taskLists)
          ..where((t) => t.id.equals(inboxListId)))
        .getSingleOrNull();
    if (inbox == null) {
      await into(taskLists).insert(TaskListsCompanion.insert(
        id: inboxListId,
        isSystem: const Value(true),
        modifiedAt: Value(DateTime.now().toUtc()),
      ));
    }
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'notes_app.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
