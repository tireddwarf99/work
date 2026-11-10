// Инспектор снятой с устройства базы (этап 3, диагностика синхронизации).
// Запуск: dart run tool/inspect_device_db.dart <path>
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  final db = sqlite3.open(args.first);
  void show(String title, String sql) {
    stdout.writeln('=== $title ===');
    try {
      for (final row in db.select(sql)) {
        stdout.writeln(row);
      }
    } catch (e) {
      stdout.writeln('ERROR: $e');
    }
  }

  show('outbox', 'SELECT entity_type, entity_id, change_kind, attempts, '
      'last_error FROM outbox_entries');
  show('sync_state', 'SELECT * FROM sync_state');
  show('task_lists', 'SELECT id, title, is_system, revision, base_revision, '
      'deleted_at FROM task_lists');
  show('notes', 'SELECT id, title, revision, deleted_at FROM notes');
  show('counts', "SELECT 'folders', COUNT(*) FROM folders UNION ALL "
      "SELECT 'notes', COUNT(*) FROM notes UNION ALL "
      "SELECT 'tasks', COUNT(*) FROM tasks");
  db.close();
}
