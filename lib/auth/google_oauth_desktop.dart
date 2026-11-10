/// Windows-вход (§9): системный браузер, OAuth Authorization Code + PKCE
/// S256, случайные state/nonce, loopback callback 127.0.0.1 на временном
/// свободном порту. Desktop-клиент — публичный, секрет не используется.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
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
          'client_secret': FirebaseConfig.desktopClientSecret,
          'redirect_uri': 'http://127.0.0.1:$port',
          'grant_type': 'authorization_code',
          'code_verifier': verifier,
        },
      );
      final body =
          jsonDecode(utf8.decode(tokenResponse.bodyBytes)) as Map<String, dynamic>;
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
      _verifyNonce(idToken, nonce);
      return GoogleTokens(idToken: idToken, accessToken: accessToken);
    } finally {
      await server.close(force: true);
    }
  }

  /// Локальный сервер ждёт redirect с code и state.
  Future<String> _awaitAuthorizationCode(
      HttpServer server, String state) async {
    final completer = Completer<String>();
    await for (final request in server) {
      final uri = request.uri;
      if (uri.path != '/' || uri.queryParameters['error'] != null) {
        request.response.statusCode = 400;
        await request.response.close();
        if (!completer.isCompleted) {
          completer.completeError(
              FirebaseApiException(uri.queryParameters['error'] ?? 'bad callback'));
        }
        break;
      }
      if (uri.queryParameters['state'] != state) {
        // Несовпадение state — атака; игнорируем запрос (§9: случайный state).
        request.response.statusCode = 400;
        await request.response.close();
        continue;
      }
      request.response.headers.contentType = ContentType.html;
      request.response
          .write('<html><body><h3>Вхід виконано — можна закрити вікно.</h3>'
              '<script>window.close()</script></body></html>');
      await request.response.close();
      if (!completer.isCompleted) {
        completer.complete(uri.queryParameters['code']!);
      }
      break;
    }
    return completer.future;
  }

  /// Проверка nonce по payload id_token. Ограничение v1: подпись, issuer,
  /// audience и срок действия не проверяются криптографически — для этого
  /// нужна валидация по JWKS Google (этап полировки). Подпись токена в этом
  /// флоу гарантируется TLS-каналом accounts.google.com; state/nonce/redirect
  /// закрывают подмену и replay в рамках клиента.
  void _verifyNonce(String idToken, String nonce) {
    final parts = idToken.split('.');
    if (parts.length != 3) {
      throw FirebaseApiException('malformed id_token');
    }
    final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
        as Map<String, dynamic>;
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
