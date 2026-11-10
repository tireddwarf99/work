/// Строка задачи из макетов: чекбокс, текст, синяя строка срока,
/// красный флажок высокого приоритета.
library;

import 'package:flutter/material.dart';

import '../../db/app_database.dart';
import '../../domain/due_spec.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import 'due_label.dart';

class TaskRow extends StatelessWidget {
  final Task task;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final String? subtitleOverride;

  const TaskRow({
    super.key,
    required this.task,
    required this.onToggle,
    required this.onOpen,
    this.subtitleOverride,
  });

  DueSpec get _due => dueSpecFromRow(task);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final dueText = subtitleOverride ?? formatDue(_due, l10n);
    final done = task.completedAt != null;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: Checkbox(value: done, onChanged: (_) => onToggle()),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.content,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      decoration: done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (dueText != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      dueText,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: dueAccent(context)),
                    ),
                  ],
                ],
              ),
            ),
            if (task.priority == Priority.high)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.flag, size: 18, color: AppColors.danger),
              ),
          ],
        ),
      ),
    );
  }
}

/// Чтение DueSpec из строки БД.
DueSpec dueSpecFromRow(Task task) {
  final DueKind kind = task.dueKind;
  return switch (kind) {
    DueKind.none => const DueSpec.none(),
    DueKind.date => DueSpec.dateOnly(task.dueDate!),
    DueKind.dateTime => DueSpec.at(task.dueDate!, task.dueMinutes!),
  };
}
