/// Семантика SyncStatus: copyWith перезаписывает дословно — ошибки и флаги
/// обязаны сбрасываться явно (ревью P2).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/sync/sync_engine.dart';

void main() {
  test('успешная синхронизация сбрасывает ошибки и флаги', () {
    final failed = const SyncStatus(
      running: true,
      error: 'boom',
      permissionDenied: true,
      workspaceMismatch: true,
      epochSwitchRequired: true,
      pendingOps: 3,
    );
    final recovered = failed.copyWith(
      running: false,
      lastSyncAt: DateTime.utc(2026, 11, 1),
      error: null,
      permissionDenied: false,
      workspaceMismatch: false,
      epochSwitchRequired: false,
      pendingOps: 0,
    );
    expect(recovered.error, isNull);
    expect(recovered.permissionDenied, isFalse);
    expect(recovered.workspaceMismatch, isFalse);
    expect(recovered.epochSwitchRequired, isFalse);
    expect(recovered.lastSyncAt, isNotNull);
  });

  test('copyWith перезаписывает дословно: не передал поле — не изменилось', () {
    const base = SyncStatus(error: 'x', permissionDenied: true);
    final same = base.copyWith(running: true);
    // error и permissionDenied сохраняются, если не заданы явно.
    expect(same.error, 'x');
    expect(same.permissionDenied, isTrue);
    expect(same.running, isTrue);
  });

  test('константа по умолчанию чистая', () {
    const fresh = SyncStatus();
    expect(fresh.error, isNull);
    expect(fresh.permissionDenied, isFalse);
    expect(fresh.workspaceMismatch, isFalse);
    expect(fresh.epochSwitchRequired, isFalse);
    expect(fresh.pendingOps, 0);
  });
}
