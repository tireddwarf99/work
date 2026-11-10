/// Карточка встроенного списка задач из макетов: заголовок, активные задачи
/// с подзадачами, сворачиваемая область «Виконані» (§4).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tasks_service.dart';
import '../../db/app_database.dart';
import '../../domain/due_spec.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../common/dialogs.dart';
import '../common/task_actions.dart';
import '../common/task_dnd.dart';
import '../common/task_row.dart';
import '../common/task_sorting.dart';
import '../providers.dart';
import '../queries.dart';

/// Карточка одного списка задач.
class TaskListCard extends ConsumerStatefulWidget {
  final String listId;

  /// block_id embed'а — для временной подсветки при переходе (§4).
  final String? blockId;
  final void Function(Task task) onOpenTask;

  /// Заголовок внутри карточки; экран списка показывает его в AppBar.
  final bool showTitle;

  const TaskListCard({
    super.key,
    required this.listId,
    this.blockId,
    required this.onOpenTask,
    this.showTitle = true,
  });

  @override
  ConsumerState<TaskListCard> createState() => _TaskListCardState();
}

class _TaskListCardState extends ConsumerState<TaskListCard> {
  Timer? _highlightTimer;

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  /// Подсветка снимается через 2 с после включения.
  void _onHighlightChanged(String? previous, String? next) {
    if (next == null || next != widget.blockId) return;
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (ref.read(embedHighlightProvider) == widget.blockId) {
        ref.read(embedHighlightProvider.notifier).state = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tasks = ref.watch(tasksServiceProvider);
    ref.listen<String?>(embedHighlightProvider, _onHighlightChanged);
    final highlighted =
        widget.blockId != null &&
        ref.watch(embedHighlightProvider) == widget.blockId;
    final listAsync = ref.watch(taskListProvider(widget.listId));

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
      child: listAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l10n.actionFailed),
        ),
        data: (list) {
          if (list == null) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.showTitle)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Text(
                    list.isSystem ? l10n.inbox : (list.title ?? l10n.untitled),
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              _ActiveTasks(
                listId: widget.listId,
                sortMode: list.sortMode,
                onOpenTask: widget.onOpenTask,
              ),
              _CompletedSection(
                listId: widget.listId,
                tasksService: tasks,
                onOpenTask: widget.onOpenTask,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.addTask),
                  onPressed: () =>
                      showQuickAddTask(context, ref, widget.listId),
                ),
              ),
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
  final SortMode sortMode;
  final void Function(Task task) onOpenTask;

  const _ActiveTasks({
    required this.listId,
    required this.sortMode,
    required this.onOpenTask,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksServiceProvider);
    return StreamBuilder<List<Task>>(
      stream: tasks.watchActiveInList(listId),
      builder: (context, snapshot) {
        final all = sortTasks(sortMode, snapshot.data ?? const <Task>[]);
        // Выполненные корни показывает область «Виконані».
        final roots = all
            .where((t) => t.parentId == null && t.completedAt == null)
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final root in roots)
              _TaskBranch(
                task: root,
                all: all,
                reorderEnabled: sortMode == SortMode.manual,
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
  final bool reorderEnabled;
  final void Function(Task task) onOpenTask;

  const _TaskBranch({
    required this.task,
    required this.all,
    required this.reorderEnabled,
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
          reorderEnabled: reorderEnabled,
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
              reorderEnabled: reorderEnabled,
              onOpenTask: onOpenTask,
            ),
          ),
      ],
    );
  }
}

/// Сворачиваемая область выполненных корневых задач («Виконані», §4).
class _CompletedSection extends StatefulWidget {
  final String listId;
  final TasksService tasksService;
  final void Function(Task task) onOpenTask;

  const _CompletedSection({
    required this.listId,
    required this.tasksService,
    required this.onOpenTask,
  });

  @override
  State<_CompletedSection> createState() => _CompletedSectionState();
}

class _CompletedSectionState extends State<_CompletedSection> {
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
  final tasks = ref.read(tasksServiceProvider);
  final text = await showTextInputDialog(
    context,
    hint: AppLocalizations.of(context)!.taskTextHint,
  );
  if (text == null) return;
  await tasks.create(listId, text: text);
}
