/// Раздел «Списки» (§4): «Входящие» сверху, самостоятельные в ручном
/// порядке; списки из заметок показывают источник.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tasks_service.dart';
import '../../db/app_database.dart';
import '../../domain/due_spec.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../common/dialogs.dart';
import '../common/section_card.dart';
import '../common/task_actions.dart';
import '../common/task_row.dart';
import '../editor/task_list_card.dart';
import '../providers.dart';
import '../queries.dart';

enum _ListAction { rename, delete }

/// Запрашивает новое название списка и сохраняет его (пусто — «Без названия»).
Future<void> renameList(
    BuildContext context, WidgetRef ref, TaskList list) async {
  final l10n = AppLocalizations.of(context)!;
  final service = ref.read(listsServiceProvider);
  final title = await showTextInputDialog(
    context,
    title: l10n.rename,
    hint: l10n.listTitleHint,
    initial: list.title ?? '',
    allowEmpty: true,
  );
  if (title == null) return;
  await service.rename(list.id, title.isEmpty ? null : title);
}

/// Создаёт самостоятельный список по введённому названию.
Future<void> createList(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final service = ref.read(listsServiceProvider);
  final title = await showTextInputDialog(
    context,
    title: l10n.newList,
    hint: l10n.listTitleHint,
  );
  if (title == null) return;
  await service.create(title: title);
}

/// Удаление списка в корзину с подтверждением (§11); true — удалён.
Future<bool> deleteList(
    BuildContext context, WidgetRef ref, TaskList list) async {
  final l10n = AppLocalizations.of(context)!;
  final service = ref.read(listsServiceProvider);
  final confirmed = await showConfirmDialog(
    context,
    message: l10n.deleteListConfirm,
    confirmLabel: l10n.delete,
  );
  if (!confirmed) return false;
  await service.moveToTrash(list.id);
  return true;
}

/// Меню переименования и удаления самостоятельного списка.
class _ListMenu extends ConsumerWidget {
  final TaskList list;
  final VoidCallback? onDeleted;

  const _ListMenu({required this.list, this.onDeleted});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<_ListAction>(
      icon: const Icon(Icons.more_vert),
      onSelected: (action) async {
        switch (action) {
          case _ListAction.rename:
            await renameList(context, ref, list);
          case _ListAction.delete:
            if (await deleteList(context, ref, list)) onDeleted?.call();
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(value: _ListAction.rename, child: Text(l10n.rename)),
        PopupMenuItem(value: _ListAction.delete, child: Text(l10n.delete)),
      ],
    );
  }
}

/// Экран списка задач: карточка со списком + сортировка (§4).
class ListDetailScreen extends ConsumerWidget {
  final String listId;
  final void Function(Task task)? onOpenTask;

  /// Вызывается после удаления списка из этого экрана; по умолчанию экран
  /// закрывается как маршрут.
  final VoidCallback? onDeleted;

  const ListDetailScreen({
    super.key,
    required this.listId,
    this.onOpenTask,
    this.onDeleted,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final listAsync = ref.watch(taskListProvider(listId));
    final list = listAsync.value;
    if (list == null) {
      return Scaffold(
        appBar: AppBar(),
        body: listAsync.isLoading
            ? const Center(child: CircularProgressIndicator())
            : const SizedBox.shrink(),
      );
    }
    final lists = ref.read(listsServiceProvider);
    final isStandalone = !list.isSystem && list.noteId == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(list.isSystem ? l10n.inbox : (list.title ?? l10n.untitled)),
        actions: [
          PopupMenuButton<SortMode>(
            icon: const Icon(Icons.sort),
            tooltip: l10n.sortMode,
            initialValue: list.sortMode,
            onSelected: (mode) => lists.setSortMode(listId, mode),
            itemBuilder: (ctx) => [
              PopupMenuItem(
                  value: SortMode.manual, child: Text(l10n.sortManual)),
              PopupMenuItem(value: SortMode.due, child: Text(l10n.sortDue)),
              PopupMenuItem(
                  value: SortMode.priority, child: Text(l10n.sortPriority)),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: l10n.addTask,
            onPressed: () => showQuickAddTask(context, ref, listId),
          ),
          if (isStandalone)
            _ListMenu(
              list: list,
              onDeleted: onDeleted ?? () => Navigator.maybePop(context),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TaskListCard(
            listId: listId,
            showTitle: false,
            onOpenTask: (task) => onOpenTask?.call(task),
          ),
        ],
      ),
    );
  }
}

/// Экран «Усі списки»: Входящие + самостоятельные + встроенные с источником.
class ListsScreen extends ConsumerWidget {
  final void Function(String listId)? onOpenList;
  final void Function(String taskId)? onOpenTask;

  /// Переход к списку в заметке (§4): открыть заметку у её embed'а.
  final void Function(String noteId, String blockId)? onOpenEmbeddedNote;

