/// Логика движка синхронизации без сети: push/pull через in-memory Firestore
/// (постраничный pull, уникальный commit_seq, маска workspace, epoch,
/// rollback/повторы), решение по исходящей операции, слияние и конфликты.
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/cloud/firebase_rest.dart';
import 'package:notes_app/data/outbox_ledger.dart';
import 'package:notes_app/db/app_database.dart';
import 'package:notes_app/domain/due_spec.dart';
import 'package:notes_app/sync/sync_engine.dart';
import 'package:notes_app/sync/sync_mapper.dart';
import 'package:notes_app/ui/providers.dart'
    show appDatabaseProvider;

const _uid = 'uid-1';
const _docRoot = 'projects/dwarfs-life-app/databases/(default)/documents/';

/// Минимальная in-memory реализация Firestore REST, достаточная движку.
class FakeFirestore extends FirebaseRestClient {
  final Map<String, Map<String, Object?>> docs = {};
  final List<String> rollbacks = [];
  final List<List<Map<String, dynamic>>> commits = [];
  FirebaseApiException? failNextCommit;
  int _clock = 0;
  int _txn = 0;

  void seed(String path, Map<String, Object?> fields) {
    docs[path] = {...fields};
    _touch(path);
  }

  final Map<String, String> _updateTimes = {};

  void _touch(String path) => _updateTimes[path] = '${++_clock}';

  Map<String, dynamic> _wrap(String path) => {
        'name': '$_docRoot$path',
        'updateTime': _updateTimes[path],
        ...FirebaseRestClient.encodeFields(docs[path]!),
      };

  @override
  Future<Map<String, dynamic>?> getDocument(String path,
          {String? transaction}) async =>
      docs.containsKey(path) ? _wrap(path) : null;

  @override
  Future<String> beginTransaction() async => 'txn-${++_txn}';

  @override
  Future<void> rollback(String transaction) async =>
      rollbacks.add(transaction);

  @override
  Future<List<Map<String, dynamic>?>> batchGet(List<String> documentPaths,
          {String? transaction}) async =>
      [for (final p in documentPaths) docs.containsKey(p) ? _wrap(p) : null];

  @override
  Future<CommitResult> commit(
      {required List<Map<String, dynamic>> writes, String? transaction}) async {
    final failure = failNextCommit;
    if (failure != null) {
      failNextCommit = null;
      throw failure;
    }
    commits.add(writes);
    // Проверка precondition до применения (атомарность).
    for (final w in writes) {
      final path = (w['update']['name'] as String).substring(_docRoot.length);
      final pre = w['currentDocument'] as Map<String, dynamic>?;
      if (pre == null) continue;
      if (pre['exists'] == false && docs.containsKey(path)) {
        throw FirebaseApiException('exists', statusCode: 409, aborted: true);
      }
      final time = pre['updateTime'];
      if (time != null && _updateTimes[path] != time) {
        throw FirebaseApiException('stale', statusCode: 409, aborted: true);
      }
    }
    for (final w in writes) {
      final update = w['update'] as Map<String, dynamic>;
      final path = (update['name'] as String).substring(_docRoot.length);
      final fields = FirebaseRestClient.decodeFields(update);
      final mask = (w['updateMask']?['fieldPaths'] as List?)?.cast<String>();
      if (mask == null) {
        docs[path] = fields;
      } else {
        docs[path] = {
          ...?docs[path],
          for (final k in mask) k: fields[k],
        };
      }
      _touch(path);
    }
    return CommitResult(updateTimes: const []);
  }

  @override
  Future<List<Map<String, dynamic>>> runQuery({
    required String parentPath,
    required Map<String, dynamic> structuredQuery,
  }) async {
    final cursor = int.parse(structuredQuery['where']['fieldFilter']['value']
        ['integerValue'] as String);
    final limit = structuredQuery['limit'] as int;
    final matches = docs.entries
        .where((e) =>
            e.key.startsWith('$parentPath/') &&
            (e.value['commit_seq'] as int) > cursor)
        .toList()
      ..sort((a, b) => (a.value['commit_seq'] as int)
          .compareTo(b.value['commit_seq'] as int));
    return [for (final e in matches.take(limit)) _wrap(e.key)];
  }
}

