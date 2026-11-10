/// Настройки (§8): общие синхронизируются, локальные для устройства — нет.
///
/// Единый формат хранения: значение — JSON. [getDevice]/[getShared] отдают
/// JSON-текст (структурные значения декодирует вызывающий код),
/// [getString]/[setString] — простые строковые настройки без обёртки.
/// `null` при записи удаляет настройку.
library;

import 'dart:convert';


import '../db/app_database.dart';

class SettingsService {
  final AppDatabase _db;

  SettingsService(this._db);

  Future<String?> getDevice(String key) => _read(shared: false, key: key);
  Future<String?> getShared(String key) => _read(shared: true, key: key);

  Future<void> setDevice(String key, Object? value) =>
      _write(shared: false, key: key, value: value);
  Future<void> setShared(String key, Object? value) =>
      _write(shared: true, key: key, value: value);

  /// Строковая настройка (workspace uid, тема, язык). Значения, записанные
  /// до единого формата без JSON-обёртки, читаются как есть.
  Future<String?> getString(String key, {bool shared = false}) async {
    final stored = await _read(shared: shared, key: key);
    if (stored == null) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is String) return decoded;
    } on FormatException {
      // устаревшее сырое значение
    }
    return stored;
  }

  Future<void> setString(String key, String? value, {bool shared = false}) =>
      _write(shared: shared, key: key, value: value);

  // --- внутренние ---

  Future<String?> _read({required bool shared, required String key}) async {
    if (shared) {
      final row = await (_db.select(
        _db.sharedSettings,
      )..where((s) => s.key.equals(key))).getSingleOrNull();
      return row?.value;
    }
    final row = await (_db.select(
      _db.deviceSettings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _write({
    required bool shared,
    required String key,
    Object? value,
  }) async {
    if (value == null) {
      if (shared) {
        await (_db.delete(
          _db.sharedSettings,
        )..where((s) => s.key.equals(key))).go();
      } else {
        await (_db.delete(
          _db.deviceSettings,
        )..where((s) => s.key.equals(key))).go();
      }
      return;
    }
    final encoded = jsonEncode(value);
    if (shared) {
      await _db
          .into(_db.sharedSettings)
          .insertOnConflictUpdate(
            SharedSettingsCompanion.insert(key: key, value: encoded),
          );
    } else {
      await _db
          .into(_db.deviceSettings)
          .insertOnConflictUpdate(
            DeviceSettingsCompanion.insert(key: key, value: encoded),
          );
    }
  }
}
