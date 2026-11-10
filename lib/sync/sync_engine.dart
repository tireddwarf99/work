/// Движок синхронизации (§10): локальная SQLite — источник для UI; каждая
/// мутация уже лежит в outbox (одна транзакция с мутацией). Отправка —
/// транзакционные пакеты с счётчиком commit_seq на epoch; получение —
/// постраничный запрос commit_seq выше курсора; курсор двигается только
/// после локальной транзакции. Автослияние — трёхстороннее по sync_base;
/// сомнение сохраняет обе версии в «Конфлікти».
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_service.dart';
import '../cloud/firebase_config.dart';
import '../cloud/firebase_rest.dart';
import '../data/outbox_ledger.dart';
import '../db/app_database.dart';
import '../diagnostics/diag_log.dart';
import '../domain/due_spec.dart';
import '../ui/providers.dart' show appDatabaseProvider, settingsServiceProvider;
import 'sync_mapper.dart';
import 'sync_merge.dart';

/// Статус синхронизации для UI.
///
/// [copyWith] перезаписывает поля дословно (без `??`): вызывающий код
/// обязан задавать все значимые поля, чтобы ошибки и флаги явно сбрасывались
/// при новой попытке и после успеха.
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

  /// Nullable-поля сохраняются, если не переданы; явная передача `null`
  /// сбрасывает значение. Булевы поля — всегда передавай явно.
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

class SyncEngine {
  final Ref _ref;
  Timer? _timer;
  bool _running = false;
  final _statusController = StreamController<SyncStatus>.broadcast();
  SyncStatus _status = const SyncStatus();
  static const Duration _interval = Duration(seconds: 30);

  SyncEngine(this._ref);

