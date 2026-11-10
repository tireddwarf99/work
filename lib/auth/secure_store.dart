/// Защищённое хранилище токенов (§9): Android — Keystore-backed
/// EncryptedSharedPreferences (MethodChannel), Windows — DPAPI
/// (CryptProtectData через FFI, файлы в приватной области данных). Это
/// собственная реализация, flutter_secure_storage не используется.
/// Токены не попадают в ZIP-экспорт и логи.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' show calloc;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

import '../diagnostics/diag_log.dart';

/// Интерфейс защищённого хранилища «ключ → значение».
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  Future<void> clearAll(Iterable<String> keys) async {
    for (final key in keys) {
      await delete(key);
    }
  }
}

SecureStore createSecureStore() {
  if (Platform.isAndroid) return AndroidSecureStore();
  if (Platform.isWindows) return WindowsDpapiStore();
  // Прочие платформы в v1 не поддерживаются (§1); для токенов безопаснее
  // пустое хранилище, чем файлы без шифрования.
  return _InMemoryFallback();
}

// ---------- Android: EncryptedSharedPreferences ----------

class AndroidSecureStore extends SecureStore {
  static const _channel = MethodChannel('dev.notesapp.notes/secure');

  @override
  Future<String?> read(String key) async {
    try {
      return await _channel.invokeMethod<String>('get', {'key': key});
    } on PlatformException catch (e) {
      // Хранилище недоступно/пересоздано (см. MainActivity): как «нет
      // значения», потребуется повторный вход (§9).
      dlog('[secure] read failed (${e.code}): ${e.message}');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    await _channel.invokeMethod('put', {'key': key, 'value': value});
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _channel.invokeMethod('remove', {'key': key});
    } on PlatformException {
      // уже отсутствует
    }
  }
}

// ---------- Windows: DPAPI ----------

/// CRYPTPROTECT_UI_FORBIDDEN — без диалогов (фоновое обновление токенов).
const int _cryptProtectUiForbidden = 0x1;

/// Сбой CryptProtectData/CryptUnprotectData (ожидаемый, в отличие от
/// программных ошибок).
class _DpapiException implements Exception {
  final String message;
  _DpapiException(this.message);

  @override
  String toString() => '_DpapiException: $message';
}

class WindowsDpapiStore extends SecureStore {
  Directory? _dir;

  Future<Directory> _secureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'secure'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _dir = dir;
    return dir;
  }

  Uint8List _protect(List<int> plain) {
    final input = _allocBlob(plain);
    final output = calloc<CRYPT_INTEGER_BLOB>();
    try {
      final result = CryptProtectData(
        input,
        null,
        null,
        null,
        _cryptProtectUiForbidden,
        output,
      );
      if (result.value != true) {
        throw _DpapiException('CryptProtectData failed: ${result.error}');
      }
      final bytes = Uint8List.fromList(
          output.ref.pbData.asTypedList(output.ref.cbData));
      LocalFree(HLOCAL(output.ref.pbData));
      return bytes;
    } finally {
      _freeBlob(input);
      calloc.free(output);
    }
  }

  List<int> _unprotect(Uint8List encrypted) {
    final input = _allocBlob(encrypted);
    final output = calloc<CRYPT_INTEGER_BLOB>();
    try {
      final result = CryptUnprotectData(
        input,
        null,
        null,
        null,
        _cryptProtectUiForbidden,
        output,
      );
      if (result.value != true) {
        throw _DpapiException('CryptUnprotectData failed: ${result.error}');
      }
      final bytes = Uint8List.fromList(
          output.ref.pbData.asTypedList(output.ref.cbData));
      LocalFree(HLOCAL(output.ref.pbData));
      return bytes;
    } finally {
      _freeBlob(input);
      calloc.free(output);
    }
  }

  /// Входной блоб выделен через calloc — освобождается calloc, не LocalFree;
  /// LocalFree применим только к выходному буферу, выделенному DPAPI.
  void _freeBlob(ffi.Pointer<CRYPT_INTEGER_BLOB> blob) {
    calloc.free(blob.ref.pbData);
    calloc.free(blob);
  }

  ffi.Pointer<CRYPT_INTEGER_BLOB> _allocBlob(List<int> bytes) {
    final blob = calloc<CRYPT_INTEGER_BLOB>();
    final data = calloc<ffi.Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    blob.ref.cbData = bytes.length;
    blob.ref.pbData = data.cast();
    return blob;
  }

  @override
  Future<String?> read(String key) async {
    final dir = await _secureDir();
    final file = File(p.join(dir.path, '$key.bin'));
    if (!await file.exists()) return null;
    try {
      final encrypted = base64Decode(await file.readAsString());
      return utf8.decode(_unprotect(encrypted));
    } on FileSystemException catch (e) {
      dlog('[secure] read "$key" failed: ${e.message}');
      return null;
    } on FormatException catch (e) {
      dlog('[secure] read "$key": corrupted record: ${e.message}');
      return null;
    } on _DpapiException catch (e) {
      // Запись от другого пользователя Windows/повреждена — как «нет
      // значения»; потребуется повторный вход (§9).
      dlog('[secure] read "$key": ${e.message}');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final dir = await _secureDir();
    final encrypted = _protect(utf8.encode(value));
    // Атомарно: временный файл + rename, чтобы сбой не оставил обрезанную
    // запись.
    final target = File(p.join(dir.path, '$key.bin'));
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(base64Encode(encrypted), flush: true);
    await temp.rename(target.path);
  }

  @override
  Future<void> delete(String key) async {
    final dir = await _secureDir();
    final file = File(p.join(dir.path, '$key.bin'));
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class _InMemoryFallback extends SecureStore {
  final Map<String, String> _memory = {};

  @override
  Future<String?> read(String key) async => _memory[key];

  @override
  Future<void> write(String key, String value) async => _memory[key] = value;

  @override
  Future<void> delete(String key) async => _memory.remove(key);
}