Map<String, Object?> folderPayload(String id,
        {String name = 'F',
        int revision = 1,
        int base = 0,
        int order = 0,
        String modifiedAt = '2026-11-01T10:00:00.000Z'}) =>
    {
      'id': id,
      'name': name,
      'parent_id': null,
      'manual_order': order,
      'revision': revision,
      'base_revision': base,
      'modified_at': modifiedAt,
      'device_id': 'dev-remote',
      'deleted_at': null,
    };

Map<String, Object?> folderDoc(String id, int seq, Map<String, Object?> p,
        {bool deleted = false, String lastOp = 'op-remote'}) =>
    {
      'type': SyncEntityType.folder.index,
      'revision': p['revision'],
      'base_revision': p['base_revision'],
      'commit_seq': seq,
      'modified_at': p['modified_at'],
      'deleted': deleted,
      'device_id': 'dev-remote',
      'payload': deleted ? '' : jsonEncode(p),
      'last_op_id': lastOp,
    };

String _entityPath(String id, [int epoch = 1]) =>
    'workspaces/$_uid/epochs/$epoch/entities/$id';

class Device {
  final AppDatabase db;
  final ProviderContainer container;
  final SyncEngine engine;

  Device._(this.db, this.container, this.engine);

  factory Device(FakeFirestore cloud) {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      firebaseRestClientProvider.overrideWithValue(cloud),
    ]);
    final engine = container.read(syncEngineProvider)
      ..retryDelay = (_) => Duration.zero;
    return Device._(db, container, engine);
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }

  Future<int> count(String table) async => (await db
          .customSelect('SELECT COUNT(*) AS c FROM $table')
          .getSingle())
      .data['c'] as int;

  Future<int> cursor() async =>
      (await db.select(db.syncState).getSingle()).commitCursor;

  Future<Folder> folder(String id) =>
      (db.select(db.folders)..where((f) => f.id.equals(id))).getSingle();

  Future<List<OutboxEntry>> outbox() => db.select(db.outboxEntries).get();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeFirestore cloud;
  late Device a;

  setUp(() {
    cloud = FakeFirestore()
      ..seed('workspaces/$_uid', {'active_epoch': 1, 'commit_seq': 0});
    a = Device(cloud);
  });

  tearDown(() => a.dispose());

  group('pull', () {
    test('постранично забирает все документы (700 > лимита страницы)',
        () async {
      for (var i = 1; i <= 700; i++) {
        cloud.seed(_entityPath('f$i'),
            folderDoc('f$i', i, folderPayload('f$i', name: 'F$i')));
      }
      cloud.seed('workspaces/$_uid', {'active_epoch': 1, 'commit_seq': 700});

      expect(await a.engine.pullChanges(_uid), isTrue);

      expect(await a.count('folders'), 700);
      expect(await a.cursor(), 700);
      expect((await a.folder('f700')).name, 'F700');
    });

    test('другой epoch: данные не тронуты, выставлен epochSwitchRequired',
        () async {
      cloud.seed(_entityPath('f1', 2),
          folderDoc('f1', 1, folderPayload('f1')));
      cloud.seed('workspaces/$_uid', {'active_epoch': 2, 'commit_seq': 1});

      expect(await a.engine.pullChanges(_uid), isFalse);

      expect(a.engine.status.epochSwitchRequired, isTrue);
      expect(await a.count('folders'), 0);
    });

    test('курсор догоняет счётчик, если документов выше курсора нет', () async {
      cloud.seed('workspaces/$_uid', {'active_epoch': 1, 'commit_seq': 42});
      await a.engine.pullChanges(_uid);
      expect(await a.cursor(), 42);
    });
  });

  group('push', () {
    Future<void> enqueueFolders(Device d, int n) async {
      final ledger = OutboxLedger(d.db);
      for (var i = 1; i <= n; i++) {
        await d.db
            .into(d.db.folders)
            .insert(FoldersCompanion.insert(id: 'f$i', name: 'F$i'));
        // Формат снапшотов сервисов данных: camelCase и даты в миллисекундах.
        await ledger.recordUpsert(SyncEntityType.folder, 'f$i', {
          'id': 'f$i',
          'name': 'F$i',
          'manualOrder': 0,
          'revision': 1,
          'baseRevision': 0,
          'modifiedAt': DateTime.utc(2026, 11, 1).millisecondsSinceEpoch,
          'deviceId': 'dev-a',
        });
      }
    }

    test('каждый документ получает свой commit_seq; active_epoch цел; '
        'второе устройство получает всё', () async {
      await enqueueFolders(a, 650);

      await a.engine.pushOutbox(_uid, 1);

      final ws = cloud.docs['workspaces/$_uid']!;
      expect(ws['commit_seq'], 650);
      expect(ws['active_epoch'], 1);
      final seqs = [
        for (final e in cloud.docs.entries)
          if (e.key.contains('/entities/')) e.value['commit_seq'] as int,
      ]..sort();
      expect(seqs, List.generate(650, (i) => i + 1));
      expect(await a.outbox(), isEmpty);
      expect((await a.folder('f1')).baseRevision, 1);

      final b = Device(cloud);
      addTearDown(b.dispose);
      await b.engine.pullChanges(_uid);
      expect(await b.count('folders'), 650);
      final f = await b.folder('f650');
      expect(f.name, 'F650');
      expect(f.deviceId, 'dev-a');
      expect(f.modifiedAt.toUtc(), DateTime.utc(2026, 11, 1));
    });

    test('устройство старого epoch не пишет в облако и откатывает транзакцию',
        () async {
      await enqueueFolders(a, 2);
      cloud.seed('workspaces/$_uid', {'active_epoch': 2, 'commit_seq': 0});

      await expectLater(a.engine.pushOutbox(_uid, 1), throwsA(isA<Exception>()));

      expect(cloud.commits, isEmpty);
      expect(cloud.rollbacks, hasLength(1));
      expect((await a.outbox()), hasLength(2));
    });

    test('abort при commit: транзакция откатывается, повтор успешен', () async {
      await enqueueFolders(a, 1);
      cloud.failNextCommit =
          FirebaseApiException('aborted', statusCode: 409, aborted: true);

      await a.engine.pushOutbox(_uid, 1);

      expect(cloud.rollbacks, hasLength(1));
      expect(cloud.docs.containsKey(_entityPath('f1')), isTrue);
      expect(await a.outbox(), isEmpty);
    });

    test('постоянная ошибка не повторяется и не стирает outbox', () async {
      await enqueueFolders(a, 1);
      cloud.failNextCommit = FirebaseApiException('denied',
          statusCode: 403, permissionDenied: true);

      await expectLater(a.engine.pushOutbox(_uid, 1),
          throwsA(isA<FirebaseApiException>()));
      expect(await a.outbox(), hasLength(1));
      expect(cloud.rollbacks, hasLength(1));
    });

    test('повтор уже применённой операции подтверждает базу без записи',
        () async {
      await enqueueFolders(a, 1);
      final op = (await a.outbox()).single;
      cloud.seed(
          _entityPath('f1'),
          folderDoc('f1', 1, folderPayload('f1', name: 'F1'),
              lastOp: op.operationId));
      cloud.seed('workspaces/$_uid', {'active_epoch': 1, 'commit_seq': 1});

      await a.engine.pushOutbox(_uid, 1);

      expect(cloud.commits, isEmpty);
      expect(await a.outbox(), isEmpty);
      expect((await a.folder('f1')).baseRevision, 1);
    });
  });

  group('decideOp', () {
    OutboxEntry op(String kind, {int revision = 2, String id = 'op-1'}) =>
        OutboxEntry(
          operationId: id,
          entityType: SyncEntityType.folder,
          entityId: 'f1',
          changeKind: kind,
          payload: jsonEncode({'revision': revision}),
          createdAt: DateTime.utc(2026, 11, 1, 12),
          attempts: 0,
        );

    Map<String, dynamic> cloudDoc(
            {int revision = 1,
            bool deleted = false,
            String lastOp = 'other',
            String modifiedAt = '2026-11-01T10:00:00.000Z'}) =>
        FirebaseRestClient.encodeFields({
          'revision': revision,
          'deleted': deleted,
          'last_op_id': lastOp,
          'modified_at': modifiedAt,
        });

    test('нет документа или ревизия выше — писать', () {
      expect(SyncEngine.decideOp(op('upsert'), null), PushDecision.write);
      expect(SyncEngine.decideOp(op('upsert'), cloudDoc(revision: 1)),
          PushDecision.write);
    });

    test('равная ревизия другого устройства не перезаписывает', () {
      expect(SyncEngine.decideOp(op('upsert'), cloudDoc(revision: 2)),
          PushDecision.stale);
      expect(SyncEngine.decideOp(op('upsert'), cloudDoc(revision: 5)),
          PushDecision.stale);
    });

    test('тот же last_op_id — идемпотентный повтор', () {
      expect(
          SyncEngine.decideOp(
              op('upsert'), cloudDoc(revision: 2, lastOp: 'op-1')),
          PushDecision.alreadyApplied);
    });

    test('удаление против редактирования — по поздней дате', () {
      expect(
          SyncEngine.decideOp(op('delete'),
              cloudDoc(modifiedAt: '2026-11-01T11:00:00.000Z')),
          PushDecision.write);
      expect(
          SyncEngine.decideOp(op('delete'),
              cloudDoc(modifiedAt: '2026-11-01T13:00:00.000Z')),
          PushDecision.stale);
      expect(SyncEngine.decideOp(op('delete'), cloudDoc(deleted: true)),
          PushDecision.stale);
    });

    test('редактирование против удаления в облаке — только если позднее', () {
      expect(
          SyncEngine.decideOp(
              op('upsert'),
              cloudDoc(
                  deleted: true, modifiedAt: '2026-11-01T11:00:00.000Z')),
          PushDecision.write);
      expect(
          SyncEngine.decideOp(
              op('upsert'),
              cloudDoc(
                  deleted: true, modifiedAt: '2026-11-01T12:00:00.000Z')),
          PushDecision.stale);
    });
  });

  group('слияние при pull', () {
    Future<void> seedLocalFolder({
      required String name,
      int order = 0,
      int revision = 2,
      int base = 1,
      DateTime? modifiedAt,
    }) async {
      await a.db.into(a.db.folders).insert(FoldersCompanion.insert(
            id: 'f1',
            name: name,
            manualOrder: Value(order),
            revision: Value(revision),
            baseRevision: Value(base),
            modifiedAt:
                Value(modifiedAt ?? DateTime.utc(2026, 11, 1, 10)),
          ));
      await a.db.into(a.db.syncBase).insert(SyncBaseCompanion.insert(
            entityId: 'f1',
            entityType: SyncEntityType.folder,
            payload: jsonEncode(folderPayload('f1',
                name: 'Orig', revision: 1, base: 1)),
            baseRevision: 1,
          ));
    }

    test('независимые правки сливаются; результат уходит с ревизией выше '
        'обеих сторон', () async {
      await seedLocalFolder(name: 'Local', revision: 3, base: 1);
      final remote = folderPayload('f1',
          name: 'Orig', revision: 5, base: 4, order: 7);
      cloud.seed(_entityPath('f1'), folderDoc('f1', 1, remote));
      cloud.seed('workspaces/$_uid', {'active_epoch': 1, 'commit_seq': 1});

      await a.engine.pullChanges(_uid);

      final f = await a.folder('f1');
      expect(f.name, 'Local');
      expect(f.manualOrder, 7);
      expect(f.revision, 6);
      expect(f.baseRevision, 5);
      expect(await a.count('conflicts'), 0);
      final op = (await a.outbox()).single;
      expect(canonicalPayload(decodePayload(op.payload))['revision'], 6);
    });

    test('пересечение полей — конфликт; выбор «локальная» уходит в облако',
        () async {
      await seedLocalFolder(name: 'Local', revision: 2, base: 1);
      final remote = folderPayload('f1', name: 'Remote', revision: 4, base: 3);
      cloud.seed(_entityPath('f1'), folderDoc('f1', 1, remote));
      cloud.seed('workspaces/$_uid', {'active_epoch': 1, 'commit_seq': 1});

      await a.engine.pullChanges(_uid);

      final conflict = await a.db.select(a.db.conflicts).getSingle();
      expect((await a.folder('f1')).name, 'Local');

      await a.engine.resolveConflict(conflict, true);

      expect(await a.count('conflicts'), 0);
      final f = await a.folder('f1');
      expect(f.revision, 5, reason: 'выше облачной ревизии 4');
      final op = (await a.outbox()).single;
      expect(canonicalPayload(decodePayload(op.payload))['revision'], 5);

      await a.engine.pushOutbox(_uid, 1);
      expect(cloud.docs[_entityPath('f1')]!['revision'], 5,
          reason: 'выбор пользователя не отброшен как устаревший');
      expect(await a.outbox(), isEmpty);
    });

    test('выбор «удалённая» применяет облачную версию и снимает локальные '
        'операции', () async {
      await seedLocalFolder(name: 'Local', revision: 2, base: 1);
      await OutboxLedger(a.db).recordUpsert(SyncEntityType.folder, 'f1',
          {'name': 'Local', 'revision': 2});
      final remote = folderPayload('f1', name: 'Remote', revision: 4, base: 3);
      cloud.seed(_entityPath('f1'), folderDoc('f1', 1, remote));
      cloud.seed('workspaces/$_uid', {'active_epoch': 1, 'commit_seq': 1});
      await a.engine.pullChanges(_uid);

      await a.engine
          .resolveConflict(await a.db.select(a.db.conflicts).getSingle(), false);

      final f = await a.folder('f1');
      expect(f.name, 'Remote');
      expect(f.revision, 4);
      expect(f.baseRevision, 4);
      expect(await a.outbox(), isEmpty);
    });

    test('локальная правка новее облачного удаления возвращается в облако',
        () async {
      await seedLocalFolder(
          name: 'Local',
          revision: 2,
          base: 1,
          modifiedAt: DateTime.utc(2026, 11, 1, 12));
      cloud.seed(
          _entityPath('f1'),
          folderDoc(
              'f1',
              1,
              folderPayload('f1',
                  revision: 1, modifiedAt: '2026-11-01T11:00:00.000Z'),
              deleted: true));
      cloud.seed('workspaces/$_uid', {'active_epoch': 1, 'commit_seq': 1});

      await a.engine.pullChanges(_uid);

      final f = await a.folder('f1');
      expect(f.deletedAt, isNull);
      expect(f.revision, 3);
      final op = (await a.outbox()).single;
      expect(op.changeKind, 'upsert');
    });

    test('облачное удаление новее локальной правки — запись в корзине',
        () async {
      await seedLocalFolder(
          name: 'Local',
          revision: 2,
          base: 1,
          modifiedAt: DateTime.utc(2026, 11, 1, 10));
      cloud.seed(
          _entityPath('f1'),
          folderDoc(
              'f1',
              1,
              folderPayload('f1',
                  revision: 1, modifiedAt: '2026-11-01T11:00:00.000Z'),
              deleted: true));
      cloud.seed('workspaces/$_uid', {'active_epoch': 1, 'commit_seq': 1});

      await a.engine.pullChanges(_uid);

      expect((await a.folder('f1')).deletedAt, isNotNull);
      expect(await a.outbox(), isEmpty);
    });
  });
}