  SyncStatus get status => _status;

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
    _timer = Timer.periodic(_interval, (_) => unawaited(syncNow()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> syncNow() async {
    if (_running) {
      dlog('[sync] syncNow skipped: already running');
      return;
    }
    final auth = _ref.watch(authServiceProvider);
    final session = auth.state is AuthSignedIn
        ? (auth.state as AuthSignedIn).session
        : null;
    if (session == null) {
      dlog('[sync] syncNow skipped: not signed in');
      return;
    }
    dlog('[sync] syncNow started (uid=${session.uid})');
    _running = true;
    _update(_status.copyWith(
      running: true,
      error: null,
      permissionDenied: false,
      workspaceMismatch: false,
      epochSwitchRequired: false,
    ));
    try {
      // Привязка локальных данных к аккаунту — ДО любого сетевого запроса
      // (§9): другой аккаунт не должен получить копию, оставленную
      // предыдущим.
      final settings = _ref.watch(settingsServiceProvider);
      var workspaceUid =
          await settings.getString('sync.workspace_uid');
      // Совместимость: старые версии хранили JSON-строку ('"uid"').
      if (workspaceUid != null &&
          workspaceUid.startsWith('"') &&
          workspaceUid.endsWith('"') &&
          workspaceUid.length >= 2) {
        workspaceUid = workspaceUid.substring(1, workspaceUid.length - 1);
      }
      if (workspaceUid != null && workspaceUid != session.uid) {
        dlog('[sync] workspace mismatch: $workspaceUid != ${session.uid}');
        _update(_status.copyWith(
          running: false,
          error: 'workspace belongs to another account',
          workspaceMismatch: true,
          pendingOps: await _outboxCount(),
        ));
        return;
      }
      if (workspaceUid == null) {
        await settings.setString('sync.workspace_uid', session.uid);
      }

      final db = _ref.watch(appDatabaseProvider);
      final state = await db.select(db.syncState).getSingle();

      await _ensureWorkspace(session.uid);
      dlog('[sync] workspace ensured');
      await _pushOutbox(session.uid, state.workspaceEpoch);
      dlog('[sync] outbox drained');
      await _pullChanges(session.uid);
      dlog('[sync] changes pulled');
      _update(_status.copyWith(
        running: false,
        lastSyncAt: DateTime.now().toUtc(),
        error: null,
        permissionDenied: false,
        workspaceMismatch: false,
        pendingOps: await _outboxCount(),
      ));
      dlog('[sync] OK');
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
    } finally {
      _running = false;
    }
  }

  Future<int> _outboxCount() async {
    final db = _ref.watch(appDatabaseProvider);
    final rows = await db.select(db.outboxEntries).get();
    return rows.length;
  }

  // ---------- Workspace / epoch ----------

  String _workspacePath(String uid) => 'workspaces/$uid';

  String _entitiesPath(String uid, int epoch) =>
      'workspaces/$uid/epochs/$epoch/entities';

  String _entityDocName(String uid, int epoch, String entityId) =>
      'projects/${FirebaseConfig.projectId}/databases/(default)/documents/'
      'workspaces/$uid/epochs/$epoch/entities/$entityId';

  Future<void> _ensureWorkspace(String uid) async {
    final client = _ref.watch(firebaseRestClientProvider);
    var doc = await client.getDocument(_workspacePath(uid));
    if (doc != null) return;
    // Гонка при первом создании (два клиента одновременно видят 404):
    // оба делают commit c exists:false — проигравший получает 409 и
    // перечитывает документ; ожидаемая ситуация, не ошибка.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await client.commit(writes: [
          {
            'update': {
              'name':
                  'projects/${FirebaseConfig.projectId}/databases/(default)/documents/${_workspacePath(uid)}',
              ...FirebaseRestClient.encodeFields(
                  {'active_epoch': 1, 'commit_seq': 0}),
            },
            'currentDocument': {'exists': false},
          },
        ]);
        dlog('[sync] workspace created');
        return;
      } on FirebaseApiException catch (e) {
        if (!e.aborted) rethrow;
        doc = await client.getDocument(_workspacePath(uid));
        if (doc != null) return;
      }
    }
    throw FirebaseApiException('workspace creation raced repeatedly');
  }

  // ---------- Push (outbox → облако) ----------

  Future<void> _pushOutbox(String uid, int epoch) async {
    final db = _ref.watch(appDatabaseProvider);
    final client = _ref.watch(firebaseRestClientProvider);

    final ops = await (db.select(db.outboxEntries)
          ..orderBy([(o) => OrderingTerm.asc(o.createdAt)]))
        .get();
    dlog('[sync] outbox ops: ${ops.length}');
    if (ops.isEmpty) return;

    const chunkSize = 400;
    for (var i = 0; i < ops.length; i += chunkSize) {
      final chunk = ops.sublist(
          i, i + chunkSize > ops.length ? ops.length : i + chunkSize);
      await _pushChunk(uid, epoch, client, db, chunk);
    }
  }

  Future<void> _pushChunk(String uid, int epoch, FirebaseRestClient client,
      AppDatabase db, List<OutboxEntry> chunk) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final txn = await client.beginTransaction();
      final ws = await client.getDocument(_workspacePath(uid),
          transaction: txn);
      if (ws == null) {
        await _ensureWorkspace(uid);
        continue;
      }
      final fields = FirebaseRestClient.decodeFields(ws);
      final seq = ((fields['commit_seq'] as int?) ?? 0) + 1;
      final wsUpdateTime = ws['updateTime'] as String;

      // Повтор после сбоя (commit прошёл, локальный ack нет): сверяемся
      // с текущим состоянием облака, чтобы не затереть более новую версию
      // другого устройства.
      final docPaths = [
        for (final op in chunk) 'workspaces/$uid/epochs/$epoch/entities/${op.entityId}',
      ];
      final remoteDocs =
          await client.batchGet(docPaths, transaction: txn);

      final writes = <Map<String, dynamic>>[
        {
          'update': {
            'name':
                'projects/${FirebaseConfig.projectId}/databases/(default)/documents/${_workspacePath(uid)}',
            ...FirebaseRestClient.encodeFields({'commit_seq': seq}),
          },
          // Precondition по прочитанной версии (§10).
          'currentDocument': {'updateTime': wsUpdateTime},
        },
      ];
      final applied = <OutboxEntry>[];
      for (var i = 0; i < chunk.length; i++) {
        final op = chunk[i];
        final remote = remoteDocs[i];
        if (!_shouldApplyOp(op, remote)) {
          dlog('[sync] skip stale op ${op.changeKind} '
              '${op.entityId} (cloud is newer)');
          continue;
        }
        applied.add(op);
        writes.add(_entityWrite(uid, epoch, op, seq));
      }
      try {
        await client.commit(writes: writes, transaction: txn);
      } on FirebaseApiException catch (e) {
        if (e.aborted) continue; // конкуренция: повторить чтение и слияние
        rethrow;
      }
      // Outbox чистится для всех операций пакета: пропущенные (stale) уже
      // покрыты более новым состоянием облака — их восстановит pull.
      await (db.delete(db.outboxEntries)
            ..where((o) => o.operationId.isIn(chunk.map((c) => c.operationId))))
          .go();
      // Подтверждённая база: base_revision = отправленной ревизии,
      // sync_base — снапшот отправленного payload (§10). Только для
      // фактически применённых операций.
      await db.transaction(() async {
        for (final op in applied) {
          if (op.changeKind != 'upsert') continue;
          final payload = decodePayload(op.payload);
          final revision = payload['revision'] as int? ?? 1;
          await _confirmLocalBase(db, op.entityType, op.entityId, payload,
              revision);
        }
      });
      return;
    }
    throw FirebaseApiException('outbox commit aborted repeatedly');
  }

  /// Защита повторной отправки: операция применяется, только если облако
  /// не содержит более нового состояния этой сущности.
  bool _shouldApplyOp(OutboxEntry op, Map<String, dynamic>? remote) {
    if (remote == null) return true;
    final fields = FirebaseRestClient.decodeFields(remote);
    final cloudRevision = fields['revision'] as int? ?? 0;
    final cloudModifiedAt = parseDate(fields['modified_at'] as String?);
    if (op.changeKind == 'delete') {
      // Удаление против редактирования — по поздней дате действия (§10);
      // при равенстве удаление выигрывает.
      final cloudDeleted = fields['deleted'] as bool? ?? false;
      if (cloudDeleted) return false;
      final local = cloudModifiedAt;
      if (local == null) return true;
      return !local.isAfter(op.createdAt);
    }
    final opRevision =
        (decodePayload(op.payload)['revision'] as int?) ?? 1;
    // Равные ревизии — повтор того же payload, идемпотентно.
    return opRevision >= cloudRevision;
  }

  Map<String, dynamic> _entityWrite(
      String uid, int epoch, OutboxEntry op, int seq) {
    final deleted = op.changeKind == 'delete';
    final payload = deleted ? <String, Object?>{} : decodePayload(op.payload);
    return {
      'update': {
        'name': _entityDocName(uid, epoch, op.entityId),
        ...FirebaseRestClient.encodeFields({
          'type': op.entityType.index,
          'revision': payload['revision'] ?? 1,
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
  Future<void> initialMerge() async {
    final auth = _ref.watch(authServiceProvider);
    final session = auth.state is AuthSignedIn
        ? (auth.state as AuthSignedIn).session
        : null;
    if (session == null) return;
    final db = _ref.watch(appDatabaseProvider);
    final ledger = _ref.watch(outboxLedgerProvider);
    final settings = _ref.watch(settingsServiceProvider);
    final workspaceUid = await settings.getString('sync.workspace_uid');
    if (workspaceUid == null) {
      await settings.setString('sync.workspace_uid', session.uid);
    }

    await _ensureWorkspace(session.uid);
    await _pullChanges(session.uid);

    Future<void> enqueueTable(
        Future<Map<String, Object?>?> Function(String id) loader,
        SyncEntityType type,
        List<String> ids) async {
      for (final id in ids) {
        final payload = await loader(id);
        if (payload == null) continue;
        await ledger.recordUpsert(type, id, payload);
      }
    }

    await enqueueTable(
      (id) => readEntityPayload(db, SyncEntityType.folder, id),
      SyncEntityType.folder,
      (await db.select(db.folders).get()).map((f) => f.id).toList(),
    );
    await enqueueTable(
      (id) => readEntityPayload(db, SyncEntityType.note, id),
      SyncEntityType.note,
      (await db.select(db.notes).get()).map((n) => n.id).toList(),
    );
    await enqueueTable(
      (id) => readEntityPayload(db, SyncEntityType.taskList, id),
      SyncEntityType.taskList,
      (await db.select(db.taskLists).get()).map((l) => l.id).toList(),
    );
    await enqueueTable(
      (id) => readEntityPayload(db, SyncEntityType.task, id),
      SyncEntityType.task,
      (await db.select(db.tasks).get()).map((t) => t.id).toList(),
    );
    await enqueueTable(
      (id) => readEntityPayload(db, SyncEntityType.tag, id),
      SyncEntityType.tag,
      (await db.select(db.tags).get()).map((t) => t.id).toList(),
    );
    await syncNow();
  }

  // ---------- Pull (облако → локально) ----------

  Future<void> _pullChanges(String uid) async {
    final db = _ref.watch(appDatabaseProvider);
    final client = _ref.watch(firebaseRestClientProvider);

    final ws = await client.getDocument(_workspacePath(uid));
    // ignore: avoid_print
    dlog('[sync] pull: workspace doc '
        '${ws == null ? 'missing' : 'present'}');
    if (ws == null) return;
    final fields = FirebaseRestClient.decodeFields(ws);
    final activeEpoch = (fields['active_epoch'] as int?) ?? 1;
    final serverSeq = (fields['commit_seq'] as int?) ?? 0;

    final state = await db.select(db.syncState).getSingle();
    var cursor = state.commitCursor;

    if (activeEpoch != state.workspaceEpoch) {
      // Устройство старого epoch (§12): смена — явное решение пользователя,
      // потому что новый снимок затирает несинхронизированные изменения.
      // Останавливаем синхронизацию без каких-либо удалений.
      dlog('[sync] epoch switch required: '
          'server=$activeEpoch local=${state.workspaceEpoch}');
      _update(_status.copyWith(
        running: false,
        error: 'server switched to a newer workspace snapshot',
        epochSwitchRequired: true,
        pendingOps: await _outboxCount(),
      ));
      return;
    }

    while (cursor < serverSeq) {
      final query = {
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
        'limit': 300,
      };
      final docs = await client.runQuery(
          parentPath: _entitiesPath(uid, activeEpoch),
          structuredQuery: query);
      if (docs.isEmpty) break;

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
        // Курсор продвигается только после локальной транзакции (§10).
        await db.customStatement(
            'UPDATE sync_state SET commit_cursor = ?', [maxSeq]);
      });
      cursor = maxSeq;
      if (docs.length < 300) break;
    }
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
  Future<void> acceptEpochSnapshot() async {
    final db = _ref.watch(appDatabaseProvider);
    final auth = _ref.watch(authServiceProvider);
    final session = auth.state is AuthSignedIn
        ? (auth.state as AuthSignedIn).session
        : null;
    if (session == null) return;

    final state = await db.select(db.syncState).getSingle();
    final pending = await _outboxCount();
    dlog('[sync] epoch snapshot accepted by user: '
        'epoch ${state.workspaceEpoch} → pending ops to discard: $pending');
    // Необратимая операция: перед очисткой сохраняем несинхронизированное
    // в JSON-файл (outbox + локально изменившиеся сущности) — пользователь
    // сможет восстановить содержимое вручную.
    await _exportPendingBackup(db);

    final client = _ref.watch(firebaseRestClientProvider);
    final ws = await client.getDocument(_workspacePath(session.uid));
    if (ws == null) {
      throw FirebaseApiException('workspace doc missing during epoch accept');
    }
    final newEpoch =
        (FirebaseRestClient.decodeFields(ws)['active_epoch'] as int?) ?? 1;

    await db.transaction(() async {
      await db.customStatement(
          'DELETE FROM folders; DELETE FROM notes; DELETE FROM task_lists; '
          'DELETE FROM tasks; DELETE FROM tags; DELETE FROM entity_tags; '
          'DELETE FROM recurrence_rules; DELETE FROM task_occurrences; '
          'DELETE FROM reminders; DELETE FROM outbox_entries; '
          'DELETE FROM sync_base');
      await db.customStatement(
          'UPDATE sync_state SET workspace_epoch = ?, commit_cursor = 0',
          [newEpoch]);
    });
    await db.into(db.taskLists).insert(TaskListsCompanion.insert(
      id: inboxListId,
      isSystem: const Value(true),
      modifiedAt: Value(DateTime.now().toUtc()),
    ));
    dlog('[sync] local data reset to epoch $newEpoch');
    // Полный снимок: курсор 0 → обычный pull вычитает всё.
    await syncNow();
  }

  /// Применение одного удалённого документа с автослиянием (§10).
  Future<void> _applyRemoteEntity(AppDatabase db, String entityId,
      Map<String, Object?> docFields) async {
    final typeIndex = docFields['type'] as int? ?? -1;
    if (typeIndex < 0 || typeIndex >= SyncEntityType.values.length) return;
    final type = SyncEntityType.values[typeIndex];
    final remoteRevision = docFields['revision'] as int? ?? 1;
    final remoteDeleted = docFields['deleted'] as bool? ?? false;
    final remoteModifiedAt = parseDate(docFields['modified_at']);
    final remotePayload =
        docFields['deleted'] == true ? null : decodePayload(docFields['payload'] as String? ?? '{}');
    if (!remoteDeleted && remotePayload == null) return;
    if (remotePayload != null) {
      // Прикладываем ревизию базы с удалённой стороны.
      remotePayload['base_revision'] = remoteRevision;
    }

    final local = await readEntityPayload(db, type, entityId);

    // 1) Локальной записи нет: удалённый маркер → ничего; апсерт → вставить.
    if (local == null) {
      if (remoteDeleted) {
        // Компактный маркер без контента (§10) — локально удалять нечего.
        return;
      }
      await applyPayload(db, type, entityId, remotePayload!);
      await _storeBase(db, type, entityId, remotePayload, remoteRevision);
      return;
    }

    final localDeleted = local['deleted_at'] != null;
    final localModifiedAt = parseDate(local['modified_at'] as String?);
    final localRevision = local['revision'] as int? ?? 1;

    // 2) Удаление против редактирования — по поздней дате действия (§10).
    if (remoteDeleted || localDeleted) {
      final remoteWins = deletionWins(
        localModifiedAt: localModifiedAt,
        remoteModifiedAt: remoteModifiedAt,
        localDeleted: localDeleted,
        remoteDeleted: remoteDeleted,
      );
      if (remoteDeleted && remoteWins) {
        await _applyLocalDeletion(db, type, entityId,
            modifiedAt: remoteModifiedAt);
      } else if (!remoteDeleted && remoteWins && localDeleted) {
        // Позднее редактирование восстанавливает запись.
        await applyPayload(db, type, entityId, remotePayload!);
        await _storeBase(db, type, entityId, remotePayload, remoteRevision);
      }
      // Иначе побеждает локальная сторона; если локально удалено и это
      // позднее — локальная корзина остаётся, удаление уйдёт через outbox.
      return;
    }

    // 3) Обе активны. Локально не менялась с базы → просто принимаем.
    final baseRow = await (db.select(db.syncBase)
          ..where((b) =>
              b.entityId.equals(entityId) &
              b.entityType.equalsNullable(type.index)))
        .getSingleOrNull();
    // Локально менялась с подтверждённой базы ⇔ revision != base_revision
    // (база фиксируется при пуше и при применении удалённых изменений).
    final localChangedSinceBase =
        localRevision != (local['base_revision'] as int? ?? 0);

    if (!localChangedSinceBase) {
      await applyPayload(db, type, entityId, remotePayload!);
      await _storeBase(db, type, entityId, remotePayload, remoteRevision);
      return;
    }

    // 4) Изменились обе стороны: трёхстороннее слияние от базы (§10).
    final base = baseRow != null
        ? decodePayload(baseRow.payload)
        : <String, Object?>{};
    final merged =
        mergePayloads(base: base, local: local, remote: remotePayload!);
    if (!merged.hasConflicts) {
      final mergedPayload = {
        ...merged.merged,
        'revision': localRevision + 1,
      };
      await applyPayload(db, type, entityId, mergedPayload);
      await _storeBase(db, type, entityId, mergedPayload, remoteRevision);
      // Объединённый результат уходит в облако (§10: обе версии/результат
      // синхронизируются).
      await _ref
          .watch(outboxLedgerProvider)
          .recordUpsert(type, entityId, mergedPayload);
      return;
    }

    // 5) Несовместимые изменения → конфликт: обе версии сохраняются (§10),
    // локальная остаётся активной, удалённая ждёт решения в «Конфліктах».
    final existing = await (db.select(db.conflicts)
          ..where((c) =>
              c.entityId.equals(entityId) &
              c.entityType.equalsNullable(type.index) &
              c.kind.equals('merge')))
        .getSingleOrNull();
    if (existing == null) {
      await db.into(db.conflicts).insert(ConflictsCompanion.insert(
        id: 'merge:$type:$entityId',
        entityType: type,
        entityId: entityId,
        kind: 'merge',
        basePayload: Value(encodePayload(base)),
        localPayload: encodePayload(local),
        remotePayload: encodePayload(remotePayload),
        createdAt: DateTime.now().toUtc(),
      ));
    }
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
                  e.entityKind.equalsNullable(rowKind)))
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

  /// Решение конфликта с проверкой ревизии: применить выбранную версию,
  /// записать в outbox, снять конфликт (удаление разрешённого конфликта
  /// не создаёт историю).
  Future<void> resolveConflict(
    Conflict conflict,
    bool chooseLocal,
  ) async {
    final db = _ref.watch(appDatabaseProvider);
    final chosenPayload = decodePayload(
        chooseLocal ? conflict.localPayload : conflict.remotePayload);
    if (!chooseLocal) {
      await db.transaction(() async {
        await applyPayload(db, conflict.entityType, conflict.entityId,
            chosenPayload);
        await _storeBase(db, conflict.entityType, conflict.entityId,
            chosenPayload, chosenPayload['revision'] as int? ?? 1);
      });
    }
    await _ref
        .watch(outboxLedgerProvider)
        .recordUpsert(conflict.entityType, conflict.entityId, chosenPayload);
    await (db.delete(db.conflicts)
          ..where((c) => c.id.equals(conflict.id)))
        .go();
  }

  void dispose() {
    stop();
    _statusController.close();
  }
}

final firebaseRestClientProvider = Provider<FirebaseRestClient>((ref) {
  final auth = ref.watch(authServiceProvider);
  final client = FirebaseRestClient(
      idTokenProvider: () =>
          auth.state is AuthSignedIn
              ? (auth.state as AuthSignedIn).session.idToken
              : null);
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
