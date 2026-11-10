/// Корзина (§11): восстановление, окончательное удаление — этап 2 показывает
/// содержимое с восстановлением; физическая очистка — TrashService (30 дней).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import 'app_theme.dart';
import 'providers.dart';

class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final trash = ref.watch(trashServiceProvider);
        final lists = ref.watch(listsServiceProvider);
    final tasks = ref.watch(tasksServiceProvider);

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
          StreamBuilder<List<Note>>(
            stream: trash.watchTrashedNotes(),
            builder: (context, snap) {
              final items = snap.data ?? const <Note>[];
              if (items.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(l10n.trashEmpty, style: mutedStyle(context)),
                );
              }
              return Column(
                children: [
                  for (final note in items)
                    ListTile(
                      leading: const Icon(Icons.notes),
                      title: Text(note.title ?? l10n.untitled,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(l10n.note, style: mutedStyle(context)),
                      trailing: IconButton(
                        icon: const Icon(Icons.restore),
                        tooltip: l10n.restore,
                        onPressed: () async {
                          final moved = await trash.restoreNote(note.id);
                          if (context.mounted && moved) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(l10n.movedToNoFolderHint)),
                            );
                          }
                        },
                      ),
                    ),
                ],
              );
            },
          ),
          StreamBuilder<List<TaskList>>(
            stream: trash.watchTrashedLists(),
            builder: (context, snap) {
              final items = snap.data ?? const <TaskList>[];
              return Column(
                children: [
                  for (final list in items)
                    ListTile(
                      leading: const Icon(Icons.format_list_bulleted),
                      title: Text(list.title ?? l10n.untitled,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(l10n.allLists, style: mutedStyle(context)),
                      trailing: IconButton(
                        icon: const Icon(Icons.restore),
                        onPressed: () => lists.restoreFromTrash(list.id),
                      ),
                    ),
                ],
              );
            },
          ),
          StreamBuilder<List<Task>>(
            stream: trash.watchTrashedTasks(),
            builder: (context, snap) {
              final items = snap.data ?? const <Task>[];
              return Column(
                children: [
                  for (final task in items)
                    ListTile(
                      leading: const Icon(Icons.check_box_outline_blank),
                      title: Text(task.content,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(l10n.task, style: mutedStyle(context)),
                      trailing: IconButton(
                        icon: const Icon(Icons.restore),
                        onPressed: () =>
                            tasks.restoreBranchFromTrash(task.id),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
