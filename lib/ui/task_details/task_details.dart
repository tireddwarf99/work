/// Детали задачи (§5, §8): текст, описание, срок, приоритет, теги,
/// подзадачи. На Windows — правая боковая панель, на Android — экран.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/app_database.dart';
import '../../domain/due_spec.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../common/task_actions.dart';
import '../common/due_label.dart';
import '../common/task_row.dart';
import '../providers.dart';

/// Детали задачи; [onClose] для боковой панели Windows.
class TaskDetails extends ConsumerStatefulWidget {
  final String taskId;
  final VoidCallback? onClose;

  const TaskDetails({super.key, required this.taskId, this.onClose});

  @override
  ConsumerState<TaskDetails> createState() => _TaskDetailsState();
}

class _TaskDetailsState extends ConsumerState<TaskDetails> {
  late Future<Task?> _task;
  final _descriptionController = TextEditingController();
  bool _descriptionInitialized = false;

  @override
  void initState() {
    super.initState();
    _task = _load();
  }

  Future<Task?> _load() async {
    try {
      return await ref.read(tasksServiceProvider).get(widget.taskId);
    } on StateError {
      return null;
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tasks = ref.watch(tasksServiceProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () =>
              widget.onClose != null ? widget.onClose!() : Navigator.pop(context),
        ),
        title: Text(l10n.task),
        actions: [
          IconButton(
            icon: const Icon(Icons.drive_file_move_outline),
            tooltip: l10n.moveToFolder,
            onPressed: () => _showMoveTaskDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final task = await _task;
              if (task == null || !context.mounted) return;
              await deleteTaskToTrash(context, tasks, task);
              if (!context.mounted) return;
              if (widget.onClose != null) {
                widget.onClose!();
              } else {
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: FutureBuilder<Task?>(
        future: _task,
        builder: (context, snapshot) {
          final task = snapshot.data;
          if (task == null) {
            return const SizedBox.shrink();
          }
          if (!_descriptionInitialized) {
            _descriptionController.text = task.description;
            _descriptionInitialized = true;
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _titleRow(context, task),
              const SizedBox(height: 8),
              _sourceLink(context, task),
              const Divider(height: 32),
              // Описание (простой текст, §3).
              Text(l10n.descriptionLabel, style: mutedStyle(context)),
              TextField(
                controller: _descriptionController,
                maxLines: null,
                decoration: InputDecoration(hintText: l10n.noDescription),
                onChanged: (v) => tasks.updateDescription(task.id, v),
              ),
              const SizedBox(height: 16),
              _dueRow(context, task),
              _priorityRow(context, task),
              _tagsRow(context, task),
              const SizedBox(height: 16),
              _subtasksSection(context, task),
            ],
          );
        },
      ),
    );
  }

  Widget _titleRow(BuildContext context, Task task) {
    final tasks = ref.watch(tasksServiceProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 36,
          height: 40,
          child: Checkbox(
            value: task.completedAt != null,
            onChanged: (_) => toggleTaskCompletion(context, tasks, task),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            task.content,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (task.priority == Priority.high)
          const Icon(Icons.flag, color: AppColors.danger),
      ],
    );
  }

  /// «Переместить…»: список назначения, недоступный на экране (§4).
  Future<void> _showMoveTaskDialog(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final task = await _task;
    if (task == null || !context.mounted) return;
    final lists = ref.read(listsServiceProvider);
    final notes = ref.read(notesServiceProvider);

    final inbox = await lists.inbox();
    final standalone = await lists.listStandalone();
    final allNotes = await notes.listInFolder(null);
    final embedded = <TaskList>[];
    for (final note in allNotes) {
      embedded.addAll(await lists.listInNote(note.id));
    }

    if (!context.mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.moveToFolder),
        children: [
          for (final list in [inbox, ...standalone, ...embedded])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, list.id),
              child: Row(
                children: [
                  const Icon(Icons.format_list_bulleted, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      list.isSystem
                          ? l10n.inbox
                          : (list.title ?? l10n.untitled),
                    ),
                  ),
                  if (list.id == task.listId) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == task.listId || !context.mounted) return;
    await ref
        .read(tasksServiceProvider)
        .moveBranch(task.id, newListId: picked, newParentId: null);
    if (context.mounted) setState(() => _task = _load());
  }

  /// Переход к источнику: список, а для встроенного — заметка (§5).
  Widget _sourceLink(BuildContext context, Task task) {
    final l10n = AppLocalizations.of(context)!;
    final lists = ref.watch(listsServiceProvider);
    return FutureBuilder<TaskList>(
      future: lists.get(task.listId),
      builder: (context, snap) {
        final list = snap.data;
        if (list == null) return const SizedBox.shrink();
        final source = list.title ?? l10n.inbox;
        return Text(
          '${list.isSystem ? l10n.inbox : source}'
          '${list.noteId != null ? ' · ${l10n.note}' : ''}',
          style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600),
        );
      },
    );
  }

  Widget _dueRow(BuildContext context, Task task) {
    final l10n = AppLocalizations.of(context)!;
    final tasks = ref.watch(tasksServiceProvider);
    final due = dueSpecFromRow(task);
    final label = formatDatePart(due, l10n) ??
        (due.hasTime ? null : l10n.noDue);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.grid_view),
      title: Text(l10n.dueLabel, maxLines: 1),
      trailing: SizedBox(
        width: 140,
        child: Text(
          due.isNone ? l10n.noDue : _dueText(due, l10n),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: TextStyle(color: Theme.of(context).colorScheme.primary),
        ),
      ),
      onTap: () async {
        final date = await showDatePicker(
          context: context,
          initialDate: due.isNone ? DateTime.now() : _parseYmd(due.date!),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (date == null) return;
        if (!context.mounted) return;
        if (due.hasTime) {
          final time = await showTimePicker(
            context: context,
            initialTime:
                TimeOfDay(hour: due.minutes! ~/ 60, minute: due.minutes! % 60),
          );
          if (time != null) {
            await tasks.setDue(
              task.id,
              DueSpec.at(_ymd(date), time.hour * 60 + time.minute),
            );
          } else {
            await tasks.setDue(task.id, DueSpec.dateOnly(_ymd(date)));
          }
        } else {
          await tasks.setDue(task.id, DueSpec.dateOnly(_ymd(date)));
        }
        setState(() => _task = _load());
      },
      subtitle: label == null ? null : Text(label, style: mutedStyle(context)),
    );
  }

