/// Детали задачи (§5, §8): текст, описание, срок, приоритет, теги,
/// подзадачи. На Windows — правая боковая панель, на Android — экран.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/app_database.dart';
import '../../domain/due_spec.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../common/dialogs.dart';
import '../common/due_label.dart';
import '../common/tag_actions.dart';
import '../common/task_actions.dart';
import '../common/task_row.dart';
import '../providers.dart';
import '../queries.dart';

/// Детали задачи; [onClose] для боковой панели Windows.
class TaskDetails extends ConsumerStatefulWidget {
  final String taskId;
  final VoidCallback? onClose;

  const TaskDetails({super.key, required this.taskId, this.onClose});

  @override
  ConsumerState<TaskDetails> createState() => _TaskDetailsState();
}

enum _DueAction { changeDate, setTime, removeTime, clear }

class _TaskDetailsState extends ConsumerState<TaskDetails> {
  final _descriptionController = TextEditingController();

  /// Подзадача, открытая внутри панели; null — показывается [TaskDetails.taskId].
  String? _openedId;

  /// Задача, чьё описание сейчас в поле ввода.
  String? _descriptionTaskId;

  String get _id => _openedId ?? widget.taskId;

  @override
  void didUpdateWidget(covariant TaskDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId) _openedId = null;
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.pop(context);
    }
  }

  Future<void> _delete(Task task) async {
    final deleted = await deleteTaskToTrash(
        context, ref.read(tasksServiceProvider), task);
    if (deleted && mounted) _close();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final taskAsync = ref.watch(taskProvider(_id));
    final task = taskAsync.value;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: l10n.close,
          onPressed: _close,
        ),
        title: Text(l10n.task),
        actions: [
          if (task != null) ...[
            IconButton(
              icon: const Icon(Icons.drive_file_move_outline),
              tooltip: l10n.moveToFolder,
              onPressed: () => _showMoveTaskDialog(task),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.delete,
              onPressed: () => _delete(task),
            ),
          ],
        ],
      ),
      body: task == null
          ? (taskAsync.isLoading
              ? const Center(child: CircularProgressIndicator())
              : const SizedBox.shrink())
          : _body(context, l10n, task),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n, Task task) {
    final tasks = ref.read(tasksServiceProvider);
    if (_descriptionTaskId != task.id) {
      _descriptionController.text = task.description;
      _descriptionTaskId = task.id;
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
  }

  Widget _titleRow(BuildContext context, Task task) {
    final tasks = ref.read(tasksServiceProvider);
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
  Future<void> _showMoveTaskDialog(Task task) async {
    final l10n = AppLocalizations.of(context)!;
    final lists = ref.read(listsServiceProvider);
    final tasks = ref.read(tasksServiceProvider);

    final inbox = await lists.inbox();
    final standalone = await lists.listStandalone();
    final embedded = await ref.read(embeddedListsProvider.future);
    if (!mounted) return;
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
    if (picked == null || picked == task.listId) return;
    await tasks.moveBranch(task.id, newListId: picked, newParentId: null);
  }

  /// Переход к источнику: список, а для встроенного — заметка (§5).
  Widget _sourceLink(BuildContext context, Task task) {
    final l10n = AppLocalizations.of(context)!;
    final list = ref.watch(taskListProvider(task.listId)).value;
    if (list == null) return const SizedBox.shrink();
    final source = list.isSystem ? l10n.inbox : (list.title ?? l10n.untitled);
    return Text(
      '$source${list.noteId != null ? ' · ${l10n.note}' : ''}',
      style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600),
    );
  }

  Widget _dueRow(BuildContext context, Task task) {
    final l10n = AppLocalizations.of(context)!;
    final due = dueSpecFromRow(task);
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
      onTap: () => _editDue(task, due),
    );
  }

  /// Срок: дата, время, снятие времени и снятие срока целиком (§3).
  Future<void> _editDue(Task task, DueSpec due) async {
    final l10n = AppLocalizations.of(context)!;
    final tasks = ref.read(tasksServiceProvider);
    final _DueAction? action = due.isNone
        ? _DueAction.changeDate
        : await showDialog<_DueAction>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: Text(l10n.dueLabel),
              children: [
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, _DueAction.changeDate),
                  child: Text(l10n.changeDate),
                ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, _DueAction.setTime),
                  child: Text(l10n.setTime),
                ),
                if (due.hasTime)
                  SimpleDialogOption(
                    onPressed: () =>
                        Navigator.pop(ctx, _DueAction.removeTime),
                    child: Text(l10n.removeTime),
                  ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, _DueAction.clear),
                  child: Text(l10n.clearDue),
                ),
              ],
            ),
          );
    if (action == null || !mounted) return;

    switch (action) {
      case _DueAction.clear:
        await tasks.setDue(task.id, const DueSpec.none());
      case _DueAction.removeTime:
        await tasks.setDue(task.id, DueSpec.dateOnly(due.date!));
      case _DueAction.changeDate:
        final date = await _pickDate(due.isNone ? null : due.date);
        if (date == null) return;
        await tasks.setDue(
          task.id,
          due.hasTime
              ? DueSpec.at(date, due.minutes!)
              : DueSpec.dateOnly(date),
        );
      case _DueAction.setTime:
        final date = due.isNone ? await _pickDate(null) : due.date;
        if (date == null || !mounted) return;
        final initial = due.hasTime ? due.minutes! : TimeOfDay.now().hour * 60;
        final time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60),
        );
        if (time == null) return;
        await tasks.setDue(
            task.id, DueSpec.at(date, time.hour * 60 + time.minute));
    }
  }

  /// Выбор даты; возвращает `yyyy-MM-dd` или null при отмене.
  Future<String?> _pickDate(String? current) async {
    final date = await showDatePicker(
      context: context,
      initialDate: current == null ? DateTime.now() : parseYmd(current),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    return date == null ? null : formatYmd(date);
  }

  Widget _priorityRow(BuildContext context, Task task) {
    final l10n = AppLocalizations.of(context)!;
    final tasks = ref.read(tasksServiceProvider);
    String label(Priority p) => switch (p) {
          Priority.high => l10n.priorityHigh,
          Priority.normal => l10n.priorityNormal,
          Priority.low => l10n.priorityLow,
        };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.flag),
      title: Text(l10n.priorityLabel, maxLines: 1),
      trailing: SizedBox(
        width: 110,
        child: Text(
          label(task.priority),
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
                  child: Text(label(p)),
                ),
            ],
          ),
        );
        if (picked != null) await tasks.setPriority(task.id, picked);
      },
    );
  }

  Widget _tagsRow(BuildContext context, Task task) {
    final l10n = AppLocalizations.of(context)!;
    final items = ref
            .watch(tagsForProvider((kind: EntityKind.task, id: task.id)))
            .value ??
        const <Tag>[];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.label_outline),
      title: Text(l10n.tagsLabel),
      subtitle: items.isEmpty
          ? Text(l10n.noTags, style: mutedStyle(context))
          : Wrap(
              spacing: 6,
              children: [for (final t in items) Text(t.name)],
            ),
      onTap: () => pickAndAttachTag(context, ref, EntityKind.task, task.id),
    );
  }

  Widget _subtasksSection(BuildContext context, Task task) {
    final l10n = AppLocalizations.of(context)!;
    final tasks = ref.read(tasksServiceProvider);
    final children = ref.watch(subtasksProvider(task.id)).value ?? const <Task>[];
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
              tooltip: l10n.addTask,
              onPressed: () => showQuickAddSubtask(context, ref, task.id),
            ),
          ],
        ),
        for (final child in children)
          TaskRow(
            task: child,
            onToggle: () => toggleTaskCompletion(context, tasks, child),
            onOpen: () => setState(() => _openedId = child.id),
          ),
      ],
    );
  }
}

/// Быстрое добавление подзадачи.
Future<void> showQuickAddSubtask(
    BuildContext context, WidgetRef ref, String parentId) async {
  final tasks = ref.read(tasksServiceProvider);
  final hint = AppLocalizations.of(context)!.subtaskHint;
  final text = await showTextInputDialog(context, hint: hint);
  if (text == null) return;
  final parent = await tasks.get(parentId);
  await tasks.create(parent.listId, parentId: parentId, text: text);
}

String _dueText(DueSpec due, AppLocalizations l10n) {
  final date = formatDatePart(due, l10n) ?? l10n.noDue;
  return due.hasTime ? '$date, ${formatMinutes(due.minutes!)}' : date;
}
