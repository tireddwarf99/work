/// Экран «Діагностика»: состояние сессии и
/// синхронизации, журнал событий, ручные действия.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_service.dart';
import '../diagnostics/diag_log.dart';
import '../l10n/app_localizations.dart';
import '../sync/sync_engine.dart';
import 'app_theme.dart';
import 'providers.dart';

class DebugScreen extends ConsumerWidget {
  const DebugScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final authState = ref.watch(authStateProvider).value ?? const AuthSignedOut();
    final sync = ref.watch(syncStatusProvider).value ?? const SyncStatus();
    final db = ref.watch(appDatabaseProvider);
    final engine = ref.watch(syncEngineProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l10n.debugTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: l10n.debugCopyLog,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: DiagLog.instance.asText));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.debugCopied)),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusTable(authState: authState, sync: sync),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.sync, size: 18),
                label: Text(l10n.syncNow),
                onPressed: sync.running ? null : () => engine.syncNow(),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.merge, size: 18),
                label: Text(l10n.debugInitialMerge),
                onPressed: sync.running ? null : () => engine.initialMerge(),
              ),
              if (sync.epochSwitchRequired)
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: Text(l10n.debugAcceptSnapshot),
                  style: FilledButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () async {
                    final l10n = AppLocalizations.of(context)!;
                    final pending = sync.pendingOps;
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        content: Text(
                            '${l10n.debugAcceptSnapshotWarning}\n\n'
                            '${l10n.notSynced}: $pending'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(l10n.cancel),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(l10n.debugAcceptSnapshot),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await engine.acceptEpochSnapshot();
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          StreamBuilder<int>(
            stream: db.select(db.outboxEntries).watch().map((r) => r.length),
            builder: (context, outbox) => StreamBuilder<int>(
              stream: db.select(db.conflicts).watch().map((r) => r.length),
              builder: (context, conflicts) => Text(
                l10n.debugCounters(outbox.data ?? 0, conflicts.data ?? 0),
                style: mutedStyle(context),
              ),
            ),
          ),
          const Divider(height: 24),
          Text(l10n.debugLogTitle, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          StreamBuilder<void>(
            stream: DiagLog.instance.changes,
            builder: (context, _) {
              final entries = DiagLog.instance.entries;
              if (entries.isEmpty) {
                return Text(l10n.debugLogEmpty, style: mutedStyle(context));
              }
              return Container(
                decoration: BoxDecoration(
                  border: Border.all(color: cardBorder(context)),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(8),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in entries.take(120))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            entry,
                            style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                height: 1.3),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatusTable extends StatelessWidget {
  final AuthState authState;
  final SyncStatus sync;

  const _StatusTable({required this.authState, required this.sync});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = switch (authState) {
      AuthSignedOut() => l10n.syncOff,
      AuthNeedsReauth() => l10n.reauthNeeded,
      AuthSignedIn(:final session) => '${l10n.signedInAs} · ${session.uid}',
    };
    String yesNo(bool v) => v ? l10n.yes : l10n.no;
    const mono = TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.4);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: cardBorder(context)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.debugSession(session), style: mono),
          const SizedBox(height: 4),
          Text(
            l10n.debugSync(
              sync.running ? l10n.syncing : l10n.debugIdle,
              sync.lastSyncAt?.toIso8601String() ?? '-',
              sync.pendingOps,
            ),
            style: mono,
          ),
          if (sync.error != null)
            Text(
              l10n.debugError(sync.error!, yesNo(sync.permissionDenied),
                  yesNo(sync.workspaceMismatch)),
              style: mono.copyWith(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
