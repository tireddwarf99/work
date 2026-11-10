/// Firebase по официальному REST API (§9): не FlutterFire — Windows-клиент
/// работает напрямую. Аутентификация: Bearer Firebase ID token.
///
/// Firestore REST: documents:get / runQuery / beginTransaction / commit /
/// rollback. Протокол синхронизации — в sync_engine.dart.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'firebase_config.dart';

/// Ошибки Firebase/сети с классификацией для стратегии повторов (§10).
class FirebaseApiException implements Exception {
  final int? statusCode;
  final String message;

  /// Код ошибки Identity Toolkit/securetoken (начало поля `message`, напр.
  /// `INVALID_REFRESH_TOKEN`); null, если ответ без такого кода.
  final String? code;

  /// gRPC-статус из тела ответа (`ABORTED`, `PERMISSION_DENIED`, …).
  final String? status;

  /// RESOURCE_EXHAUSTED (квота), UNAVAILABLE, INTERNAL — повторять с backoff.
  final bool retryable;

  /// PERMISSION_DENIED — правила блокируют; повтор бесполезен.
  final bool permissionDenied;

  /// ABORTED — конкуренция транзакций; повторить чтение и слияние.
  final bool aborted;

  FirebaseApiException(this.message,
      {this.statusCode,
      this.code,
      this.status,
      this.retryable = false,
      this.permissionDenied = false,
      this.aborted = false});

  @override
  String toString() => 'FirebaseApiException($statusCode: $message)';
}

class FirebaseRestClient {
  final http.Client _http = http.Client();
  String? Function() idTokenProvider;

  FirebaseRestClient({String? Function()? idTokenProvider})
      : idTokenProvider = idTokenProvider ?? (() => null);

  // ---------- Аутентификация (identitytoolkit) ----------

