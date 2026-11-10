/// Общие действия над задачей: выполнение с подтверждением ветки (§6),
/// удаление в корзину (§11).
library;

import 'package:flutter/material.dart';

import '../../data/tasks_service.dart';
import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import 'dialogs.dart';

/// Переключение выполнения с правилом §6: родитель с незавершёнными
/// потомками требует подтверждения.
Future<void> toggleTaskCompletion(
  BuildContext context,
  TasksService tasks,
  Task task,
) async {
  final nowDone = task.completedAt == null;
  final needsBranchConfirm =
      nowDone && await tasks.hasIncompleteDescendants(task.id);
  if (needsBranchConfirm) {
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.completeBranchTitle,
      message: l10n.completeBranchQuestion,
      confirmLabel: l10n.ok,
    );
    if (!confirmed) return;
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

/// Удаление в корзину целиком (§11) с подтверждением; true — удалено.
Future<bool> deleteTaskToTrash(
  BuildContext context,
  TasksService tasks,
  Task task,
) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showConfirmDialog(
    context,
    message: l10n.deleteTaskConfirm,
    confirmLabel: l10n.delete,
  );
  if (!confirmed) return false;
  await tasks.moveBranchToTrash(task.id);
  return true;
}
