/// Сессия (§9): Google-вход по платформам, Firebase-токены в защищённом
/// хранилище ОС (Android Keystore через EncryptedSharedPreferences /
/// Windows DPAPI — см. secure_store.dart), обновление до истечения,
/// выход с выбором сохранения локальной копии.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../cloud/firebase_config.dart';
import '../cloud/firebase_rest.dart';
import '../db/app_database.dart';
import '../diagnostics/diag_log.dart';
import '../ui/providers.dart' show appDatabaseProvider;
import 'google_oauth_desktop.dart';
import 'secure_store.dart';

class Session {
  final String uid;
  final String? email;
  final String? displayName;

  /// Пустой, пока токен не получен после запуска без сети.
  final String idToken;
  final String refreshToken;
  final DateTime expiresAt;

  Session({
    required this.uid,
    required this.idToken,
    required this.refreshToken,
    required this.expiresAt,
    this.email,
    this.displayName,
  });

  bool get isExpiringSoon =>
      DateTime.now().toUtc().isAfter(expiresAt.subtract(const Duration(minutes: 5)));

  /// Есть ли действующий ID token для запросов к облаку.
  bool get hasValidToken =>
      idToken.isNotEmpty && DateTime.now().toUtc().isBefore(expiresAt);
}

/// Состояние авторизации для UI.
sealed class AuthState {
  const AuthState();
}

class AuthSignedOut extends AuthState {
  const AuthSignedOut();
}

class AuthSignedIn extends AuthState {
  final Session session;
  const AuthSignedIn(this.session);
}

class AuthNeedsReauth extends AuthState {
  final String? email;
  const AuthNeedsReauth(this.email);
}

/// Коды Firebase, означающие, что refresh token больше не действителен:
/// нужен повторный вход. Прочие ошибки (сеть, 429/5xx) — временные.
const Set<String> _definitiveAuthCodes = {
  'INVALID_REFRESH_TOKEN',
  'TOKEN_EXPIRED',
  'USER_DISABLED',
  'USER_NOT_FOUND',
  'MISSING_REFRESH_TOKEN',
  'UID_MISMATCH',
};

/// Окончательный отказ в авторизации (а не временный сбой).
@visibleForTesting
bool isDefinitiveAuthFailure(FirebaseApiException e) =>
    !e.retryable && _definitiveAuthCodes.contains(e.code);

/// Сбой сети/TLS/таймаут — сессию сохраняем и повторяем позже.
bool _isNetworkError(Object e) =>
    e is SocketException ||
    e is TlsException ||
    e is TimeoutException ||
    e is http.ClientException;

class AuthService {
  final Ref _ref;
  final FirebaseRestClient _client;
  final SecureStore _storage;
  final DesktopGoogleSignIn _desktopSignIn;

  final _stateController = StreamController<AuthState>.broadcast();
  AuthState _state = const AuthSignedOut();
  Timer? _refreshTimer;
  bool _initialized = false;
  int _retryAttempt = 0;

  AuthService(
    this._ref, {
    FirebaseRestClient? client,
    SecureStore? storage,
    DesktopGoogleSignIn? desktopSignIn,
  })  : _client = client ?? FirebaseRestClient(),
        _storage = storage ?? createSecureStore(),
        _desktopSignIn = desktopSignIn ?? DesktopGoogleSignIn() {
    _client.idTokenProvider = () {
      final current = _state;
      return current is AuthSignedIn && current.session.idToken.isNotEmpty
          ? current.session.idToken
          : null;
    };
  }

  AuthState get state => _state;

  /// Текущее состояние + последующие изменения.
  Stream<AuthState> get stream async* {
    yield _state;
    yield* _stateController.stream;
  }

  void _setState(AuthState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  /// Запуск: восстановление сессии из защищённого хранилища. Отказ в
  /// авторизации — повторный вход; сбой сети — сессия сохраняется (данные
  /// из хранилища), токен обновляется повторами с backoff.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final refreshToken = await _storage.read('auth.refresh_token');
    if (refreshToken == null) {
      dlog('[auth] no saved session');
      _setState(const AuthSignedOut());
      return;
    }
    dlog('[auth] restoring session from secure storage');
    try {
      await _refresh(refreshToken);
      dlog('[auth] session restored');
    } on FirebaseApiException catch (e) {
      if (isDefinitiveAuthFailure(e)) {
        dlog('[auth] restore rejected: ${e.code}');
        await _forceReauth();
      } else {
        dlog('[auth] restore failed (transient): ${e.message}');
        await _restoreOffline(refreshToken);
      }
    } catch (e) {
      if (!_isNetworkError(e)) rethrow;
      dlog('[auth] restore failed (network): ${e.runtimeType}');
      await _restoreOffline(refreshToken);
    }
  }

