/// Карточка встроенного списка задач из макетов: заголовок, активные задачи
/// с подзадачами, сворачиваемая область «Виконані» (§4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tasks_service.dart';
import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../common/task_actions.dart';
import '../common/task_dnd.dart';
import '../common/task_row.dart';
import '../providers.dart';

/// Карточка одного списка задач.
class TaskListCard extends ConsumerWidget {
  final String listId;

  /// block_id embed'а — для временной подсветки при переходе (§4).
  final String? blockId;
  final void Function(Task task) onOpenTask;

  const TaskListCard({
    super.key,
    required this.listId,
    this.blockId,
    required this.onOpenTask,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final lists = ref.watch(listsServiceProvider);
    final tasks = ref.watch(tasksServiceProvider);

    final listFuture = lists.get(listId);
    final highlighted = blockId != null &&
        ref.watch(embedHighlightProvider) == blockId;
    if (highlighted) {
      Future.delayed(const Duration(seconds: 2), () {
        ref.read(embedHighlightProvider.notifier).state = null;
      });
    }
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: highlighted
              ? Theme.of(context).colorScheme.primary
              : cardBorder(context),
          width: highlighted ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<TaskList>(
        future: listFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          final list = snapshot.data!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(
                  list.title ?? l10n.untitled,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              _ActiveTasks(
                listId: listId,
                onOpenTask: onOpenTask,
              ),
              _CompletedSection(
                listId: listId,
                tasksService: tasks,
                onOpenTask: onOpenTask,
              ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

/// Активные корневые задачи с деревом подзадач.
class _ActiveTasks extends ConsumerWidget {
  final String listId;
  final void Function(Task task) onOpenTask;

  const _ActiveTasks({required this.listId, required this.onOpenTask});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksServiceProvider);
    return StreamBuilder<List<Task>>(
      stream: tasks.watchActiveInList(listId),
      builder: (context, snapshot) {
        final all = snapshot.data ?? const <Task>[];
        final roots = all.where((t) => t.parentId == null).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final root in roots)
              _TaskBranch(
                task: root,
                all: all,
                onOpenTask: onOpenTask,
              ),
          ],
        );
      },
    );
  }
}

/// Ветвь задачи: сама задача и её потомки с отступами.
class _TaskBranch extends ConsumerWidget {
  final Task task;
  final List<Task> all;
  final void Function(Task task) onOpenTask;

  const _TaskBranch({
    required this.task,
    required this.all,
    required this.onOpenTask,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksServiceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TaskDndRow(
          task: task,
          allTasks: all,
          onToggle: () => toggleTaskCompletion(context, tasks, task),
          onOpen: () => onOpenTask(task),
          child: TaskRow(
            task: task,
            onToggle: () => toggleTaskCompletion(context, tasks, task),
            onOpen: () => onOpenTask(task),
          ),
        ),
        for (final child in all.where((t) => t.parentId == task.id))
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: _TaskBranch(
              task: child,
              all: all,
              onOpenTask: onOpenTask,
            ),
          ),
      ],
    );
  }
}

/// Сворачиваемая область выполненных корневых задач («Виконані», §4).
class _CompletedSection extends ConsumerStatefulWidget {
  final String listId;
  final TasksService tasksService;
  final void Function(Task task) onOpenTask;

  const _CompletedSection({
    required this.listId,
    required this.tasksService,
    required this.onOpenTask,
  });

  @override
  ConsumerState<_CompletedSection> createState() => _CompletedSectionState();
}

class _CompletedSectionState extends ConsumerState<_CompletedSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return StreamBuilder<List<Task>>(
      stream: widget.tasksService.watchCompletedRoots(widget.listId),
      builder: (context, snapshot) {
        final completed = snapshot.data ?? const <Task>[];
        if (completed.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Divider(height: 1, color: cardBorder(context)),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: _expanded ? 0 : -0.25,
                      duration: const Duration(milliseconds: 150),
                      child: const Icon(Icons.expand_more, size: 20),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n.completedN(completed.length),
                      style: mutedStyle(context),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              for (final task in completed)
                TaskRow(
                  task: task,
                  onToggle: () =>
                      toggleTaskCompletion(context, widget.tasksService, task),
                  onOpen: () => widget.onOpenTask(task),
                ),
          ],
        );
      },
    );
  }
}

/// Быстрое добавление задачи в список.
Future<void> showQuickAddTask(
  BuildContext context,
  WidgetRef ref,
  String listId,
) async {
  final tasks = ref.watch(tasksServiceProvider);
  final controller = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: ' '),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(AppLocalizations.of(ctx)!.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(AppLocalizations.of(ctx)!.ok),
        ),
      ],
    ),
  );
  if (text != null && text.trim().isNotEmpty) {
    await tasks.create(listId, text: text.trim());
  }
}