  const ListsScreen({
    super.key,
    this.onOpenList,
    this.onOpenTask,
    this.onOpenEmbeddedNote,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(listsServiceProvider);
    final tasksService = ref.watch(tasksServiceProvider);
    final embedded =
        ref.watch(embeddedListsProvider).value ?? const <TaskList>[];
    final l10n = AppLocalizations.of(context)!;

    return StreamBuilder<List<TaskList>>(
      stream: lists.watchStandalone(),
      builder: (context, snapshot) {
        final standalone = snapshot.data ?? const <TaskList>[];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.newList),
                onPressed: () => createList(context, ref),
              ),
            ),
            const SizedBox(height: 16),
            _ListDropTarget(
              listId: inboxListId,
              tasks: tasksService,
              child: SectionCard(
                title: l10n.inbox,
                addTooltip: l10n.addTask,
                onAdd: () => showQuickAddTask(context, ref, inboxListId),
                children: [
                  _ListPreview(
                    listId: inboxListId,
                    onOpen: () => onOpenList?.call(inboxListId),
                    onOpenTask: onOpenTask,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            for (final list in standalone) ...[
              _ListDropTarget(
                listId: list.id,
                tasks: tasksService,
                child: SectionCard(
                  title: list.title ?? l10n.untitled,
                  addTooltip: l10n.addTask,
                  onAdd: () => showQuickAddTask(context, ref, list.id),
                  actions: [_ListMenu(list: list)],
                  children: [
                    _ListPreview(
                      listId: list.id,
                      onOpen: () => onOpenList?.call(list.id),
                      onOpenTask: onOpenTask,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            // Списки из заметок показывают источник (§4).
            for (final list in embedded)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _EmbeddedListCard(
                  list: list,
                  onOpenTask: onOpenTask,
                  onOpenSource: onOpenEmbeddedNote,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Компактный предпросмотр первых задач списка.
class _ListPreview extends ConsumerWidget {
  final String listId;
  final VoidCallback onOpen;
  final void Function(String taskId)? onOpenTask;

  const _ListPreview({
    required this.listId,
    required this.onOpen,
    this.onOpenTask,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tasks = ref.watch(tasksServiceProvider);
    return StreamBuilder<List<Task>>(
      stream: tasks.watchActiveInList(listId),
      builder: (context, snapshot) {
        final all = snapshot.data ?? const <Task>[];
        final preview = all
            .where((t) => t.parentId == null && t.completedAt == null)
            .take(4)
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (preview.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(l10n.emptyListHint, style: mutedStyle(context)),
              ),
            for (final task in preview)
              TaskRow(
                task: task,
                onToggle: () => toggleTaskCompletion(context, tasks, task),
                onOpen: () {
                  final openTask = onOpenTask;
                  if (openTask != null) {
                    openTask(task.id);
                  } else {
                    onOpen();
                  }
                },
              ),
            InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Text(l10n.openList, style: mutedStyle(context)),
                    const Spacer(),
                    Icon(Icons.arrow_forward,
                        size: 18, color: Theme.of(context).colorScheme.primary),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Карточка списка, встроенного в заметку: источник виден (§4).
class _EmbeddedListCard extends ConsumerWidget {
  final TaskList list;
  final void Function(String taskId)? onOpenTask;
  final void Function(String noteId, String blockId)? onOpenSource;

  const _EmbeddedListCard({
    required this.list,
    required this.onOpenTask,
    this.onOpenSource,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final noteId = list.noteId;
    final note = noteId == null ? null : ref.watch(noteProvider(noteId)).value;
    final blockId = list.embedBlockId;
    final canOpen = note != null && blockId != null && onOpenSource != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: canOpen ? () => onOpenSource!(note.id, blockId) : null,
          child: Text(
            l10n.embeddedFrom(note?.title ?? l10n.untitled),
            style: mutedStyle(context)?.copyWith(
              decoration: canOpen ? TextDecoration.underline : null,
            ),
          ),
        ),
        const SizedBox(height: 6),
        TaskListCard(
          listId: list.id,
          onOpenTask: (task) => onOpenTask?.call(task.id),
        ),
      ],
    );
  }
}

/// Карточка списка принимает перетаскиваемые задачи: перенос между
/// списками вместе с веткой, корнем списка (§4).
class _ListDropTarget extends StatelessWidget {
  final String listId;
  final TasksService tasks;
  final Widget child;

  const _ListDropTarget({
    required this.listId,
    required this.tasks,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<Task>(
      builder: (context, candidates, rejected) {
        final hovered = candidates.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hovered
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: child,
        );
      },
      onAcceptWithDetails: (details) async {
        final task = details.data;
        if (task.listId == listId) return;
        final messenger = ScaffoldMessenger.of(context);
        final message = AppLocalizations.of(context)!.dropForbidden;
        try {
          await tasks.moveBranch(task.id, newListId: listId, newParentId: null);
        } on StateError {
          // Циклический перенос запрещён (§4).
          messenger.showSnackBar(SnackBar(content: Text(message)));
        }
      },
    );
  }
}
