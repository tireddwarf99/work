/// Windows-вход (§9): системный браузер, OAuth Authorization Code + PKCE
/// S256, случайные state/nonce, loopback callback 127.0.0.1 на временном
/// свободном порту. Desktop-клиент Google требует client_secret при обмене
/// кода (см. [FirebaseConfig.desktopClientSecret]); он не граница
/// безопасности — защиту дают PKCE, state и nonce.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../cloud/firebase_config.dart';
import '../cloud/firebase_rest.dart';

class DesktopGoogleSignIn {
  final http.Client _http = http.Client();

  final Random _random = Random.secure();

  String _randomString(int length) {
    final values = List<int>.generate(length,
        (i) => _random.nextInt(256));
    return base64UrlEncode(values).replaceAll('=', '');
  }

  String _s256(String verifier) =>
      base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes)
          .replaceAll('=', '');

  /// Полный вход: возвращает токены Google для signInWithIdp.
  Future<GoogleTokens> signIn() async {
    // Без секрета обмен кода невозможен — падаем до открытия браузера.
    final clientSecret = FirebaseConfig.desktopClientSecret;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final state = _randomString(24);
    final nonce = _randomString(24);
    final verifier = _randomString(64);
    final challenge = _s256(verifier);

    final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': FirebaseConfig.desktopClientId,
      'redirect_uri': 'http://127.0.0.1:$port',
      'response_type': 'code',
      'scope': 'openid email profile',
      'state': state,
      'nonce': nonce,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'prompt': 'select_account',
    });

    try {
      final codeFuture = _awaitAuthorizationCode(server, state);
      // Ошибка колбэка может прийти раньше, чем мы начнём её ждать.
      unawaited(codeFuture.then((_) {}, onError: (_) {}));
      await _openBrowser(authUrl.toString());

      final code = await codeFuture.timeout(const Duration(minutes: 5),
          onTimeout: () => throw FirebaseApiException(
              'Авторизация не завершена за 5 минут'));

      // Обмен кода на токены (PKCE verifier).
      final tokenResponse = await _http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'code': code,
          'client_id': FirebaseConfig.desktopClientId,
          'client_secret': clientSecret,
          'redirect_uri': 'http://127.0.0.1:$port',
          'grant_type': 'authorization_code',
          'code_verifier': verifier,
        },
      );
      final Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(utf8.decode(tokenResponse.bodyBytes));
        body = decoded is Map<String, dynamic> ? decoded : const {};
      } on FormatException {
        throw FirebaseApiException('token exchange: malformed response',
            statusCode: tokenResponse.statusCode);
      }
      if (tokenResponse.statusCode != 200) {
        throw FirebaseApiException(
            body['error_description'] as String? ?? 'token exchange failed',
            statusCode: tokenResponse.statusCode);
      }
      final idToken = body['id_token'] as String?;
      final accessToken = body['access_token'] as String?;
      if (idToken == null) {
        throw FirebaseApiException('no id_token in token response');
      }
      verifyIdTokenClaims(idToken,
          nonce: nonce, audience: FirebaseConfig.desktopClientId);
      return GoogleTokens(idToken: idToken, accessToken: accessToken);
    } finally {
      await server.close(force: true);
    }
  }

  /// Локальный сервер ждёт redirect с code и state. Посторонние запросы
  /// (favicon, зонды) и запросы с чужим state игнорируются.
  Future<String> _awaitAuthorizationCode(
      HttpServer server, String state) async {
    await for (final request in server) {
      final uri = request.uri;
      if (uri.path != '/') {
        await _respond(request, HttpStatus.notFound);
        continue;
      }
      final params = uri.queryParameters;
      if (params['state'] != state) {
        // Несовпадение state — чужой/поддельный запрос; ждём настоящий
        // (§9: случайный state).
        await _respond(request, HttpStatus.badRequest);
        continue;
      }
      final error = params['error'];
      final code = params['code'];
      if (error != null || code == null || code.isEmpty) {
        await _respond(request, HttpStatus.badRequest);
        throw FirebaseApiException(error != null
            ? 'Google отклонил вход: $error'
            : 'Ответ авторизации без кода');
      }
      await _respond(request, HttpStatus.ok,
          html: '<html><body><h3>Вхід виконано — можна закрити вікно.</h3>'
              '<script>window.close()</script></body></html>');
      return code;
    }
    throw FirebaseApiException('Сервер входа остановлен до получения кода');
  }

  Future<void> _respond(HttpRequest request, int status,
      {String? html}) async {
    request.response.statusCode = status;
    if (html != null) {
      request.response.headers.contentType = ContentType.html;
      request.response.write(html);
    }
    await request.response.close();
  }

  /// Проверка claims id_token: issuer, audience, срок действия и nonce.
  /// Подпись здесь не проверяется: токен получен напрямую от
  /// oauth2.googleapis.com по TLS, а криптографическую проверку подписи
  /// выполняет сервер Firebase в accounts:signInWithIdp.
  @visibleForTesting
  static void verifyIdTokenClaims(
    String idToken, {
    required String nonce,
    required String audience,
    DateTime? now,
  }) {
    final parts = idToken.split('.');
    if (parts.length != 3) {
      throw FirebaseApiException('malformed id_token');
    }
    final Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('claims is not an object');
      }
      payload = decoded;
    } on FormatException {
      throw FirebaseApiException('malformed id_token');
    }
    const issuers = {'https://accounts.google.com', 'accounts.google.com'};
    if (!issuers.contains(payload['iss'])) {
      throw FirebaseApiException('id_token: unexpected issuer');
    }
    final aud = payload['aud'];
    if (aud != audience && !(aud is List && aud.contains(audience))) {
      throw FirebaseApiException('id_token: unexpected audience');
    }
    final exp = payload['exp'];
    final nowSeconds =
        (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch ~/ 1000;
    if (exp is! int || exp <= nowSeconds) {
      throw FirebaseApiException('id_token expired');
    }
    if (payload['nonce'] != nonce) {
      throw FirebaseApiException('nonce mismatch');
    }
  }

  Future<void> _openBrowser(String url) async {
    // Системный браузер по умолчанию (§9); url_launcher корректно
    // экранирует URL (cmd «съедает» & как разделитель команд).
    final uri = Uri.parse(url);
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );
    if (!launched) {
      throw FirebaseApiException('Не удалось открыть браузер для входа');
    }
  }

  void dispose() => _http.close();
}


/// Токены после Google-авторизации.
class GoogleTokens {
  final String idToken;
  final String? accessToken;
  const GoogleTokens({required this.idToken, this.accessToken});
}
