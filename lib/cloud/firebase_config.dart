/// Публичная конфигурация Firebase (§9): это НЕ секреты — API-ключ Firebase
/// идентифицирует проект и поставляется в каждом APK; доступ к данным
/// обеспечивают Security Rules по UID владельца. Приватных ключей в проекте
/// нет и не должно появиться.
library;

import 'dart:io';

class FirebaseConfig {
  static const String projectId = 'dwarfs-life-app';
  /// Browser key (REST-запросы с десктопа и из приложения).
  static const String apiKey = 'AIzaSyCyoUEyNgzEy9xuSS-DuusYXlk_YSSkrqo';

  /// OAuth-клиенты (§9, §13): публичные, без секретов.
  /// Web-клиент — serverClientId для Credential Manager на Android.
  static const String webClientId =
      '801436414302-q37vusl75jhe3egpsm1ie1ftjh6ag1p6.apps.googleusercontent.com';

  /// Desktop-клиент — PKCE + loopback 127.0.0.1 на Windows.
  static const String desktopClientId =
      '801436414302-v191510i21a70o5qbv4he1tefq7l1bu6.apps.googleusercontent.com';

  /// Секрет desktop-клиента. Google требует его при обмене кода на токены.
  /// Он не является границей безопасности: защиту обеспечивают PKCE,
  /// Consent screen и Security Rules. Секрет не хранится в исходниках:
  /// он берётся из переменной окружения DESKTOP_OAUTH_CLIENT_SECRET.
  static String get desktopClientSecret =>
      Platform.environment['DESKTOP_OAUTH_CLIENT_SECRET'] ?? '';
}
