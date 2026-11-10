/// Drag-and-drop задач (§4): вложенность (бросок на нижнюю половину
/// строки), порядок (верхняя половина), перенос между списками с веткой.
/// Циклический перенос запрещён — проверка в сервисе.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tasks_service.dart';
import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import '../providers.dart';
import 'platform_drag.dart';

/// Перенос задачи при броске на другую задачу.
///
/// Верхняя половина строки — сосед перед целью, нижняя — вложить ребёнком.
/// Существующий ручной порядок соседи сохраняют. Возвращает false, если
/// сервис запретил перенос (цикл §4, родитель из другого списка §3).
Future<bool> dropTaskOnTask(
  TasksService tasks,
  Task dragged,
  Task target,
  List<Task> allTasks, {
  required bool asChild,
}) async {
  if (dragged.id == target.id) return true;
  final newParentId = asChild ? target.id : target.parentId;
  try {
    final alreadyPlaced =
        dragged.listId == target.listId && dragged.parentId == newParentId;
    if (!alreadyPlaced) {
      await tasks.moveBranch(
        dragged.id,
        newListId: target.listId,
        newParentId: newParentId,
      );
    }
    final siblings =
        allTasks
            .where((t) => t.parentId == newParentId && t.id != dragged.id)
            .toList()
          ..sort((a, b) => a.manualOrder.compareTo(b.manualOrder));
    if (asChild) {
      await tasks.reorder(
        dragged.id,
        afterId: siblings.isEmpty ? null : siblings.last.id,
      );
      return true;
    }
    final targetIndex = siblings.indexWhere((t) => t.id == target.id);
    final prevId = targetIndex > 0 ? siblings[targetIndex - 1].id : null;
    await tasks.reorder(dragged.id, afterId: prevId);
    return true;
  } on StateError {
    return false;
  } on ArgumentError {
    return false;
  }
}

/// Строка задачи с drag-and-drop: перетаскивается и принимает перетаскивание.
/// При [reorderEnabled] == false (сортировка не ручная) верхняя зона
/// «перед» отключена — порядок определяет сортировка, а не пользователь.
class TaskDndRow extends ConsumerWidget {
  final Task task;
  final List<Task> allTasks;
  final Widget child;
  final bool reorderEnabled;

  const TaskDndRow({
    super.key,
    required this.task,
    required this.allTasks,
    required this.child,
    this.reorderEnabled = true,
  });

  Future<void> _drop(
    BuildContext context,
    WidgetRef ref,
    Task dragged, {
    required bool asChild,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = AppLocalizations.of(context)!.dropForbidden;
    final ok = await dropTaskOnTask(
      ref.read(tasksServiceProvider),
      dragged,
      task,
      allTasks,
      asChild: asChild,
    );
    if (!ok) messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      child: Stack(
        children: [
          child,
          // Две зоны приёма: верхняя — «перед», нижняя — «внутрь».
          Positioned.fill(
            child: Column(
              children: [
                Expanded(
                  child: reorderEnabled
                      ? _DropZone(
                          atTop: true,
                          onWillAccept: (d) => d.id != task.id,
                          onAccept: (d) =>
                              _drop(context, ref, d, asChild: false),
                        )
                      : const SizedBox.expand(),
                ),
                Expanded(
                  child: _DropZone(
                    atTop: false,
                    onWillAccept: (d) => d.id != task.id,
                    onAccept: (d) => _drop(context, ref, d, asChild: true),
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

class _DropZone extends StatelessWidget {
  final bool atTop;
  final bool Function(Task dragged) onWillAccept;
  final void Function(Task dragged) onAccept;

  const _DropZone({
    required this.atTop,
    required this.onWillAccept,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<Task>(
      onWillAcceptWithDetails: (d) => onWillAccept(d.data),
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (context, candidates, _) {
        if (candidates.isEmpty) return const SizedBox.expand();
        return Align(
          alignment: atTop ? Alignment.topCenter : Alignment.bottomCenter,
          child: Container(
            height: 3,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      },
    );
  }
}
