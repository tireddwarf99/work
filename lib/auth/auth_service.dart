/// Сессия (§9): Google-вход по платформам, Firebase-токены в защищённом
/// хранилище ОС (Android Keystore / Windows DPAPI — flutter_secure_storage),
/// обновление до истечения, выход с выбором сохранения локальной копии.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:uuid/uuid.dart';

import 'secure_store.dart';

import 'package:drift/drift.dart' show Value;

import '../cloud/firebase_config.dart';
import '../cloud/firebase_rest.dart';
import '../db/app_database.dart';
import '../diagnostics/diag_log.dart';
import '../ui/providers.dart' show appDatabaseProvider;
import 'google_oauth_desktop.dart';

class Session {
  final String uid;
  final String? email;
  final String? displayName;
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

class AuthService {
  final Ref _ref;
  final FirebaseRestClient _client;
  final SecureStore _storage;
  final DesktopGoogleSignIn _desktopSignIn;

  final _stateController = StreamController<AuthState>.broadcast();
  AuthState _state = const AuthSignedOut();
  Timer? _refreshTimer;
  bool _initialized = false;

  AuthService(this._ref)
      : _client = FirebaseRestClient(),
        _storage = createSecureStore(),
        _desktopSignIn = DesktopGoogleSignIn() {
    _client.idTokenProvider = () {
      final current = _state;
      return current is AuthSignedIn ? current.session.idToken : null;
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

  /// Запуск: восстановление сессии из защищённого хранилища.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final refreshToken = await _storage.read('auth.refresh_token');
    if (refreshToken == null) {
      dlog('[auth] no saved session');
      _setState(const AuthSignedOut());
      return;
    }
    try {
      dlog('[auth] restoring session from secure storage');
      await _refresh(refreshToken);
      dlog('[auth] session restored');
    } on FirebaseApiException catch (e) {
      // Истечение/отзыв доступа — требуется повторный вход (§9).
      dlog('[auth] restore failed: ${e.message}');
      final email = await _storage.read('auth.email');
      await _clearCredentials();
      _setState(AuthNeedsReauth(email));
    }
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
    _setState(AuthSignedIn(session));
    _scheduleRefresh(session);
    dlog('[auth] sign-in OK: uid=${session.uid} '
        'email=${session.email}');
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
    await _storage.write('auth.expires_at',
        session.expiresAt.millisecondsSinceEpoch.toString());
  }

  Future<void> _refresh(String refreshToken) async {
    final tokens = await _client.refreshIdToken(refreshToken);
    dlog('[auth] token refreshed');
    final session = Session(
      uid: tokens.localId,
      idToken: tokens.idToken,
      refreshToken: tokens.refreshToken,
      expiresAt:
          DateTime.now().toUtc().add(Duration(seconds: tokens.expiresInSeconds)),
      email: await _storage.read('auth.email'),
    );
    // Один Google-аккаунт даёт одинаковый Firebase UID на всех платформах (§9).
    final storedUid = await _storage.read('auth.uid');
    if (storedUid != null && storedUid != session.uid) {
      throw FirebaseApiException('uid mismatch between platforms');
    }
    await _persist(session);
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
      () async {
        final current = _state;
        if (current is AuthSignedIn) {
          try {
            await _refresh(current.session.refreshToken);
          } on FirebaseApiException {
            final email = current.session.email;
            await _clearCredentials();
            _setState(AuthNeedsReauth(email));
          }
        }
      },
    );
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

  /// Монотонный локальный счётчик событий устройства (§10).
  Future<int> nextLocalCounter() async {
    final db = _ref.read(appDatabaseProvider);
    return db.transaction(() async {
      await db.customStatement(
          'UPDATE sync_state SET local_counter = local_counter + 1');
      final row = await db
          .customSelect('SELECT local_counter FROM sync_state')
          .getSingle();
      return row.data['local_counter'] as int;
    });
  }

  /// Оценка смещения от сервера (§10): разница между ответом и локальными
  /// часами уточняется по заголовку Date ответов REST.
  DateTime serverNow() => DateTime.now().toUtc();

  String newDeviceOperationId() => const Uuid().v4();

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
  // Инициализация при первом чтении состояния.
  service.initialize();
  return service.stream;
});
