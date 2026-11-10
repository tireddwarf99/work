/// Корзина (§11): содержимое с восстановлением. Физическое удаление
/// выполняет TrashService по истечении срока хранения (30 дней, §11);
/// удаления вручную в сервисе нет.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_database.dart';
import '../l10n/app_localizations.dart';
import 'app_theme.dart';
import 'common/dialogs.dart';
import 'providers.dart';

final _trashedNotesProvider = StreamProvider.autoDispose<List<Note>>(
    (ref) => ref.watch(trashServiceProvider).watchTrashedNotes());
final _trashedFoldersProvider = StreamProvider.autoDispose<List<Folder>>(
    (ref) => ref.watch(trashServiceProvider).watchTrashedFolders());
final _trashedListsProvider = StreamProvider.autoDispose<List<TaskList>>(
    (ref) => ref.watch(trashServiceProvider).watchTrashedLists());
final _trashedTasksProvider = StreamProvider.autoDispose<List<Task>>(
    (ref) => ref.watch(trashServiceProvider).watchTrashedTasks());

class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  /// Выполняет восстановление и сообщает результат пользователю.
  Future<void> _restore(
    BuildContext context,
    Future<Object?> Function() action, {
    String? message,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(message ?? l10n.restored)));
    } catch (e, st) {
      debugPrint('trash restore failed: $e\n$st');
      if (context.mounted) showActionError(context);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final trash = ref.watch(trashServiceProvider);
    final lists = ref.watch(listsServiceProvider);
    final tasks = ref.watch(tasksServiceProvider);

    final notes = ref.watch(_trashedNotesProvider).value ?? const <Note>[];
    final folders =
        ref.watch(_trashedFoldersProvider).value ?? const <Folder>[];
    final trashedLists =
        ref.watch(_trashedListsProvider).value ?? const <TaskList>[];
    final trashedTasks =
        ref.watch(_trashedTasksProvider).value ?? const <Task>[];
    final isEmpty = notes.isEmpty &&
        folders.isEmpty &&
        trashedLists.isEmpty &&
        trashedTasks.isEmpty;

    Widget tile({
      required IconData icon,
      required String title,
      required String kind,
      required Future<void> Function() onRestore,
    }) =>
        ListTile(
          leading: Icon(icon),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(kind, style: mutedStyle(context)),
          trailing: IconButton(
            icon: const Icon(Icons.restore),
            tooltip: l10n.restore,
            onPressed: onRestore,
          ),
        );

    return Container(
      color: sidebarBackground(context),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.trash,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          if (isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(l10n.trashEmpty, style: mutedStyle(context)),
            ),
          for (final note in notes)
            tile(
              icon: Icons.notes,
              title: note.title ?? l10n.untitled,
              kind: l10n.note,
              onRestore: () => _restore(
                context,
                () async {
                  final moved = await trash.restoreNote(note.id);
                  if (moved && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.movedToNoFolderHint)));
                  }
                  return moved;
                },
                message: l10n.restored,
              ),
            ),
          for (final folder in folders)
            tile(
              icon: Icons.folder_outlined,
              title: folder.name,
              kind: l10n.folder,
              onRestore: () =>
                  _restore(context, () => trash.restoreFolder(folder.id)),
            ),
          for (final list in trashedLists)
            tile(
              icon: Icons.format_list_bulleted,
              title: list.title ?? l10n.untitled,
              kind: l10n.allLists,
              onRestore: () =>
                  _restore(context, () => lists.restoreFromTrash(list.id)),
            ),
          for (final task in trashedTasks)
            tile(
              icon: Icons.check_box_outline_blank,
              title: task.content,
              kind: l10n.task,
              onRestore: () =>
                  _restore(context, () => tasks.restoreBranchFromTrash(task.id)),
            ),
        ],
      ),
    );
  }
}
