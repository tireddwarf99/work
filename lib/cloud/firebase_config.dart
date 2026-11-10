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

  static const String _compiledDesktopSecret =
      String.fromEnvironment('DESKTOP_OAUTH_CLIENT_SECRET');

  /// Секрет desktop-клиента: Google требует его при обмене кода на токены.
  /// Границей безопасности он не является (защиту дают PKCE, consent screen
  /// и Security Rules), но в исходниках не хранится. Источники: сборка с
  /// `--dart-define=DESKTOP_OAUTH_CLIENT_SECRET=...` (для пользователей),
  /// затем переменная окружения (для разработки). Если не задан нигде —
  /// [StateError]: пустой секрет не отправляется.
  static String get desktopClientSecret {
    final secret = _compiledDesktopSecret.isNotEmpty
        ? _compiledDesktopSecret
        : Platform.environment['DESKTOP_OAUTH_CLIENT_SECRET'] ?? '';
    if (secret.isEmpty) {
      throw StateError('Не задан DESKTOP_OAUTH_CLIENT_SECRET: соберите '
          'приложение с --dart-define=DESKTOP_OAUTH_CLIENT_SECRET=<секрет> '
          'или задайте переменную окружения (docs/cloud-setup.md).');
    }
    return secret;
  }
}
