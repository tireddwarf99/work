/// Трёхстороннее слияние и правило «удаление против редактирования» (§10).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/sync/sync_merge.dart';

void main() {
  group('mergePayloads', () {
    test('независимые поля объединяются', () {
      final result = mergePayloads(
        base: {'title': 'A', 'delta': 'x', 'pinned': false},
        local: {'title': 'B', 'delta': 'x', 'pinned': false},
        remote: {'title': 'A', 'delta': 'y', 'pinned': false},
      );
      expect(result.hasConflicts, isFalse);
      expect(result.merged['title'], 'B');
      expect(result.merged['delta'], 'y');
    });

    test('одинаковые изменения обеих сторон считаются одним', () {
      final result = mergePayloads(
        base: {'title': 'A'},
        local: {'title': 'B'},
        remote: {'title': 'B'},
      );
      expect(result.hasConflicts, isFalse);
      expect(result.merged['title'], 'B');
    });

    test('пересечение одного поля даёт конфликт, остальные сливаются', () {
      final result = mergePayloads(
        base: {'title': 'A', 'delta': 'x'},
        // Локально изменили title и delta; удалённо только title.
        local: {'title': 'B', 'delta': 'local-edit'},
        remote: {'title': 'C', 'delta': 'x'},
      );
      expect(result.hasConflicts, isTrue);
      expect(result.conflicts, ['title']);
      // Консервативно: конфликтное поле — локальное значение.
      expect(result.merged['title'], 'B');
      // delta меняла только локальная сторона — остаётся.
      expect(result.merged['delta'], 'local-edit');
    });

    test('удалённое поле у одной стороны применяется', () {
      final result = mergePayloads(
        base: {'title': 'A', 'folder_id': 'f1'},
        local: {'title': 'A'},
        remote: {'title': 'B', 'folder_id': 'f1'},
      );
      expect(result.merged['folder_id'], isNull);
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
