/// Провайдеры Riverpod: база, сервисы, локальные настройки устройства.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../data/folders_service.dart';
import '../data/lists_service.dart';
import '../data/notes_service.dart';
import '../data/outbox_ledger.dart';
import '../data/search_service.dart';
import '../data/settings_service.dart';
import '../data/tags_service.dart';
import '../data/tasks_service.dart';
import '../data/trash_service.dart';
import '../db/app_database.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

OutboxLedger _ledger(Ref ref) => OutboxLedger(ref.watch(appDatabaseProvider));

final notesServiceProvider = Provider(
  (ref) => NotesService(ref.watch(appDatabaseProvider), _ledger(ref)),
);
final tasksServiceProvider = Provider(
  (ref) => TasksService(ref.watch(appDatabaseProvider), _ledger(ref)),
);
final listsServiceProvider = Provider(
  (ref) => TaskListsService(ref.watch(appDatabaseProvider), _ledger(ref)),
);
final foldersServiceProvider = Provider(
  (ref) => FoldersService(ref.watch(appDatabaseProvider), _ledger(ref)),
);
final tagsServiceProvider = Provider(
  (ref) => TagsService(ref.watch(appDatabaseProvider), _ledger(ref)),
);
final trashServiceProvider = Provider(
  (ref) => TrashService(ref.watch(appDatabaseProvider), _ledger(ref)),
);
final searchServiceProvider = Provider(
  (ref) => SearchService(ref.watch(appDatabaseProvider)),
);
final settingsServiceProvider = Provider(
  (ref) => SettingsService(ref.watch(appDatabaseProvider)),
);

/// Тема устройства — локальная настройка (§8): 0 system, 1 light, 2 dark.
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    try {
      // getString; старые версии хранили JSON-строку ('"dark"') — совместимость.
      var raw = await ref.read(settingsServiceProvider).getString('theme');
      if (raw == null) {
        raw = await ref.read(settingsServiceProvider).getDevice('theme');
        if (raw != null) raw = raw.replaceAll('"', '');
      }
      if (raw == null || !ref.mounted) return;
      state = switch (raw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (e, st) {
      // Без сохранённой темы остаётся системная.
      debugPrint('theme load failed: $e\n$st');
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final name = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await ref.read(settingsServiceProvider).setString('theme', name);
  }
}

/// Ручной выбор языка (§8): null — как в системе.
final localeProvider = NotifierProvider<LocaleNotifier, Locale?>(
  LocaleNotifier.new,
);

class LocaleNotifier extends Notifier<Locale?> {
  @override
  Locale? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    try {
      var raw = await ref.read(settingsServiceProvider).getString('locale');
      if (raw == null) {
        raw = await ref.read(settingsServiceProvider).getDevice('locale');
        if (raw != null) raw = raw.replaceAll('"', '');
      }
      if (raw == null || !ref.mounted) return;
      state = raw.isEmpty ? null : Locale(raw);
    } catch (e, st) {
      // Без сохранённого языка остаётся системный.
      debugPrint('locale load failed: $e\n$st');
    }
  }

  Future<void> set(Locale? locale) async {
    state = locale;
    await ref
        .read(settingsServiceProvider)
        .setString('locale', locale?.languageCode ?? '');
  }
}

/// Переход к списку в заметке (§4): заметка + block_id embed'а.
final pendingEmbedJumpProvider =
    StateProvider<({String noteId, String blockId})?>((ref) => null);

/// Подсвеченный в данный момент embed (block_id); снимается по таймеру.
final embedHighlightProvider = StateProvider<String?>((ref) => null);

/// Задача, открытая в правой боковой панели на Windows (§8).
final windowsTaskPanelProvider =
    NotifierProvider<WindowsTaskPanelNotifier, String?>(
      WindowsTaskPanelNotifier.new,
    );

class WindowsTaskPanelNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String taskId) => state = taskId;

  void close() => state = null;
}
