/// Защищённое хранилище токенов (§9): Android — Keystore-backed
/// EncryptedSharedPreferences (MethodChannel), Windows — DPAPI
/// (CryptProtectData через FFI, файлы в приватной области данных).
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
    } on PlatformException {
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
        throw StateError('CryptProtectData failed: ${result.error}');
      }
      return Uint8List.fromList(
          output.ref.pbData.asTypedList(output.ref.cbData));
    } finally {
      LocalFree(HLOCAL(input.ref.pbData));
      LocalFree(HLOCAL(output.ref.pbData));
      calloc.free(input);
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
        throw StateError('CryptUnprotectData failed: ${result.error}');
      }
      return Uint8List.fromList(
          output.ref.pbData.asTypedList(output.ref.cbData));
    } finally {
      LocalFree(HLOCAL(input.ref.pbData));
      LocalFree(HLOCAL(output.ref.pbData));
      calloc.free(input);
      calloc.free(output);
    }
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
    } catch (_) {
      // Повреждённая запись DPAPI (например, смена пользователя) —
      // трактуем как отсутствие значения; потребуется повторный вход (§9).
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final dir = await _secureDir();
    final encrypted = _protect(utf8.encode(value));
    await File(p.join(dir.path, '$key.bin'))
        .writeAsString(base64Encode(encrypted), flush: true);
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