  /// Обмен Google-токенов на Firebase-токены (§9): accounts:signInWithIdp.
  /// Identity Toolkit принимает credential в разных ключах postBody —
  /// пробуем `id_token`, затем `access_token` (оба формата документированы
  /// для providerId=google.com).
  Future<AuthTokens> signInWithGoogleIdToken({
    required String googleIdToken,
    String? googleAccessToken,
  }) async {
    final variants = <String>[
      _formEncode({'id_token': googleIdToken, 'providerId': 'google.com'}),
      if (googleAccessToken != null)
        _formEncode(
            {'access_token': googleAccessToken, 'providerId': 'google.com'}),
    ];
    late FirebaseApiException lastError;
    for (final postBody in variants) {
      final response = await _http.post(
        Uri.https('identitytoolkit.googleapis.com',
            '/v1/accounts:signInWithIdp', {'key': FirebaseConfig.apiKey}),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'postBody': postBody,
          'requestUri': 'http://localhost',
          'returnIdpCredential': true,
          'returnSecureToken': true,
        }),
      );
      final body = _tryDecodeMap(response);
      if (response.statusCode == 200 && body != null) {
        final idToken = body['idToken'];
        final refreshToken = body['refreshToken'];
        final localId = body['localId'];
        if (idToken is! String ||
            refreshToken is! String ||
            localId is! String) {
          throw FirebaseApiException(
              'signInWithIdp: unexpected response shape',
              statusCode: response.statusCode);
        }
        final expiresIn = body['expiresIn'];
        return AuthTokens(
          idToken: idToken,
          refreshToken: refreshToken,
          localId: localId,
          email: body['email'] is String ? body['email'] as String : null,
          displayName: body['displayName'] is String
              ? body['displayName'] as String
              : null,
          expiresInSeconds:
              expiresIn is String ? (int.tryParse(expiresIn) ?? 3600) : 3600,
        );
      }
      lastError = _exceptionFor(response, fallback: 'signInWithIdp failed');
      // Неверный формат credential — пробуем следующий вариант.
      if (lastError.code != 'INVALID_CREDENTIAL_OR_PROVIDER_ID' &&
          lastError.code != 'INVALID_IDP_RESPONSE') {
        break;
      }
    }
    throw lastError;
  }

  static String _formEncode(Map<String, String> params) => params.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  /// Безопасное декодирование тела ответа; null — не JSON-объект.
  Map<String, dynamic>? _tryDecodeMap(http.Response response) {
    try {
      final decoded = jsonDecode(_utf8(response));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// Обновление Firebase ID token по refresh token (securetoken).
  Future<AuthTokens> refreshIdToken(String refreshToken) async {
    final response = await _http.post(
      Uri.https('securetoken.googleapis.com', '/v1/token',
          {'key': FirebaseConfig.apiKey}),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      }),
    );
    final body = _tryDecodeMap(response);
    if (response.statusCode != 200 || body == null) {
      throw _exceptionFor(response, fallback: 'token refresh failed');
    }
    final idToken = body['id_token'];
    final newRefresh = body['refresh_token'];
    final userId = body['user_id'];
    if (idToken is! String || newRefresh is! String || userId is! String) {
      throw FirebaseApiException('token refresh: unexpected response shape',
          statusCode: response.statusCode);
    }
    final expiresIn = body['expires_in'];
    return AuthTokens(
      idToken: idToken,
      refreshToken: newRefresh,
      localId: userId,
      expiresInSeconds:
          expiresIn is String ? (int.tryParse(expiresIn) ?? 3600) : 3600,
    );
  }

  // ---------- Firestore REST ----------

  String _documentsUrl(String path) =>
      'https://firestore.googleapis.com/v1/projects/${FirebaseConfig.projectId}'
      '/databases/(default)/documents/$path';

  Map<String, String> _headers() {
    final token = idTokenProvider();
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (token case final token?) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  /// Документ по пути; null — не существует.
  Future<Map<String, dynamic>?> getDocument(String path,
      {String? transaction}) async {
    final base = Uri.parse(_documentsUrl(path));
    final url = transaction == null
        ? base
        : base.replace(queryParameters: {'transaction': transaction});
    final response = await _http.get(url, headers: _headers());
    if (response.statusCode == 404) return null;
    _check(response);
    return jsonDecode(_utf8(response)) as Map<String, dynamic>;
  }

  /// Запрос с structuredQuery; возвращает список документов.
  Future<List<Map<String, dynamic>>> runQuery({
    required String parentPath,
    required Map<String, dynamic> structuredQuery,
  }) async {
    final response = await _http.post(
      Uri.parse('${_documentsUrl(parentPath)}:runQuery'),
      headers: _headers(),
      body: jsonEncode({'structuredQuery': structuredQuery}),
    );
    _check(response);
    final body = jsonDecode(_utf8(response));
    if (body is! List) return const [];
    return [
      for (final item in body)
        if (item is Map<String, dynamic> && item['document'] != null)
          item['document'] as Map<String, dynamic>,
    ];
  }

  /// beginTransaction (readWrite) — для протокола §10.
  Future<String> beginTransaction() async {
    final response = await _http.post(
      Uri.parse('${_documentsUrl('')}:beginTransaction'),
      headers: _headers(),
      body: jsonEncode({'options': {'readWrite': {}}}),
    );
    _check(response);
    final body = jsonDecode(_utf8(response)) as Map<String, dynamic>;
    return body['transaction'] as String;
  }

  /// Откат транзакции, не дошедшей до commit (освобождает блокировки).
  Future<void> rollback(String transaction) async {
    final response = await _http.post(
      Uri.parse('${_documentsUrl('')}:rollback'),
      headers: _headers(),
      body: jsonEncode({'transaction': transaction}),
    );
    _check(response);
  }

  /// Пакетное чтение документов внутри транзакции: для каждого пути —
  /// документ (found) или null (missing).
  Future<List<Map<String, dynamic>?>> batchGet(
    List<String> documentPaths, {
    String? transaction,
  }) async {
    final response = await _http.post(
      Uri.parse('${_documentsUrl('')}:batchGet'),
      headers: _headers(),
      body: jsonEncode({
        'documents': documentPaths
            .map((p) =>
                'projects/${FirebaseConfig.projectId}/databases/(default)/documents/$p')
            .toList(),
        'transaction': ?transaction,
      }),
    );
    _check(response);
    final decoded = jsonDecode(_utf8(response));
    if (decoded is! List) return const [];
    final result = List<Map<String, dynamic>?>.filled(
        documentPaths.length, null,
        growable: false);
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final found = item['found'] as Map<String, dynamic>?;
      if (found == null) continue;
      final name = found['name'] as String? ?? '';
      final index = documentPaths
          .indexWhere((p) => name.endsWith('/documents/$p'));
      if (index >= 0) result[index] = found;
    }
    return result;
  }

  /// commit пакета записей; precondition конкретного документа задаётся
  /// в самой записи (`currentDocument`, §10).
  Future<CommitResult> commit({
    required List<Map<String, dynamic>> writes,
    String? transaction,
  }) async {
    final response = await _http.post(
      Uri.parse('${_documentsUrl('')}:commit'),
      headers: _headers(),
      body: jsonEncode({
        'transaction': ?transaction,
        'writes': writes,
      }),
    );
    _check(response);
    final body = jsonDecode(_utf8(response)) as Map<String, dynamic>;
    final writeResults =
        (body['writeResults'] as List? ?? []).cast<Map<String, dynamic>>();
    return CommitResult(updateTimes: [
      for (final w in writeResults) w['updateTime'] as String?,
    ]);
  }

  /// PUT-записи: value-кодирование полей Firestore.
  static Map<String, dynamic> encodeFields(Map<String, Object?> fields) {
    return {
      'fields': {
        for (final e in fields.entries) e.key: encodeValue(e.value),
      },
    };
  }

  static dynamic encodeValue(Object? value) {
    if (value == null) return {'nullValue': null};
    if (value is bool) return {'booleanValue': value};
    if (value is int) return {'integerValue': '$value'};
    if (value is double) return {'doubleValue': value};
    if (value is String) return {'stringValue': value};
    throw ArgumentError.value(value, 'value', 'unsupported type');
  }

  /// Чтение полей документа Firestore в плоскую карту.
  static Map<String, Object?> decodeFields(Map<String, dynamic> document) {
    final fields = document['fields'] as Map<String, dynamic>? ?? {};
    return {
      for (final e in fields.entries) e.key: decodeValue(e.value),
    };
  }

  static Object? decodeValue(dynamic value) {
    if (value is! Map<String, dynamic>) return null;
    if (value.containsKey('nullValue')) return null;
    if (value.containsKey('booleanValue')) return value['booleanValue'] as bool;
    if (value.containsKey('integerValue')) {
      return int.parse(value['integerValue'] as String);
    }
    if (value.containsKey('doubleValue')) {
      return (value['doubleValue'] as num).toDouble();
    }
    if (value.containsKey('stringValue')) return value['stringValue'] as String;
    if (value.containsKey('timestampValue')) {
      return value['timestampValue'] as String;
    }
    return null;
  }

  void _check(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw _exceptionFor(response, fallback: 'request failed');
  }

  /// Классификация ответа-ошибки. HTTP-код — база (работает и для не-JSON
  /// тела); тело уточняет: ошибки Firestore приходят объектом
  /// `{"error": {...}}`, ошибки runQuery — списком таких объектов.
  FirebaseApiException _exceptionFor(http.Response response,
      {required String fallback}) {
    final httpCode = response.statusCode;
    final body = _utf8(response);

    var retryable = httpCode == 429 || httpCode == 503 || httpCode == 500;
    var permissionDenied = httpCode == 403;
    var aborted = httpCode == 409;

    Map<String, dynamic>? error;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final e = decoded['error'];
        if (e is Map<String, dynamic>) error = e;
      } else if (decoded is List && decoded.isNotEmpty) {
        final first = decoded.first;
        if (first is Map<String, dynamic> &&
            first['error'] is Map<String, dynamic>) {
          error = first['error'] as Map<String, dynamic>;
        }
      }
    } on FormatException {
      // тело не JSON — остаются HTTP-признаки
    }

    var message = body.isEmpty ? '$fallback: HTTP $httpCode' : body;
    String? code;
    String? status;
    if (error != null) {
      final rawMessage = error['message'];
      if (rawMessage is String && rawMessage.isNotEmpty) {
        message = rawMessage;
        final head = RegExp(r'^[A-Z][A-Z0-9_]+').firstMatch(rawMessage);
        code = head?.group(0);
      }
      final grpcStatus = error['status'];
      if (grpcStatus is String) {
        status = grpcStatus;
        permissionDenied |= grpcStatus == 'PERMISSION_DENIED';
        // Не выполненный precondition (updateTime) — та же гонка: перечитать.
        aborted |= grpcStatus == 'ABORTED' ||
            grpcStatus == 'ALREADY_EXISTS' ||
            grpcStatus == 'FAILED_PRECONDITION';
        retryable |= grpcStatus == 'RESOURCE_EXHAUSTED' ||
            grpcStatus == 'UNAVAILABLE' ||
            grpcStatus == 'INTERNAL';
      }
      final numeric = error['code'];
      if (numeric is int) {
        permissionDenied |= numeric == 403;
        aborted |= numeric == 409;
        retryable |= numeric == 429 || numeric == 503 || numeric == 500;
      }
    }

    return FirebaseApiException(message,
        statusCode: httpCode,
        code: code,
        status: status,
        retryable: retryable,
        permissionDenied: permissionDenied,
        aborted: aborted);
  }

  String _utf8(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  void close() => _http.close();
}

/// Токены после входа/обновления.
class AuthTokens {
  final String idToken;
  final String refreshToken;
  final String localId;
  final String? email;
  final String? displayName;
  final int expiresInSeconds;

  AuthTokens({
    required this.idToken,
    required this.refreshToken,
    required this.localId,
    required this.expiresInSeconds,
    this.email,
    this.displayName,
  });
}

class CommitResult {
  final List<String?> updateTimes;
  CommitResult({required this.updateTimes});
}
