/// Движок синхронизации (§10): локальная SQLite — источник для UI; каждая
/// мутация уже лежит в outbox (одна транзакция с мутацией). Отправка —
/// транзакционные пакеты; каждый записанный документ получает собственный
/// commit_seq (workspace.commit_seq растёт на число документов), поэтому
/// получение — постраничный запрос commit_seq выше курсора — не теряет
/// документы между страницами. Курсор двигается только после локальной
/// транзакции. Автослияние — трёхстороннее по sync_base; сомнение сохраняет
/// обе версии в «Конфлікти».
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../auth/auth_service.dart';
import '../cloud/firebase_config.dart';
import '../cloud/firebase_rest.dart';
import '../data/outbox_ledger.dart';
import '../data/tags_service.dart' show entityTagId;
import '../db/app_database.dart';
import '../diagnostics/diag_log.dart';
import '../domain/due_spec.dart';
import '../ui/providers.dart' show appDatabaseProvider, settingsServiceProvider;
import 'sync_mapper.dart';
import 'sync_merge.dart';

/// Статус синхронизации для UI.
///
/// [copyWith]: nullable-поля ([lastSyncAt], [error]) сохраняются, если не
/// переданы, а явная передача `null` сбрасывает значение; булевы и
/// [pendingOps] при отсутствии аргумента сохраняют текущее значение —
/// флаги, которые должны сброситься (ошибка, mismatch, epoch), вызывающий
/// код задаёт явно.
class SyncStatus {
  final bool running;
  final DateTime? lastSyncAt;
  final String? error;
  final bool permissionDenied;
  final int pendingOps;

  /// Локальные данные принадлежат другому аккаунту (§9).
  final bool workspaceMismatch;

  /// Сервер перешёл на новый epoch; требуется явное решение пользователя
  /// (§12): принять новый снимок, потеряв несинхронизированные изменения.
  final bool epochSwitchRequired;

  const SyncStatus({
    this.running = false,
    this.lastSyncAt,
    this.error,
    this.permissionDenied = false,
    this.pendingOps = 0,
    this.workspaceMismatch = false,
    this.epochSwitchRequired = false,
  });

  static const Object _unset = Object();

  SyncStatus copyWith({
    bool? running,
    Object? lastSyncAt = _unset,
    Object? error = _unset,
    bool? permissionDenied,
    int? pendingOps,
    bool? workspaceMismatch,
    bool? epochSwitchRequired,
  }) =>
      SyncStatus(
        running: running ?? this.running,
        lastSyncAt: lastSyncAt == _unset
            ? this.lastSyncAt
            : lastSyncAt as DateTime?,
        error: error == _unset ? this.error : error as String?,
        permissionDenied: permissionDenied ?? this.permissionDenied,
        pendingOps: pendingOps ?? this.pendingOps,
        workspaceMismatch: workspaceMismatch ?? this.workspaceMismatch,
        epochSwitchRequired: epochSwitchRequired ?? this.epochSwitchRequired,
      );
}

/// Решение по исходящей операции относительно текущего состояния облака.
enum PushDecision {
  /// Записать операцию в облако.
  write,

  /// Облако уже содержит эту операцию (повтор после потерянного ack).
  alreadyApplied,

  /// Облако новее/конкурирует: операцию не писать, итог придёт pull-ом.
  stale,
}

/// Облако перешло на другой epoch, чем у устройства (§12).
class _EpochSwitched implements Exception {
  final int serverEpoch;
  _EpochSwitched(this.serverEpoch);
}

class SyncEngine {
  final Ref _ref;
  Timer? _timer;
  int _queued = 0;
  Future<void> _lock = Future.value();
  final _statusController = StreamController<SyncStatus>.broadcast();
  SyncStatus _status = const SyncStatus();
  static const Duration _interval = Duration(seconds: 30);
  static const int _pushChunkSize = 400;
  static const int _maxPushAttempts = 5;

  /// Размер страницы pull (лимит runQuery).
  @visibleForTesting
  int pullPageSize = 300;

  /// Пауза перед повтором push (§10): экспоненциальный backoff.
  @visibleForTesting
  Duration Function(int attempt) retryDelay = (attempt) =>
      Duration(milliseconds: min(250 * (1 << attempt), 8000));

  SyncEngine(this._ref);

  SyncStatus get status => _status;

  AppDatabase get _db => _ref.read(appDatabaseProvider);
  FirebaseRestClient get _client => _ref.read(firebaseRestClientProvider);

  Stream<SyncStatus> get stream async* {
    yield _status;
    yield* _statusController.stream;
  }

  void _update(SyncStatus next) {
    _status = next;
    if (!_statusController.isClosed) _statusController.add(next);
  }

