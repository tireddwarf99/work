/// Drag-and-drop задач (§4): вложенность (бросок на нижнюю половину
/// строки), порядок (верхняя половина), перенос между списками с веткой.
/// Циклический перенос запрещён — проверка в сервисе.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tasks_service.dart';
import '../../db/app_database.dart';
import '../providers.dart';
import 'platform_drag.dart';

/// Перенос задачи при броске на другую задачу.
///
/// Верхняя половина строки — сосед перед целью, нижняя — вложить ребёнком.
/// Существующий ручной порядок соседи сохраняют.
Future<void> dropTaskOnTask(
  TasksService tasks,
  Task dragged,
  Task target,
  List<Task> allTasks, {
  required bool asChild,
}) async {
  if (dragged.id == target.id) return;
  final newParentId = asChild ? target.id : target.parentId;
  try {
    final alreadyPlaced = dragged.listId == target.listId &&
        dragged.parentId == newParentId;
    if (!alreadyPlaced) {
      await tasks.moveBranch(
        dragged.id,
        newListId: target.listId,
        newParentId: newParentId,
      );
    }
    final siblings = allTasks
        .where((t) => t.parentId == newParentId && t.id != dragged.id)
        .toList()
      ..sort((a, b) => a.manualOrder.compareTo(b.manualOrder));
    if (asChild) {
      final children = allTasks
          .where((t) => t.parentId == target.id && t.id != dragged.id)
          .toList()
        ..sort((a, b) => a.manualOrder.compareTo(b.manualOrder));
      await tasks.reorder(
          dragged.id, afterId: children.isEmpty ? null : children.last.id);
      return;
    }
    final targetIndex = siblings.indexWhere((t) => t.id == target.id);
    final prevId = targetIndex > 0 ? siblings[targetIndex - 1].id : null;
    await tasks.reorder(dragged.id, afterId: prevId);
  } on StateError {
    // Циклический перенос запрещён (§4).
  } on ArgumentError {
    // Несовместимый перенос (родитель в другом списке) — запрещён (§3).
  }
}

/// Строка задачи с drag-and-drop: перетаскивается и принимает перетаскивание.
class TaskDndRow extends ConsumerWidget {
  final Task task;
  final List<Task> allTasks;
  final Widget child;
  final VoidCallback onToggle;
  final VoidCallback onOpen;

  const TaskDndRow({
    super.key,
    required this.task,
    required this.allTasks,
    required this.child,
    required this.onToggle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksServiceProvider);
    return PlatformDraggable<Task>(
      data: task,
      feedback: dragFeedbackCard(
        context,
        ListTile(
          dense: true,
          title: Text(task.content),
          leading: const Icon(Icons.check_box_outline_blank, size: 20),
        ),
      ),
      child: DragTarget<Task>(
        builder: (context, candidates, rejected) {
          return Stack(
            children: [
              child,
              // Две зоны приёма: верхняя — «перед», нижняя — «внутрь».
              Positioned.fill(
                child: Column(
                  children: [
                    Expanded(
                      child: DragTarget<Task>(
                        builder: (context, candidates, _) => _ZoneLine(
                          visible: candidates.isNotEmpty,
                          context: context,
                          atTop: true,
                        ),
                        onWillAcceptWithDetails: (d) =>
                            d.data.id != task.id,
                        onAcceptWithDetails: (d) => dropTaskOnTask(
                            tasks, d.data, task, allTasks,
                            asChild: false),
                      ),
                    ),
                    Expanded(
                      child: DragTarget<Task>(
                        builder: (context, candidates, _) => _ZoneLine(
                          visible: candidates.isNotEmpty,
                          context: context,
                          atTop: false,
                        ),
                        onWillAcceptWithDetails: (d) =>
                            d.data.id != task.id,
                        onAcceptWithDetails: (d) => dropTaskOnTask(
                            tasks, d.data, task, allTasks,
                            asChild: true),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ZoneLine extends StatelessWidget {
  final bool visible;
  final BuildContext context;
  final bool atTop;

  const _ZoneLine({
    required this.visible,
    required this.context,
    required this.atTop,
  });

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.expand();
    return Padding(
      padding: EdgeInsets.only(top: atTop ? 0 : 0, bottom: 0),
      child: Align(
        alignment: atTop ? Alignment.topCenter : Alignment.bottomCenter,
        child: Container(
          height: 3,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// Подсветка цели при перетаскивании.
Color dropHighlight(BuildContext context, bool hovered) => hovered
    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
    : Colors.transparent;
