/// Раздел «Конфлікти» (§10): сравнить версии, выбрать одну. Обе версии
/// синхронизируются; решение применяется с проверкой ревизии, разрешённый
/// конфликт снимается без истории.
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_database.dart';
import '../domain/due_spec.dart';
import '../l10n/app_localizations.dart';
import '../sync/sync_engine.dart';
import 'app_theme.dart';
import 'common/dialogs.dart';
import 'providers.dart';

class ConflictsScreen extends ConsumerWidget {
  const ConflictsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final db = ref.watch(appDatabaseProvider);
    final engine = ref.watch(syncEngineProvider);

    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: Text(l10n.conflicts)),
      body: StreamBuilder<List<Conflict>>(
        stream: (db.select(
          db.conflicts,
        )..orderBy([(c) => OrderingTerm.desc(c.createdAt)])).watch(),
        builder: (context, snapshot) {
          final conflicts = snapshot.data ?? const <Conflict>[];
          if (conflicts.isEmpty) {
            return Center(
              child: Text(l10n.conflictsNone, style: mutedStyle(context)),
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

class _ConflictCard extends StatelessWidget {
  final Conflict conflict;
  final SyncEngine engine;

  const _ConflictCard({required this.conflict, required this.engine});

  Future<void> _resolve(BuildContext context, bool keepLocal) async {
    try {
      await engine.resolveConflict(conflict, keepLocal);
    } catch (e, st) {
      debugPrint('conflict resolve failed: $e\n$st');
      if (context.mounted) showActionError(context);
    }
  }

  String _entityLabel(AppLocalizations l10n) {
    final type = switch (conflict.entityType) {
      SyncEntityType.note => l10n.note,
      SyncEntityType.task => l10n.task,
      SyncEntityType.folder => l10n.folder,
      SyncEntityType.taskList => l10n.allLists,
      final other => other.name,
    };
    return l10n.conflictEntity(type, conflict.entityId);
  }

  @override
  Widget build(BuildContext context) {
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
              _entityLabel(l10n),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall
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
                    onPressed: () => _resolve(context, true),
                    child: Text(l10n.conflictKeepLocal),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _resolve(context, false),
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

/// Сравнение версий: заголовок/текст и описание сущности.
class _VersionView extends StatelessWidget {
  final String label;
  final String payload;

  const _VersionView({required this.label, required this.payload});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = conflictSummary(payload);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(summary.title ?? l10n.untitled, maxLines: 2),
          if (summary.details != null)
            Text(
              summary.details!,
              style: mutedStyle(context),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

/// Краткое содержимое версии: главное поле и пояснение.
typedef ConflictSummary = ({String? title, String? details});

/// Читает из JSON-payload заголовок (`title`/`name`/`text`) и пояснение
/// (`description` либо первая строка `search_text`). Нечитаемый payload
/// даёт пустую сводку.
ConflictSummary conflictSummary(String payloadJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payloadJson);
  } on FormatException {
    return (title: null, details: null);
  }
  if (decoded is! Map<String, dynamic>) return (title: null, details: null);

  String? firstText(List<String> keys, {bool firstLine = false}) {
    for (final key in keys) {
      final value = decoded[key];
      if (value is! String) continue;
      final text = firstLine ? value.trim().split('\n').first : value.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  return (
    title: firstText(['title', 'name', 'text']),
    details: firstText(['description', 'search_text'], firstLine: true),
  );
}
