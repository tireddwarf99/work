/// Текст состояния синхронизации по [SyncStatus] (§10): единый для настроек
/// и навигации Windows.
library;

import '../../l10n/app_localizations.dart';
import '../../sync/sync_engine.dart';

/// Состояние требует внимания пользователя.
bool syncNeedsAttention(SyncStatus s) =>
    s.workspaceMismatch ||
    s.permissionDenied ||
    s.epochSwitchRequired ||
    s.error != null;

/// Строка состояния; [withDetails] добавляет технический текст ошибки.
String syncStatusLabel(AppLocalizations l10n, SyncStatus s,
    {bool withDetails = false}) {
  if (s.workspaceMismatch) return l10n.workspaceMismatch;
  if (s.permissionDenied) return l10n.syncPermission;
  if (s.epochSwitchRequired) return l10n.epochSwitchPending;
  if (s.error != null) {
    return withDetails ? '${l10n.syncError}: ${s.error}' : l10n.syncError;
  }
  if (s.running) return l10n.syncing;
  if (s.pendingOps > 0) return l10n.pendingChangesN(s.pendingOps);
  if (s.lastSyncAt == null) return l10n.notSynced;
  return l10n.synced;
}
