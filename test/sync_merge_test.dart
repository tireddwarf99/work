/// Трёхстороннее слияние и правило «удаление против редактирования» (§10).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/sync/sync_merge.dart';

/// Реалистичный payload заметки со служебными полями протокола.
Map<String, Object?> note({
  String title = 'A',
  String delta = 'x',
  bool pinned = false,
  int revision = 1,
  int baseRevision = 0,
  String modifiedAt = '2026-11-01T10:00:00.000Z',
  String deviceId = 'dev-local',
}) =>
    {
      'title': title,
      'delta': delta,
      'pinned': pinned,
      'revision': revision,
      'base_revision': baseRevision,
      'modified_at': modifiedAt,
      'device_id': deviceId,
      'deleted_at': null,
    };

void main() {
  group('mergePayloads', () {
    final base = note(revision: 1, baseRevision: 1);

    test('независимые поля объединяются, служебные не дают конфликтов', () {
      final result = mergePayloads(
        base: base,
        local: note(
            title: 'B',
            revision: 2,
            baseRevision: 1,
            modifiedAt: '2026-11-01T11:00:00.000Z'),
        remote: note(
            delta: 'y',
            revision: 2,
            baseRevision: 1,
            modifiedAt: '2026-11-01T12:00:00.000Z',
            deviceId: 'dev-remote'),
      );
      expect(result.hasConflicts, isFalse);
      expect(result.merged['title'], 'B');
      expect(result.merged['delta'], 'y');
    });

    test('служебные поля результата: ревизия выше обеих, база — удалённая', () {
      final result = mergePayloads(
        base: base,
        local: note(title: 'B', revision: 3, baseRevision: 1),
        remote: note(
            delta: 'y',
            revision: 5,
            baseRevision: 4,
            modifiedAt: '2026-11-01T12:00:00.000Z',
            deviceId: 'dev-remote'),
      );
      expect(result.merged['revision'], 6);
      expect(result.merged['base_revision'], 5);
      expect(result.merged['modified_at'], '2026-11-01T12:00:00.000Z');
      expect(result.merged['device_id'], 'dev-local');
    });

    test('одинаковые изменения обеих сторон считаются одним', () {
      final result = mergePayloads(
        base: base,
        local: note(title: 'B', revision: 2, baseRevision: 1),
        remote: note(
            title: 'B', revision: 2, baseRevision: 1, deviceId: 'dev-remote'),
      );
      expect(result.hasConflicts, isFalse);
      expect(result.merged['title'], 'B');
    });

    test('пересечение одного поля даёт конфликт, остальные сливаются', () {
      final result = mergePayloads(
        base: base,
        // Локально изменили title и delta; удалённо только title.
        local: note(title: 'B', delta: 'local-edit', revision: 2, baseRevision: 1),
        remote: note(title: 'C', revision: 2, baseRevision: 1),
      );
      expect(result.hasConflicts, isTrue);
      expect(result.conflicts, ['title']);
      // Консервативно: конфликтное поле — локальное значение.
      expect(result.merged['title'], 'B');
      // delta меняла только локальная сторона — остаётся.
      expect(result.merged['delta'], 'local-edit');
    });

    test('удалённое поле у одной стороны применяется', () {
      final local = note(revision: 2, baseRevision: 1)..remove('pinned');
      final result = mergePayloads(
        base: base,
        local: local,
        remote: note(title: 'B', revision: 2, baseRevision: 1),
      );
      expect(result.merged['pinned'], isNull);
      expect(result.merged['title'], 'B');
    });
  });

  group('deletionWins (§10: позднее действие побеждает)', () {
    final t1 = DateTime.utc(2026, 11, 1, 10, 0);
    final t2 = DateTime.utc(2026, 11, 1, 11, 0);

    test('позднее редактирование восстанавливает запись', () {
      expect(
        deletionWins(
          localModifiedAt: t2,
          remoteModifiedAt: t1,
          localDeleted: false,
          remoteDeleted: true,
        ),
        isFalse,
        reason: 'локальное редактирование позже удаления',
      );
    });

    test('позднее удаление оставляет в корзине', () {
      expect(
        deletionWins(
          localModifiedAt: t1,
          remoteModifiedAt: t2,
          localDeleted: false,
          remoteDeleted: true,
        ),
        isTrue,
      );
    });

    test('равное время — удаление выигрывает (§10)', () {
      expect(
        deletionWins(
          localModifiedAt: t1,
          remoteModifiedAt: t1,
          localDeleted: false,
          remoteDeleted: true,
        ),
        isTrue,
      );
      expect(
        deletionWins(
          localModifiedAt: t1,
          remoteModifiedAt: t1,
          localDeleted: true,
          remoteDeleted: false,
        ),
        isTrue,
      );
    });

    test('оба удалены — не важно, восстановление не требуется', () {
      expect(
        deletionWins(
          localModifiedAt: t1,
          remoteModifiedAt: t2,
          localDeleted: true,
          remoteDeleted: true,
        ),
        isTrue,
      );
    });
  });
}
