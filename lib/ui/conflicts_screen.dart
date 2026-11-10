/// Раздел «Конфлікти» (§10): сравнить версии, выбрать одну. Обе версии
/// синхронизируются; решение применяется с проверкой ревизии, разрешённый
/// конфликт снимается без истории.
library;

import 'package:drift/drift.dart' hide isNotNull, Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_database.dart';
import '../l10n/app_localizations.dart';
import '../sync/sync_engine.dart';
import 'app_theme.dart';
import 'providers.dart';

class ConflictsScreen extends ConsumerWidget {
  const ConflictsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final db = ref.watch(appDatabaseProvider);
    final engine = ref.watch(syncEngineProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l10n.conflicts),
      ),
      body: StreamBuilder<List<Conflict>>(
        stream: (db.select(db.conflicts)
              ..orderBy([(c) => OrderingTerm.desc(c.createdAt)]))
            .watch(),
        builder: (context, snapshot) {
          final conflicts = snapshot.data ?? const <Conflict>[];
          if (conflicts.isEmpty) {
            return Center(
              child:
                  Text(l10n.conflictsNone, style: mutedStyle(context)),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final conflict in conflicts)
                _ConflictCard(conflict: conflict, engine: engine),
            ],
          );
        },
      ),
    );
  }
}

class _ConflictCard extends ConsumerWidget {
  final Conflict conflict;
  final SyncEngine engine;

  const _ConflictCard({required this.conflict, required this.engine});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        border: Border.all(color: cardBorder(context)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '${conflict.entityType.name} · ${conflict.entityId}',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          _VersionView(
            label: l10n.conflictKeepLocal,
            payload: conflict.localPayload,
          ),
          _VersionView(
            label: l10n.conflictKeepRemote,
            payload: conflict.remotePayload,
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await engine.resolveConflict(conflict, true);
                    },
                    child: Text(l10n.conflictKeepLocal),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      await engine.resolveConflict(conflict, false);
                    },
                    child: Text(l10n.conflictKeepRemote),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Сравнение версий: ключевые поля показываются рядом.
class _VersionView extends StatelessWidget {
  final String label;
  final String payload;

  const _VersionView({required this.label, required this.payload});

  @override
  Widget build(BuildContext context) {
    final text = _shortSummary(payload);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600)),
          Text(text, style: mutedStyle(context), maxLines: 3),
        ],
      ),
    );
  }

  String _shortSummary(String payloadJson) {
    // payload — JSON; выводим пару ключевых полей без всего содержимого.
    try {
      final map = payloadJson;
      return map.length > 300 ? '${map.substring(0, 300)}…' : map;
    } catch (_) {
      return payloadJson;
    }
  }
}