  /// Сессия из сохранённых данных без действующего ID token; обновление
  /// повторится по таймеру.
  Future<void> _restoreOffline(String refreshToken) async {
    final uid = await _storage.read('auth.uid');
    if (uid == null) {
      // Без UID сессию восстановить нельзя — данные повреждены.
      await _forceReauth();
      return;
    }
    final expiresAtMs =
        int.tryParse(await _storage.read('auth.expires_at') ?? '');
    final session = Session(
      uid: uid,
      idToken: '',
      refreshToken: refreshToken,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtMs ?? 0,
          isUtc: true),
      email: await _readOptional('auth.email'),
      displayName: await _readOptional('auth.display_name'),
    );
    _setState(AuthSignedIn(session));
    _scheduleRetry();
  }

  Future<String?> _readOptional(String key) async {
    final value = await _storage.read(key);
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> _forceReauth() async {
    final email = await _readOptional('auth.email');
    _refreshTimer?.cancel();
    await _clearCredentials();
    _setState(AuthNeedsReauth(email));
  }

  /// Вход через Google: платформенный флоу, затем обмен на Firebase-токены.
  Future<Session> signIn() async {
    dlog('[auth] sign-in started (${Platform.operatingSystem})');
    String googleIdToken;
    String? googleAccessToken;
    if (Platform.isAndroid) {
      googleIdToken = await _signInAndroid();
    } else {
      final googleTokens = await _desktopSignIn.signIn();
      googleIdToken = googleTokens.idToken;
      googleAccessToken = googleTokens.accessToken;
    }
    final tokens = await _client.signInWithGoogleIdToken(
      googleIdToken: googleIdToken,
      googleAccessToken: googleAccessToken,
    );

    final session = Session(
      uid: tokens.localId,
      idToken: tokens.idToken,
      refreshToken: tokens.refreshToken,
      email: tokens.email,
      displayName: tokens.displayName,
      expiresAt:
          DateTime.now().toUtc().add(Duration(seconds: tokens.expiresInSeconds)),
    );
    await _persist(session);
    _retryAttempt = 0;
    _setState(AuthSignedIn(session));
    _scheduleRefresh(session);
    dlog('[auth] sign-in OK: uid=${session.uid}');
    return session;
  }

  /// Android: Credential Manager (google_sign_in 7.x). serverClientId
  /// включает выдачу id_token (§9).
  Future<String> _signInAndroid() async {
    final signIn = GoogleSignIn.instance;
    await signIn.initialize(
      serverClientId: FirebaseConfig.webClientId,
      nonce: const Uuid().v4(),
    );
    final account = await signIn.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw FirebaseApiException('Google sign-in returned no id_token');
    }
    return idToken;
  }

  Future<void> _persist(Session session) async {
    await _storage.write('auth.refresh_token', session.refreshToken);
    await _storage.write('auth.uid', session.uid);
    await _storage.write('auth.email', session.email ?? '');
    await _storage.write('auth.display_name', session.displayName ?? '');
    await _storage.write('auth.expires_at',
        session.expiresAt.millisecondsSinceEpoch.toString());
  }

  Future<void> _refresh(String refreshToken) async {
    final tokens = await _client.refreshIdToken(refreshToken);
    dlog('[auth] token refreshed');
    // Один Google-аккаунт даёт одинаковый Firebase UID на всех платформах (§9).
    final storedUid = await _storage.read('auth.uid');
    if (storedUid != null && storedUid != tokens.localId) {
      throw FirebaseApiException('uid mismatch between platforms',
          code: 'UID_MISMATCH');
    }
    final session = Session(
      uid: tokens.localId,
      idToken: tokens.idToken,
      refreshToken: tokens.refreshToken,
      expiresAt:
          DateTime.now().toUtc().add(Duration(seconds: tokens.expiresInSeconds)),
      // securetoken не возвращает профиль — сохраняем прежний.
      email: await _readOptional('auth.email'),
      displayName: await _readOptional('auth.display_name'),
    );
    await _persist(session);
    _retryAttempt = 0;
    _setState(AuthSignedIn(session));
    _scheduleRefresh(session);
  }

  void _scheduleRefresh(Session session) {
    _refreshTimer?.cancel();
    final until = session.expiresAt
        .subtract(const Duration(minutes: 10))
        .difference(DateTime.now().toUtc());
    _refreshTimer = Timer(
      until.isNegative ? const Duration(seconds: 30) : until,
      () => unawaited(_refreshInBackground()),
    );
  }

  /// Повтор обновления с экспоненциальной задержкой (30 с … 10 мин).
  void _scheduleRetry() {
    _refreshTimer?.cancel();
    final seconds = min(30 * (1 << min(_retryAttempt, 5)), 600);
    _retryAttempt++;
    _refreshTimer = Timer(
      Duration(seconds: seconds),
      () => unawaited(_refreshInBackground()),
    );
  }

  Future<void> _refreshInBackground() async {
    final current = _state;
    if (current is! AuthSignedIn) return;
    try {
      await _refresh(current.session.refreshToken);
    } on FirebaseApiException catch (e) {
      if (isDefinitiveAuthFailure(e)) {
        dlog('[auth] refresh rejected: ${e.code}');
        await _forceReauth();
      } else {
        dlog('[auth] refresh failed, will retry: ${e.message}');
        _scheduleRetry();
      }
    } catch (e) {
      if (!_isNetworkError(e)) rethrow;
      dlog('[auth] refresh failed (network), will retry');
      _scheduleRetry();
    }
  }

  /// Выход (§9): спросить, оставить ли локальную копию; облако не удаляется.
  Future<void> signOut({required bool keepLocalCopy}) async {
    _refreshTimer?.cancel();
    if (Platform.isAndroid) {
      try {
        final signIn = GoogleSignIn.instance;
        await signIn.signOut();
      } catch (_) {
        // сессия могла уже отсутствовать
      }
    }
    await _clearCredentials();
    if (!keepLocalCopy) {
      await _wipeLocalData();
    }
    _setState(const AuthSignedOut());
  }

  Future<void> _clearCredentials() async {
    await _storage.clearAll(const [
      'auth.refresh_token',
      'auth.uid',
      'auth.email',
      'auth.display_name',
      'auth.expires_at',
    ]);
  }

  /// Полное удаление локальных данных (по явному выбору пользователя):
  /// сущности, синхронизационные таблицы и конфликты (§9: другой аккаунт
  /// не должен получить оставленную копию).
  Future<void> _wipeLocalData() async {
    final db = _ref.read(appDatabaseProvider);
    await db.transaction(() async {
      await db.customStatement(
          'DELETE FROM folders; DELETE FROM notes; DELETE FROM task_lists; '
          'DELETE FROM tasks; DELETE FROM tags; DELETE FROM entity_tags; '
          'DELETE FROM recurrence_rules; DELETE FROM task_occurrences; '
          'DELETE FROM reminders; DELETE FROM conflicts; '
          'DELETE FROM outbox_entries; DELETE FROM deletion_markers; '
          'DELETE FROM sync_base');
      // sync_state: новый workspace под следующий вход.
      await db.customStatement(
          'UPDATE sync_state SET workspace_epoch = 1, commit_cursor = 0, '
          'local_counter = 0');
      // Привязка к аккаунту снимается вместе с данными, иначе следующий
      // вход получил бы вечный workspaceMismatch.
      await db.customStatement(
          'DELETE FROM device_settings WHERE `key` = ?',
          ['sync.workspace_uid']);
    });
  }

  /// Восстановить «Входящие» после полного стирания данных.
  Future<void> rebootstrapAfterWipe() async {
    final db = _ref.read(appDatabaseProvider);
    await db.customStatement(
        'DELETE FROM task_lists WHERE id = ?', [inboxListId]);
    await db.into(db.taskLists).insert(TaskListsCompanion.insert(
      id: inboxListId,
      isSystem: const Value(true),
      modifiedAt: Value(DateTime.now().toUtc()),
    ));
  }

  void dispose() {
    _refreshTimer?.cancel();
    _stateController.close();
    _client.close();
    _desktopSignIn.dispose();
  }
}

final authServiceProvider = Provider<AuthService>((ref) {
  final service = AuthService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// Реактивное состояние авторизации.
final authStateProvider = StreamProvider<AuthState>((ref) {
  final service = ref.watch(authServiceProvider);
  // Инициализация при первом чтении состояния; сбой не должен оставаться
  // необработанным (состояние тогда остаётся прежним).
  unawaited(service.initialize().catchError((Object e, StackTrace s) {
    dlog('[auth] initialize failed: $e');
  }));
  return service.stream;
});
