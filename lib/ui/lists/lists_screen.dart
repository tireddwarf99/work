/// Раздел «Списки» (§4): «Входящие» сверху, самостоятельные в ручном
/// порядке; списки из заметок показывают источник.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/lists_service.dart';
import '../../data/notes_service.dart';
import '../../data/tasks_service.dart';
import '../../db/app_database.dart';
import '../../domain/due_spec.dart';
import '../../domain/task_sort.dart';
import '../../domain/task_sort_input.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../common/section_card.dart';
import '../common/task_dnd.dart';
import '../common/task_actions.dart';
import '../common/task_row.dart';
import '../editor/task_list_card.dart';
import '../providers.dart';

/// Экран списка задач: карточка со списком + сортировка (§4).
class ListDetailScreen extends ConsumerStatefulWidget {
  final String listId;
  final void Function(Task task)? onOpenTask;

  const ListDetailScreen({super.key, required this.listId, this.onOpenTask});

  @override
  ConsumerState<ListDetailScreen> createState() => _ListDetailScreenState();
}

class _ListDetailScreenState extends ConsumerState<ListDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final lists = ref.watch(listsServiceProvider);
    final tasks = ref.watch(tasksServiceProvider);

    return FutureBuilder<TaskList>(
      future: lists.get(widget.listId),
      builder: (context, listSnap) {
        if (!listSnap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final list = listSnap.data!;
        return StreamBuilder<List<Task>>(
          stream: tasks.watchActiveInList(widget.listId),
          builder: (context, snap) {
            final all = snap.data ?? const <Task>[];
            final sorted = _sorted(list, all, l10n);
            return Scaffold(
              appBar: AppBar(
                title: Text(list.title ?? l10n.untitled),
                actions: [
                  PopupMenuButton<SortMode>(
                    icon: const Icon(Icons.sort),
                    onSelected: (mode) =>
                        lists.setSortMode(widget.listId, mode),
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                        value: SortMode.manual,
                        child: Text(l10n.sortManual),
                      ),
                      PopupMenuItem(
                        value: SortMode.due,
                        child: Text(l10n.sortDue),
                      ),
                      PopupMenuItem(
                        value: SortMode.priority,
                        child: Text(l10n.sortPriority),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () => showQuickAddTask(
                        context, ref, widget.listId),
                  ),
                ],
              ),
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final root in sorted.where((t) => t.parentId == null))
                    _branch(context, root, sorted),
                ],
              ),
            );
          },
        );
      },
    );
  }

  List<Task> _sorted(TaskList list, List<Task> all, AppLocalizations l10n) {
    final SortMode mode = list.sortMode;
    if (mode == SortMode.manual) return all;
    // Сортируются соседние узлы (§4): компаратор домена по сроку/приоритету
    // с ручным порядком как последним критерием.
    int compare(Task a, Task b) {
      final inputA = TaskSortInput(
        priority: a.priority,
        due: dueSpecFromRow(a),
        manualOrder: a.manualOrder,
      );
      final inputB = TaskSortInput(
        priority: b.priority,
        due: dueSpecFromRow(b),
        manualOrder: b.manualOrder,
      );
      return mode == SortMode.due
          ? compareByDue(inputA, inputB)
          : compareByPriority(inputA, inputB);
    }

    return [...all]..sort(compare);
  }

  Widget _branch(BuildContext context, Task root, List<Task> all) {
    final tasks = ref.watch(tasksServiceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cardBorder(context)),
          ),
          child: TaskDndRow(
            task: root,
            allTasks: all,
            onToggle: () => toggleTaskCompletion(context, tasks, root),
            onOpen: () => widget.onOpenTask?.call(root),
            child: TaskRow(
              task: root,
              onToggle: () => toggleTaskCompletion(context, tasks, root),
              onOpen: () => widget.onOpenTask?.call(root),
            ),
          ),
        ),
        for (final child in all.where((t) => t.parentId == root.id))
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: _branch(context, child, all),
          ),
      ],
    );
  }
}

/// Экран «Усі списки»: Входящие + самостоятельные + встроенные с источником.
class ListsScreen extends ConsumerWidget {
  final String? openListId;
  final void Function(String listId)? onOpenList;
  final void Function(String taskId)? onOpenTask;

  /// Переход к списку в заметке (§4): открыть заметку у её embed'а.
  final void Function(String noteId, String blockId)? onOpenEmbeddedNote;

  const ListsScreen({
    super.key,
    this.openListId,
    this.onOpenList,
    this.onOpenTask,
    this.onOpenEmbeddedNote,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(listsServiceProvider);
    final notes = ref.watch(notesServiceProvider);
    final l10n = AppLocalizations.of(context)!;

    return StreamBuilder<List<TaskList>>(
      stream: lists.watchStandalone(),
      builder: (context, snapshot) {
        final standalone = snapshot.data ?? const <TaskList>[];
        final tasksService = ref.watch(tasksServiceProvider);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ListDropTarget(
              listId: inboxListId,
              tasks: tasksService,
              child: SectionCard(
                title: l10n.inbox,
                onAdd: openListId == null
                    ? null
                    : () => showQuickAddTask(context, ref, inboxListId),
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
                  onAdd: () => showQuickAddTask(context, ref, list.id),
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
            const SizedBox(height: 8),
            // Списки из заметок показывают источник (§4).
            FutureBuilder<List<TaskList>>(
              future: _embeddedLists(lists, notes),
              builder: (context, embeddedSnap) {
                final embedded = embeddedSnap.data ?? const <TaskList>[];
                if (embedded.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
            ),
          ],
        );
      },
    );
  }

  Future<List<TaskList>> _embeddedLists(
      TaskListsService lists, NotesService notes) async {
    final allNotes = await notes.listInFolder(null, includeTrashed: false);
    final result = <TaskList>[];
    for (final note in allNotes) {
      result.addAll(await lists.listInNote(note.id));
    }
    return result;
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
    final tasks = ref.watch(tasksServiceProvider);
    return StreamBuilder<List<Task>>(
      stream: tasks.watchActiveInList(listId),
      builder: (context, snapshot) {
        final all = snapshot.data ?? const <Task>[];
        final roots = all.where((t) => t.parentId == null).toList();
        final preview = roots.take(4);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (preview.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  AppLocalizations.of(context)!.emptyNotesHint,
                  style: mutedStyle(context),
                ),
              ),
            for (final task in preview)
              TaskRow(
                task: task,
                onToggle: () =>
                    toggleTaskCompletion(context, tasks, task),
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
                    Text(
                      AppLocalizations.of(context)!.notes,
                      style: mutedStyle(context),
                    ),
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
    final notes = ref.watch(notesServiceProvider);
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<Note?>(
      future: _note(notes),
      builder: (context, snap) {
        final note = snap.data;
        final source = note?.title ?? l10n.untitled;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: note == null ||
                      list.embedBlockId == null ||
                      onOpenSource == null
                  ? null
                  : () => onOpenSource!(note.id, list.embedBlockId!),
              child: Text(
                l10n.embeddedFrom(source),
                style: mutedStyle(context)?.copyWith(
                  decoration: onOpenSource != null
                      ? TextDecoration.underline
                      : null,
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
      },
    );
  }

  Future<Note?> _note(NotesService notes) async {
    final noteId = list.noteId;
    if (noteId == null) return null;
    try {
      return await notes.get(noteId);
    } on StateError {
      return null;
    }
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
        try {
          await tasks.moveBranch(task.id,
              newListId: listId, newParentId: null);
        } on StateError {
          // Циклический перенос запрещён (§4).
        }
      },
    );
  }
}
