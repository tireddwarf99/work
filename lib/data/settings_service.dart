/// Настройки (§8): общие синхронизируются, локальные для устройства — нет.
/// Значения — JSON-строки; типизация ключей задаётся вызывающим кодом UI.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/app_database.dart';

class SettingsService {
  final AppDatabase _db;

  SettingsService(this._db);

  Future<String?> getDevice(String key) => _get(_db.deviceSettings, key);
  Future<String?> getShared(String key) => _get(_db.sharedSettings, key);

  /// Сырое строковое значение без JSON-обёртки — для простых флагов
  /// (workspace uid, тема, язык). Отдельный контракт от JSON-[getDevice].
  /// Имена таблиц фиксированы схемой.
  Future<String?> getString(String key, {bool shared = false}) async {
    final table = shared ? 'shared_settings' : 'device_settings';
    final row = await _db.customSelect(
      'SELECT value FROM $table WHERE `key` = ?',
      variables: [Variable(key)],
      readsFrom: {shared ? _db.sharedSettings : _db.deviceSettings},
    ).getSingleOrNull();
    return row?.data['value'] as String?;
  }

  Future<void> setString(String key, String value, {bool shared = false}) {
    final table = shared ? 'shared_settings' : 'device_settings';
    return _db.customStatement(
      'INSERT INTO $table (`key`, value) VALUES (?, ?) '
      'ON CONFLICT(`key`) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  Future<void> setDevice(String key, Object? value) =>
      _set(_db.deviceSettings, key, value);
  Future<void> setShared(String key, Object? value) =>
      _set(_db.sharedSettings, key, value);

  Future<String?> _get(TableInfo<dynamic, dynamic> table, String key) async {
    final query = _db.customSelect(
      'SELECT value FROM ${table.actualTableName} WHERE `key` = ?',
      variables: [Variable(key)],
      readsFrom: {table},
    );
    final row = await query.getSingleOrNull();
    return row?.data['value'] as String?;
  }

  Future<void> _set(
      TableInfo<dynamic, dynamic> table, String key, Object? value) {
    final encoded = value == null ? null : jsonEncode(value);
    return _db.customStatement(
      'INSERT INTO ${table.actualTableName} (`key`, value) VALUES (?, ?) '
      'ON CONFLICT(`key`) DO UPDATE SET value = excluded.value',
      [key, encoded],
    );
  }
}