  Widget _priorityRow(BuildContext context, Task task) {
    final l10n = AppLocalizations.of(context)!;
    final tasks = ref.watch(tasksServiceProvider);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.flag),
      title: Text(l10n.priorityLabel, maxLines: 1),
      trailing: SizedBox(
        width: 110,
        child: Text(
          switch (task.priority) {
            Priority.high => l10n.priorityHigh,
            Priority.normal => l10n.priorityNormal,
            Priority.low => l10n.priorityLow,
          },
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: TextStyle(color: Theme.of(context).colorScheme.primary),
        ),
      ),
      onTap: () async {
        final picked = await showDialog<Priority>(
          context: context,
          builder: (ctx) => SimpleDialog(
            children: [
              for (final p in Priority.values)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, p),
                  child: Text(switch (p) {
                    Priority.high => l10n.priorityHigh,
                    Priority.normal => l10n.priorityNormal,
                    Priority.low => l10n.priorityLow,
                  }),
                ),
            ],
          ),
        );
        if (picked != null) {
          await tasks.setPriority(task.id, picked);
          if (context.mounted) setState(() => _task = _load());
        }
      },
    );
  }

  Widget _tagsRow(BuildContext context, Task task) {
    final l10n = AppLocalizations.of(context)!;
    final tags = ref.watch(tagsServiceProvider);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.label_outline),
      title: Text(l10n.tagsLabel),
      subtitle: FutureBuilder<List<Tag>>(
        future: tags.tagsFor(EntityKind.task, task.id),
        builder: (context, snap) {
          final items = snap.data ?? const <Tag>[];
          if (items.isEmpty) return Text(l10n.noTags, style: mutedStyle(context));
          return Wrap(
            spacing: 6,
            children: [for (final t in items) Text(t.name)],
          );
        },
      ),
      onTap: () async {
        final available = await tags.listAll();
        if (!context.mounted) return;
        final controller = TextEditingController();
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  onSubmitted: (v) => Navigator.pop(ctx, v),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final tag in available)
                      ActionChip(
                        label: Text(tag.name),
                        onPressed: () => Navigator.pop(ctx, tag.id),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
        if (picked == null || picked.isEmpty) return;
        final isId = available.any((t) => t.id == picked);
        final tagId = isId ? picked : (await tags.create(picked.trim())).id;
        await tags.attach(EntityKind.task, task.id, tagId);
        if (context.mounted) setState(() => _task = _load());
      },
    );
  }

  Widget _subtasksSection(BuildContext context, Task task) {
    final l10n = AppLocalizations.of(context)!;
    final tasks = ref.watch(tasksServiceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(l10n.subtasksLabel,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () async {
                await showQuickAddSubtask(context, ref, task.id);
                if (context.mounted) setState(() => _task = _load());
              },
            ),
          ],
        ),
        FutureBuilder<List<Task>>(
          future: tasks.children(task.id),
          builder: (context, snap) {
            final children = snap.data ?? const <Task>[];
            return Column(
              children: [
                for (final child in children)
                  TaskRow(
                    task: child,
                    onToggle: () =>
                        toggleTaskCompletion(context, tasks, child),
                    onOpen: () => setState(() => _task = Future.value(child)),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

Future<void> showQuickAddSubtask(
    BuildContext context, WidgetRef ref, String parentId) async {
  final tasks = ref.watch(tasksServiceProvider);
  final parent = await tasks.get(parentId);
  if (!context.mounted) return;
  final controller = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: TextField(
        controller: controller,
        autofocus: true,
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
    await tasks.create(parent.listId, parentId: parentId, text: text.trim());
  }
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime _parseYmd(String ymd) => DateTime(
    int.parse(ymd.substring(0, 4)),
    int.parse(ymd.substring(5, 7)),
    int.parse(ymd.substring(8, 10)));

String _dueText(DueSpec due, AppLocalizations l10n) {
  final date = formatDatePart(due, l10n) ?? l10n.noDue;
  if (due.hasTime) {
    final mm = (due.minutes! % 60).toString().padLeft(2, '0');
    return '$date, ${(due.minutes! ~/ 60).toString().padLeft(2, '0')}:$mm';
  }
  return date;
}
