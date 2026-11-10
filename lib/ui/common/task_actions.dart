/// Общие действия над задачей: выполнение с подтверждением ветки (§6),
/// удаление в корзину (§11).
library;

import 'package:flutter/material.dart';

import '../../data/tasks_service.dart';
import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';

/// Переключение выполнения с правилом §6: родитель с незавершёнными
/// потомками требует подтверждения.
Future<void> toggleTaskCompletion(
  BuildContext context,
  TasksService tasks,
  Task task,
) async {
  final nowDone = task.completedAt == null;
  final needsBranchConfirm = nowDone &&
      await tasks.hasIncompleteDescendants(task.id);
  if (needsBranchConfirm) {
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.completeBranchTitle),
        content: Text(l10n.completeBranchQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await tasks.setCompleted(task.id, true);
    await _completeSubtree(tasks, task.id);
    return;
  }
  await tasks.setCompleted(task.id, nowDone);
}

Future<void> _completeSubtree(TasksService tasks, String rootId) async {
  final children = await tasks.children(rootId);
  for (final child in children) {
    if (child.completedAt == null) {
      await tasks.setCompleted(child.id, true);
    }
    await _completeSubtree(tasks, child.id);
  }
}

/// Удаление в корзину целиком (§11) с подтверждением.
Future<void> deleteTaskToTrash(
  BuildContext context,
  TasksService tasks,
  Task task,
) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(l10n.deleteTaskConfirm),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await tasks.moveBranchToTrash(task.id);
  }
}