  void start() {
    if (_timer != null) return;
    // Немедленно при запуске/возврате (§10).
    unawaited(syncNow());
    _timer = Timer.periodic(_interval, (_) {
      if (_queued == 0) unawaited(syncNow());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Все операции, меняющие состояние синхронизации, выполняются строго
  /// по очереди: ожидающая операция дожидается предыдущей, а не пропускается.
  Future<T> _exclusive<T>(Future<T> Function() action) {
    _queued++;
    final run = _lock.then((_) => action());
    _lock = run.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      _queued--;
    });
    return run;
  }

  Future<void> syncNow() => _exclusive(_syncLocked);

  AuthSignedIn? _signedIn() {
    final state = _ref.read(authServiceProvider).state;
    return state is AuthSignedIn ? state : null;
  }

  /// Привязка локальных данных к аккаунту (§9) — ДО любого сетевого
  /// запроса: другой аккаунт не должен получить копию, оставленную
  /// предыдущим. false — данные чужого аккаунта (статус уже обновлён).
  Future<bool> _bindWorkspace(String uid) async {
    final settings = _ref.read(settingsServiceProvider);
    var workspaceUid = await settings.getString('sync.workspace_uid');
    // Совместимость: старые версии хранили JSON-строку ('"uid"').
    if (workspaceUid != null &&
        workspaceUid.length >= 2 &&
        workspaceUid.startsWith('"') &&
        workspaceUid.endsWith('"')) {
      workspaceUid = workspaceUid.substring(1, workspaceUid.length - 1);
    }
    if (workspaceUid != null && workspaceUid != uid) {
      dlog('[sync] workspace mismatch: $workspaceUid != $uid');
      _update(_status.copyWith(
        running: false,
        error: 'workspace belongs to another account',
        workspaceMismatch: true,
        pendingOps: await _outboxCount(),
      ));
      return false;
    }
    if (workspaceUid == null) {
      await settings.setString('sync.workspace_uid', uid);
    }
    return true;
  }

  Future<void> _syncLocked() async {
    final session = _signedIn()?.session;
    if (session == null) {
      dlog('[sync] syncNow skipped: not signed in');
      return;
    }
    if (!session.hasValidToken) {
      dlog('[sync] syncNow skipped: no valid token yet');
      return;
    }
    dlog('[sync] syncNow started (uid=${session.uid})');
    _update(_status.copyWith(
      running: true,
      error: null,
      permissionDenied: false,
      workspaceMismatch: false,
      epochSwitchRequired: false,
    ));
    try {
      if (!await _bindWorkspace(session.uid)) return;

      final db = _db;
      final state = await db.select(db.syncState).getSingle();

      final activeEpoch = await _ensureWorkspace(session.uid);
      dlog('[sync] workspace ensured');
      if (activeEpoch != state.workspaceEpoch) {
        await _flagEpochSwitch(activeEpoch, state.workspaceEpoch);
        return;
      }
      await pushOutbox(session.uid, state.workspaceEpoch);
      dlog('[sync] outbox drained');
      if (!await pullChanges(session.uid)) return;
      dlog('[sync] changes pulled');
      _update(_status.copyWith(
        running: false,
        lastSyncAt: DateTime.now().toUtc(),
        error: null,
        permissionDenied: false,
        workspaceMismatch: false,
        epochSwitchRequired: false,
        pendingOps: await _outboxCount(),
      ));
      dlog('[sync] OK');
    } on _EpochSwitched catch (e) {
      final state = await _db.select(_db.syncState).getSingle();
      await _flagEpochSwitch(e.serverEpoch, state.workspaceEpoch);
    } on FirebaseApiException catch (e) {
      dlog('[sync] FirebaseApiException: '
          '${e.message} (denied=${e.permissionDenied})');
      _update(_status.copyWith(
        running: false,
        error: e.message,
        permissionDenied: e.permissionDenied,
        pendingOps: await _outboxCount(),
      ));
    } catch (e) {
      dlog('[sync] unexpected error: $e');
      _update(_status.copyWith(
          running: false,
          error: e.toString(),
          workspaceMismatch: false,
          epochSwitchRequired: false,
          pendingOps: await _outboxCount()));
    }
  }

  Future<int> _outboxCount() async {
    final row = await _db
        .customSelect('SELECT COUNT(*) AS c FROM outbox_entries')
        .getSingle();
    return row.data['c'] as int;
  }

  /// Устройство старого epoch (§12): смена — явное решение пользователя,
  /// потому что новый снимок затирает несинхронизированные изменения.
  /// Синхронизация останавливается без каких-либо удалений.
  Future<void> _flagEpochSwitch(int serverEpoch, int localEpoch) async {
    dlog('[sync] epoch switch required: '
        'server=$serverEpoch local=$localEpoch');
    _update(_status.copyWith(
      running: false,
      error: 'server switched to a newer workspace snapshot',
      epochSwitchRequired: true,
      pendingOps: await _outboxCount(),
    ));
  }

  // ---------- Workspace / epoch ----------

  String _workspacePath(String uid) => 'workspaces/$uid';

  String _entitiesPath(String uid, int epoch) =>
      'workspaces/$uid/epochs/$epoch/entities';

  static String _docName(String path) =>
      'projects/${FirebaseConfig.projectId}/databases/(default)/documents/'
      '$path';

  /// Создаёт workspace при первом входе; возвращает его active_epoch.
  Future<int> _ensureWorkspace(String uid) async {
    final client = _client;
    var doc = await client.getDocument(_workspacePath(uid));
    // Гонка при первом создании (два клиента одновременно видят 404):
    // оба делают commit c exists:false — проигравший получает 409 и
    // перечитывает документ; ожидаемая ситуация, не ошибка.
    for (var attempt = 0; doc == null && attempt < 3; attempt++) {
      try {
        await client.commit(writes: [
          {
            'update': {
              'name': _docName(_workspacePath(uid)),
              ...FirebaseRestClient.encodeFields(
                  {'active_epoch': 1, 'commit_seq': 0}),
            },
            'currentDocument': {'exists': false},
          },
        ]);
        dlog('[sync] workspace created');
        return 1;
      } on FirebaseApiException catch (e) {
        if (!e.aborted) rethrow;
        doc = await client.getDocument(_workspacePath(uid));
      }
    }
    if (doc == null) {
      throw FirebaseApiException('workspace creation raced repeatedly');
    }
    return _activeEpoch(FirebaseRestClient.decodeFields(doc));
  }

  int _activeEpoch(Map<String, Object?> workspaceFields) =>
      (workspaceFields['active_epoch'] as int?) ?? 1;

  // ---------- Push (outbox → облако) ----------

  @visibleForTesting
  Future<void> pushOutbox(String uid, int epoch) async {
    final db = _db;
    final ops = await (db.select(db.outboxEntries)
          ..orderBy([(o) => OrderingTerm.asc(o.createdAt)]))
        .get();
    dlog('[sync] outbox ops: ${ops.length}');
    for (var i = 0; i < ops.length; i += _pushChunkSize) {
      await _pushChunk(
          uid, epoch, ops.sublist(i, min(i + _pushChunkSize, ops.length)));
    }
  }

  static String _opKey(OutboxEntry op) =>
      '${op.entityType.index}:${op.entityId}';

  static Map<String, Object?> _opPayload(OutboxEntry op) =>
      canonicalPayload(decodePayload(op.payload));

  Future<void> _pushChunk(
      String uid, int epoch, List<OutboxEntry> chunk) async {
    final client = _client;
    final db = _db;
    // Несколько операций над одной сущностью в пакете: пишется последняя
    // (снапшот), остальные покрыты ею.
    final latest = <String, OutboxEntry>{
      for (final op in chunk) _opKey(op): op,
    };
    final targets = latest.values.toList();
    final docPaths = [
      for (final op in targets)
        '${_entitiesPath(uid, epoch)}/${op.entityId}',
    ];

    for (var attempt = 0; attempt < _maxPushAttempts; attempt++) {
      String? txn;
      var committed = false;
      try {
        txn = await client.beginTransaction();
        final ws =
            await client.getDocument(_workspacePath(uid), transaction: txn);
        if (ws == null) {
          await _ensureWorkspace(uid);
          continue;
        }
        final fields = FirebaseRestClient.decodeFields(ws);
        // Устройство старого epoch не пишет в чужой снимок (§12).
        final activeEpoch = _activeEpoch(fields);
        if (activeEpoch != epoch) throw _EpochSwitched(activeEpoch);
        final baseSeq = (fields['commit_seq'] as int?) ?? 0;
        final wsUpdateTime = ws['updateTime'] as String;

        // Повтор после сбоя (commit прошёл, локальный ack нет): сверяемся
        // с текущим состоянием облака, чтобы не затереть более новую версию
        // другого устройства.
        final remoteDocs = await client.batchGet(docPaths, transaction: txn);

        final entityWrites = <Map<String, dynamic>>[];
        final confirmed = <OutboxEntry>[];
        var seq = baseSeq;
        for (var i = 0; i < targets.length; i++) {
          final op = targets[i];
          final remote = remoteDocs[i];
          switch (decideOp(op, remote)) {
            case PushDecision.write:
              seq++;
              final cloudRevision = remote == null
                  ? 0
                  : (FirebaseRestClient.decodeFields(remote)['revision']
                          as int? ??
                      0);
              entityWrites.add(_entityWrite(uid, epoch, op, seq,
                  tombstoneRevision: cloudRevision + 1));
              confirmed.add(op);
            case PushDecision.alreadyApplied:
              confirmed.add(op);
            case PushDecision.stale:
              dlog('[sync] skip stale op ${op.changeKind} '
                  '${op.entityId} (cloud is newer)');
          }
        }

        if (entityWrites.isNotEmpty) {
          await client.commit(
            writes: [
              {
                'update': {
                  'name': _docName(_workspacePath(uid)),
                  ...FirebaseRestClient.encodeFields({'commit_seq': seq}),
                },
                // Только счётчик: без маски запись заменила бы документ
                // целиком и стёрла active_epoch.
                'updateMask': {
                  'fieldPaths': ['commit_seq'],
                },
                // Precondition по прочитанной версии (§10).
                'currentDocument': {'updateTime': wsUpdateTime},
              },
              ...entityWrites,
            ],
            transaction: txn,
          );
          committed = true;
        }

        // Outbox чистится для всех операций пакета: пропущенные (stale) уже
        // покрыты более новым состоянием облака — их восстановит pull.
        // Подтверждённая база: base_revision = отправленной ревизии,
        // sync_base — снапшот отправленного payload (§10).
        await db.transaction(() async {
          await (db.delete(db.outboxEntries)
                ..where(
                    (o) => o.operationId.isIn(chunk.map((c) => c.operationId))))
              .go();
          for (final op in confirmed) {
            if (op.changeKind != 'upsert') continue;
            final payload = _opPayload(op);
            await _confirmLocalBase(db, op.entityType, op.entityId, payload,
                payload['revision'] as int? ?? 1);
          }
        });
        return;
      } on FirebaseApiException catch (e) {
        if (!(e.aborted || e.retryable)) rethrow;
        dlog('[sync] push attempt ${attempt + 1} failed '
            '(${e.aborted ? 'aborted' : 'retryable'}): ${e.message}');
      } finally {
        if (txn != null && !committed) await _rollbackQuietly(client, txn);
      }
      if (attempt + 1 < _maxPushAttempts) {
        await Future<void>.delayed(retryDelay(attempt));
      }
    }
    throw FirebaseApiException('outbox commit failed after '
        '$_maxPushAttempts attempts');
  }

  Future<void> _rollbackQuietly(FirebaseRestClient client, String txn) async {
    try {
      await client.rollback(txn);
    } on FirebaseApiException catch (e) {
      // Транзакция могла уже истечь/быть отменена сервером.
      dlog('[sync] rollback failed: ${e.message}');
    }
  }

  /// Защита повторной отправки: операция применяется, только если облако
  /// не содержит более нового или конкурирующего состояния этой сущности.
  @visibleForTesting
  static PushDecision decideOp(OutboxEntry op, Map<String, dynamic>? remote) {
    if (remote == null) return PushDecision.write;
    final fields = FirebaseRestClient.decodeFields(remote);
    // Тот же op уже в облаке: commit прошёл, потерялся только локальный ack.
    if (fields['last_op_id'] == op.operationId) {
      return PushDecision.alreadyApplied;
    }
    final cloudDeleted = fields['deleted'] as bool? ?? false;
    final cloudModifiedAt = parseDate(fields['modified_at']);
    if (op.changeKind == 'delete') {
      // Удаление против редактирования — по поздней дате действия (§10);
      // при равенстве удаление выигрывает.
      if (cloudDeleted) return PushDecision.stale;
      final newer = cloudModifiedAt != null &&
          cloudModifiedAt.isAfter(op.createdAt);
      return newer ? PushDecision.stale : PushDecision.write;
    }
    if (cloudDeleted) {
      // Редактирование восстанавливает запись, только если оно позднее.
      final later = cloudModifiedAt == null ||
          op.createdAt.isAfter(cloudModifiedAt);
      return later ? PushDecision.write : PushDecision.stale;
    }
    final cloudRevision = fields['revision'] as int? ?? 0;
    final opRevision = _opPayload(op)['revision'] as int? ?? 1;
    // Равная ревизия с другим op — параллельная правка другого устройства:
    // не перезаписываем, слияние выполнит pull.
    return opRevision > cloudRevision
        ? PushDecision.write
        : PushDecision.stale;
  }

  Map<String, dynamic> _entityWrite(
      String uid, int epoch, OutboxEntry op, int seq,
      {required int tombstoneRevision}) {
    final deleted = op.changeKind == 'delete';
    final payload = deleted ? <String, Object?>{} : _opPayload(op);
    return {
      'update': {
        'name': _docName('${_entitiesPath(uid, epoch)}/${op.entityId}'),
        ...FirebaseRestClient.encodeFields({
          'type': op.entityType.index,
          'revision':
              deleted ? tombstoneRevision : payload['revision'] as int? ?? 1,
          'base_revision': payload['base_revision'] ?? 0,
          'commit_seq': seq,
          'modified_at': op.createdAt.toUtc().toIso8601String(),
          'deleted': deleted,
          'device_id': payload['device_id'] ?? '',
          'payload': deleted ? '' : encodePayload(payload),
          'last_op_id': op.operationId,
        }),
      },
    };
  }

  /// Первый вход (§9): объединение локальных и облачных записей.
  /// Порядок важен: сначала pull — облачные версии применяются трёхсторонним
  /// слиянием (конфликты сохраняются в «Конфлікти»), и только потом
  /// локальные сущности ставятся в outbox и отправляются. Иначе локальный
  /// push мог бы затереть облачную версию до слияния.
  Future<void> initialMerge() => _exclusive(() async {
        final session = _signedIn()?.session;
        if (session == null || !session.hasValidToken) return;
        if (!await _bindWorkspace(session.uid)) return;
        final db = _db;

        final activeEpoch = await _ensureWorkspace(session.uid);
        final state = await db.select(db.syncState).getSingle();
        if (activeEpoch != state.workspaceEpoch) {
          await _flagEpochSwitch(activeEpoch, state.workspaceEpoch);
          return;
        }
        if (!await pullChanges(session.uid)) return;

        final ledger = OutboxLedger(db);
        final pending = {
          for (final op in await db.select(db.outboxEntries).get()) _opKey(op),
        };
        for (final type in SyncEntityType.values) {
          for (final id in await _localEntityIds(db, type)) {
            if (pending.contains('${type.index}:$id')) continue;
            final payload = await readEntityPayload(db, type, id);
            if (payload == null) continue;
            await ledger.recordUpsert(type, id, payload);
          }
        }
        await _syncLocked();
      });

  Future<List<String>> _localEntityIds(
      AppDatabase db, SyncEntityType type) async {
    if (type == SyncEntityType.entityTag) {
      final rows = await db.select(db.entityTags).get();
      return [
        for (final r in rows) entityTagId(r.entityKind, r.entityId, r.tagId),
      ];
    }
    final rows =
        await db.customSelect('SELECT id FROM ${_tableOf(type)}').get();
    return [for (final r in rows) r.data['id'] as String];
  }

  // ---------- Pull (облако → локально) ----------

  /// Забирает изменения выше курсора. false — сервер на другом epoch:
  /// статус выставлен, данные не тронуты.
  @visibleForTesting
  Future<bool> pullChanges(String uid) async {
    final db = _db;
    final client = _client;

    final ws = await client.getDocument(_workspacePath(uid));
    dlog('[sync] pull: workspace doc '
        '${ws == null ? 'missing' : 'present'}');
    if (ws == null) return true;
    final fields = FirebaseRestClient.decodeFields(ws);
    final activeEpoch = _activeEpoch(fields);
    final serverSeq = (fields['commit_seq'] as int?) ?? 0;

    final state = await db.select(db.syncState).getSingle();
    var cursor = state.commitCursor;

    if (activeEpoch != state.workspaceEpoch) {
      await _flagEpochSwitch(activeEpoch, state.workspaceEpoch);
      return false;
    }

    while (cursor < serverSeq) {
      final docs = await client.runQuery(
        parentPath: _entitiesPath(uid, activeEpoch),
        structuredQuery: {
          'from': [
            {'collectionId': 'entities'},
          ],
          'where': {
            'fieldFilter': {
              'field': {'fieldPath': 'commit_seq'},
              'op': 'GREATER_THAN',
              'value': {'integerValue': '$cursor'},
            },
          },
          'orderBy': [
            {
              'field': {'fieldPath': 'commit_seq'},
              'direction': 'ASCENDING',
            },
          ],
          'limit': pullPageSize,
        },
      );

      var maxSeq = cursor;
      await db.transaction(() async {
        for (final doc in docs) {
          final name = doc['name'] as String? ?? '';
          final entityId = name.split('/').last;
          final docFields = FirebaseRestClient.decodeFields(doc);
          await _applyRemoteEntity(db, entityId, docFields);
          final seq = docFields['commit_seq'] as int? ?? cursor;
          if (seq > maxSeq) maxSeq = seq;
        }
        // Больше документов нет: всё до serverSeq учтено (счётчик мог
        // «перепрыгнуть» перезаписанные документы).
        if (docs.isEmpty) maxSeq = serverSeq;
        // Курсор продвигается только после локальной транзакции (§10).
        await db.customStatement(
            'UPDATE sync_state SET commit_cursor = ?', [maxSeq]);
      });
      if (maxSeq == cursor || docs.length < pullPageSize) break;
      cursor = maxSeq;
    }
    return true;
  }

  /// Резервная копия несинхронизированного перед сменой epoch: outbox-операции
  /// и локальные сущности с revision != base_revision.
  Future<void> _exportPendingBackup(AppDatabase db) async {
    try {
      final ops = await db.select(db.outboxEntries).get();
      final buffer = StringBuffer();
      buffer.writeln('{');
      buffer.writeln('"exported_at": "${DateTime.now().toUtc().toIso8601String()}",');
      buffer.writeln('"outbox": [');
      buffer.writeln(ops
          .map((o) => jsonEncode({
                'operation_id': o.operationId,
                'entity_type': o.entityType.index,
                'entity_id': o.entityId,
                'change_kind': o.changeKind,
                'payload': o.payload,
              }))
          .join(',\n'));
      buffer.writeln('],');
      buffer.writeln('"unsynced_entities": [');
      final unsynced = <String>[];
      for (final pair in <SyncEntityType, String>{
        SyncEntityType.folder: 'folders',
        SyncEntityType.note: 'notes',
        SyncEntityType.taskList: 'task_lists',
        SyncEntityType.task: 'tasks',
        SyncEntityType.tag: 'tags',
      }.entries) {
        final rows = await db
            .customSelect(
                'SELECT * FROM ${pair.value} WHERE revision != base_revision '
                'AND deleted_at IS NULL')
            .get();
        for (final row in rows) {
          unsynced.add(jsonEncode({
            'table': pair.value,
            'id': row.data['id'],
            'row': row.data.map((k, v) => MapEntry(
                k,
                v is DateTime
                    ? v.toUtc().toIso8601String()
                    : v)),
          }));
        }
      }
      buffer.writeln(unsynced.join(',\n'));
      buffer.writeln(']}');
      final docs = await getApplicationDocumentsDirectory();
      final file = File('${docs.path}${Platform.pathSeparator}'
          'epoch-backup-${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(buffer.toString(), flush: true);
      dlog('[sync] backup written: ${file.path}');
    } catch (e) {
      dlog('[sync] backup export failed (continuing): $e');
    }
  }

  /// Явно подтверждённая пользователем смена epoch (§12): несинхронизированные
  /// локальные изменения будут потеряны — кнопка в диагностике предупреждает
  /// об этом. Вызывается только по решению пользователя, никогда автоматически.
  Future<void> acceptEpochSnapshot() => _exclusive(() async {
        final db = _db;
        final session = _signedIn()?.session;
        if (session == null) return;

        final state = await db.select(db.syncState).getSingle();
        final pending = await _outboxCount();
        dlog('[sync] epoch snapshot accepted by user: '
            'epoch ${state.workspaceEpoch} → pending ops to discard: $pending');
        // Необратимая операция: перед очисткой сохраняем несинхронизированное
        // в JSON-файл (outbox + локально изменившиеся сущности) — пользователь
        // сможет восстановить содержимое вручную.
        await _exportPendingBackup(db);

        final ws = await _client.getDocument(_workspacePath(session.uid));
        if (ws == null) {
          throw FirebaseApiException(
              'workspace doc missing during epoch accept');
        }
        final newEpoch = _activeEpoch(FirebaseRestClient.decodeFields(ws));

        await db.transaction(() async {
          await db.customStatement(
              'DELETE FROM folders; DELETE FROM notes; DELETE FROM task_lists; '
              'DELETE FROM tasks; DELETE FROM tags; DELETE FROM entity_tags; '
              'DELETE FROM recurrence_rules; DELETE FROM task_occurrences; '
              'DELETE FROM reminders; DELETE FROM conflicts; '
              'DELETE FROM outbox_entries; DELETE FROM sync_base');
          await db.customStatement(
              'UPDATE sync_state SET workspace_epoch = ?, commit_cursor = 0',
              [newEpoch]);
          await db.into(db.taskLists).insert(TaskListsCompanion.insert(
                id: inboxListId,
                isSystem: const Value(true),
                modifiedAt: Value(DateTime.now().toUtc()),
              ));
        });
        dlog('[sync] local data reset to epoch $newEpoch');
        // Полный снимок: курсор 0 → обычный pull вычитает всё.
        await _syncLocked();
      });

  /// Применение одного удалённого документа с автослиянием (§10).
  Future<void> _applyRemoteEntity(AppDatabase db, String entityId,
      Map<String, Object?> docFields) async {
    final typeIndex = docFields['type'] as int? ?? -1;
    if (typeIndex < 0 || typeIndex >= SyncEntityType.values.length) return;
    final type = SyncEntityType.values[typeIndex];
    final remoteRevision = docFields['revision'] as int? ?? 1;
    final remoteDeleted = docFields['deleted'] as bool? ?? false;
    final remoteModifiedAt = parseDate(docFields['modified_at']);
    Map<String, Object?>? remotePayload;
    if (!remoteDeleted) {
      remotePayload = canonicalPayload(
          decodePayload(docFields['payload'] as String? ?? '{}'));
      if (remotePayload.isEmpty) return;
      // Ревизия документа — база для локальной записи.
      remotePayload['revision'] = remoteRevision;
      remotePayload['base_revision'] = remoteRevision;
    }

    final local = await readEntityPayload(db, type, entityId);

    // 1) Локальной записи нет: удалённый маркер → ничего; апсерт → вставить.
    if (local == null) {
      if (remotePayload == null) return; // маркер без контента (§10)
      await applyPayload(db, type, entityId, remotePayload);
      await _storeBase(db, type, entityId, remotePayload, remoteRevision);
      return;
    }

    final localDeleted = local['deleted_at'] != null;
    final localModifiedAt = parseDate(local['modified_at']);
    final localRevision = local['revision'] as int? ?? 1;
    final localBaseRevision = local['base_revision'] as int? ?? 0;

    // Своя же запись, вернувшаяся из облака, — уже синхронна.
    if (remotePayload != null &&
        localRevision == remoteRevision &&
        localBaseRevision == remoteRevision) {
      return;
    }

    // 2) Удаление против редактирования — по поздней дате действия (§10).
    if (remoteDeleted || localDeleted) {
      if (remoteDeleted && localDeleted) return;
      final deletionSideWins = deletionWins(
        localModifiedAt: localModifiedAt,
        remoteModifiedAt: remoteModifiedAt,
        localDeleted: localDeleted,
        remoteDeleted: remoteDeleted,
      );
      if (remoteDeleted) {
        if (deletionSideWins) {
          await _applyLocalDeletion(db, type, entityId,
              modifiedAt: remoteModifiedAt);
        } else {
          // Позднее локальное редактирование восстанавливает запись.
          await _enqueueLocalWin(db, type, entityId, local, remoteRevision);
        }
      } else if (deletionSideWins) {
        // Локальное удаление позднее — уходит в облако.
        await _enqueueLocalWin(db, type, entityId, local, remoteRevision);
      } else {
        // Позднее удалённое редактирование восстанавливает запись.
        await applyPayload(db, type, entityId, remotePayload!);
        await _storeBase(db, type, entityId, remotePayload, remoteRevision);
      }
      return;
    }

    // 3) Обе активны. Локально не менялась с базы → просто принимаем.
    // Локально менялась с подтверждённой базы ⇔ revision != base_revision
    // (база фиксируется при пуше и при применении удалённых изменений).
    final localChangedSinceBase = localRevision != localBaseRevision;
    if (!localChangedSinceBase) {
      await applyPayload(db, type, entityId, remotePayload!);
      await _storeBase(db, type, entityId, remotePayload, remoteRevision);
      return;
    }

    // 4) Изменились обе стороны: трёхстороннее слияние от базы (§10).
    final baseRow = await (db.select(db.syncBase)
          ..where((b) =>
              b.entityId.equals(entityId) &
              b.entityType.equalsValue(type)))
        .getSingleOrNull();
    final base = baseRow != null
        ? decodePayload(baseRow.payload)
        : <String, Object?>{};
    final merged =
        mergePayloads(base: base, local: local, remote: remotePayload!);
    if (!merged.hasConflicts) {
      // Результат уходит в облако (§10) с ревизией выше обеих сторон; базой
      // становится удалённая версия.
      await applyPayload(db, type, entityId, merged.merged);
      await _storeBase(db, type, entityId, remotePayload, remoteRevision);
      await _replaceOutbox(db, type, entityId, merged.merged);
      return;
    }

    // 5) Несовместимые изменения → конфликт: обе версии сохраняются (§10),
    // локальная остаётся активной, удалённая ждёт решения в «Конфліктах».
    await db.into(db.conflicts).insertOnConflictUpdate(ConflictsCompanion.insert(
          id: 'merge:${type.name}:$entityId',
          entityType: type,
          entityId: entityId,
          kind: 'merge',
          basePayload: Value(encodePayload(base)),
          localPayload: encodePayload(local),
          remotePayload: encodePayload(remotePayload),
          createdAt: DateTime.now().toUtc(),
        ));
  }

  Future<void> _applyLocalDeletion(AppDatabase db, SyncEntityType type,
      String entityId, {DateTime? modifiedAt}) async {
    final local = await readEntityPayload(db, type, entityId);
    if (local == null) return;
    if (local['deleted_at'] != null) return;
    final patched = {...local};
    patched['deleted_at'] =
        (modifiedAt ?? DateTime.now().toUtc()).toIso8601String();
    await applyPayload(db, type, entityId, patched);
  }

  /// Локальная версия победила в облаке: ставим её в outbox с ревизией выше
  /// облачной — иначе она будет отброшена как устаревшая.
  Future<void> _enqueueLocalWin(AppDatabase db, SyncEntityType type,
      String entityId, Map<String, Object?> local, int remoteRevision) async {
    final localRevision = local['revision'] as int? ?? 1;
    final payload = {
      ...local,
      'revision': max(localRevision, remoteRevision) + 1,
      'base_revision': remoteRevision,
    };
    await applyPayload(db, type, entityId, payload);
    await _replaceOutbox(db, type, entityId, payload);
  }

  /// Единственная ожидающая операция над сущностью — свежий снапшот.
  Future<void> _replaceOutbox(AppDatabase db, SyncEntityType type,
      String entityId, Map<String, Object?> payload) async {
    await _dropPendingOps(db, type, entityId);
    await OutboxLedger(db).recordUpsert(type, entityId, payload);
  }

  Future<void> _dropPendingOps(
      AppDatabase db, SyncEntityType type, String entityId) {
    return (db.delete(db.outboxEntries)
          ..where((o) =>
              o.entityId.equals(entityId) & o.entityType.equalsValue(type)))
        .go();
  }

  /// base_revision = подтверждённой ревизии; у entity_tags композитный
  /// ключ, обновление по полям payload.
  Future<void> _confirmLocalBase(
      AppDatabase db,
      SyncEntityType type,
      String entityId,
      Map<String, Object?> payload,
      int revision) async {
    if (type == SyncEntityType.entityTag) {
      final rowEntityId = payload['entity_id'] as String?;
      final rowTagId = payload['tag_id'] as String?;
      final rowKind = payload['entity_kind'] as int?;
      if (rowEntityId != null && rowTagId != null && rowKind != null) {
        await (db.update(db.entityTags)
              ..where((e) =>
                  e.entityId.equals(rowEntityId) &
                  e.tagId.equals(rowTagId) &
                  e.entityKind.equalsValue(EntityKind.values[rowKind])))
            .write(EntityTagsCompanion(baseRevision: Value(revision)));
      }
      await _storeBase(db, type, entityId, payload, revision);
      return;
    }
    await db.customStatement(
        'UPDATE ${_tableOf(type)} SET base_revision = ? WHERE id = ?',
        [revision, entityId]);
    await _storeBase(db, type, entityId, payload, revision);
  }

  /// SQL-имя таблицы по типу сущности.
  String _tableOf(SyncEntityType type) => switch (type) {
        SyncEntityType.folder => 'folders',
        SyncEntityType.note => 'notes',
        SyncEntityType.taskList => 'task_lists',
        SyncEntityType.task => 'tasks',
        SyncEntityType.tag => 'tags',
        SyncEntityType.entityTag => 'entity_tags',
        SyncEntityType.reminder => 'reminders',
        SyncEntityType.recurrenceRule => 'recurrence_rules',
        SyncEntityType.taskOccurrence => 'task_occurrences',
      };

  Future<void> _storeBase(AppDatabase db, SyncEntityType type, String entityId,
      Map<String, Object?> payload, int baseRevision) async {
    await db.into(db.syncBase).insertOnConflictUpdate(
          SyncBaseCompanion.insert(
            entityId: entityId,
            entityType: type,
            payload: encodePayload(payload),
            baseRevision: baseRevision,
          ),
        );
  }

  // ---------- Конфликты (§10) ----------

  /// Решение конфликта: выбранная версия применяется локально и снимает
  /// конфликт (удаление разрешённого конфликта не создаёт историю). Выбор
  /// «локальная» уходит в облако с ревизией выше обеих сторон; «удалённая»
  /// отменяет ожидающие локальные операции над сущностью.
  Future<void> resolveConflict(Conflict conflict, bool chooseLocal) =>
      _exclusive(() async {
        final db = _db;
        final type = conflict.entityType;
        final id = conflict.entityId;
        final local = canonicalPayload(decodePayload(conflict.localPayload));
        final remote = canonicalPayload(decodePayload(conflict.remotePayload));
        final remoteRevision = remote['revision'] as int? ?? 1;
        await db.transaction(() async {
          if (chooseLocal) {
            final localRevision = local['revision'] as int? ?? 1;
            final chosen = {
              ...local,
              'revision': max(localRevision, remoteRevision) + 1,
              'base_revision': remoteRevision,
            };
            await applyPayload(db, type, id, chosen);
            await _storeBase(db, type, id, remote, remoteRevision);
            await _replaceOutbox(db, type, id, chosen);
          } else {
            final chosen = {...remote, 'base_revision': remoteRevision};
            await applyPayload(db, type, id, chosen);
            await _storeBase(db, type, id, chosen, remoteRevision);
            await _dropPendingOps(db, type, id);
          }
          await (db.delete(db.conflicts)
                ..where((c) => c.id.equals(conflict.id)))
              .go();
        });
      });

  void dispose() {
    stop();
    _statusController.close();
  }
}

final firebaseRestClientProvider = Provider<FirebaseRestClient>((ref) {
  final auth = ref.watch(authServiceProvider);
  final client = FirebaseRestClient(idTokenProvider: () {
    final state = auth.state;
    return state is AuthSignedIn && state.session.idToken.isNotEmpty
        ? state.session.idToken
        : null;
  });
  ref.onDispose(client.close);
  return client;
});

final outboxLedgerProvider = Provider<OutboxLedger>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return OutboxLedger(db);
});

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(ref);
  ref.onDispose(engine.dispose);
  return engine;
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  return ref.watch(syncEngineProvider).stream;
});
