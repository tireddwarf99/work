/// Проверка claims id_token (aud/iss/exp/nonce), классификация отказов
/// авторизации и источник секрета desktop-клиента.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/auth/auth_service.dart';
import 'package:notes_app/auth/google_oauth_desktop.dart';
import 'package:notes_app/cloud/firebase_config.dart';
import 'package:notes_app/cloud/firebase_rest.dart';

String _jwt(Map<String, Object?> claims) {
  String enc(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${enc({'alg': 'RS256'})}.${enc(claims)}.sig';
}

void main() {
  const audience = 'client-id';
  final now = DateTime.utc(2026, 11, 10, 12);
  final exp = now.millisecondsSinceEpoch ~/ 1000 + 3600;

  Map<String, Object?> claims({
    Object? iss = 'https://accounts.google.com',
    Object? aud = audience,
    Object? expiry,
    Object? nonce = 'n1',
  }) =>
      {'iss': iss, 'aud': aud, 'exp': expiry ?? exp, 'nonce': nonce};

  void verify(Map<String, Object?> c) => DesktopGoogleSignIn.verifyIdTokenClaims(
      _jwt(c),
      nonce: 'n1',
      audience: audience,
      now: now);

  group('verifyIdTokenClaims', () {
    test('корректные claims проходят', () {
      expect(() => verify(claims()), returnsNormally);
      expect(() => verify(claims(iss: 'accounts.google.com')), returnsNormally);
      expect(() => verify(claims(aud: [audience, 'other'])), returnsNormally);
    });

    test('чужой issuer, audience, просроченный токен и nonce отвергаются', () {
      expect(() => verify(claims(iss: 'https://evil.example')),
          throwsA(isA<FirebaseApiException>()));
      expect(() => verify(claims(aud: 'other-client')),
          throwsA(isA<FirebaseApiException>()));
      expect(
          () => verify(
              claims(expiry: now.millisecondsSinceEpoch ~/ 1000 - 1)),
          throwsA(isA<FirebaseApiException>()));
      expect(() => verify(claims(nonce: 'other')),
          throwsA(isA<FirebaseApiException>()));
    });

    test('не-JWT и повреждённый payload отвергаются', () {
      expect(
          () => DesktopGoogleSignIn.verifyIdTokenClaims('abc',
              nonce: 'n1', audience: audience, now: now),
          throwsA(isA<FirebaseApiException>()));
      expect(
          () => DesktopGoogleSignIn.verifyIdTokenClaims('a.!!!.c',
              nonce: 'n1', audience: audience, now: now),
          throwsA(isA<FirebaseApiException>()));
    });
  });

  group('isDefinitiveAuthFailure', () {
    test('отзыв refresh token — окончательный отказ', () {
      for (final code in [
        'INVALID_REFRESH_TOKEN',
        'TOKEN_EXPIRED',
        'USER_DISABLED',
        'USER_NOT_FOUND',
      ]) {
        expect(
            isDefinitiveAuthFailure(
                FirebaseApiException('x', statusCode: 400, code: code)),
            isTrue,
            reason: code);
      }
    });

    test('квота/5xx и неизвестные ошибки — временные', () {
      expect(
          isDefinitiveAuthFailure(
              FirebaseApiException('x', statusCode: 429, retryable: true)),
          isFalse);
      expect(
          isDefinitiveAuthFailure(
              FirebaseApiException('x', statusCode: 503, retryable: true)),
          isFalse);
      expect(
          isDefinitiveAuthFailure(FirebaseApiException('x', statusCode: 400)),
          isFalse);
    });
  });

  test('Session.hasValidToken: пустой или просроченный токен недействителен', () {
    Session s(String token, DateTime expiresAt) => Session(
        uid: 'u',
        idToken: token,
        refreshToken: 'r',
        expiresAt: expiresAt);
    final future = DateTime.now().toUtc().add(const Duration(hours: 1));
    expect(s('t', future).hasValidToken, isTrue);
    expect(s('', future).hasValidToken, isFalse);
    expect(
        s('t', DateTime.now().toUtc().subtract(const Duration(minutes: 1)))
            .hasValidToken,
        isFalse);
  });

  test('секрет desktop-клиента: без источника — ошибка, а не пустая строка', () {
    final fromEnv = Platform.environment['DESKTOP_OAUTH_CLIENT_SECRET'];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      expect(FirebaseConfig.desktopClientSecret, fromEnv);
    } else {
      expect(() => FirebaseConfig.desktopClientSecret, throwsStateError);
    }
  });
}
