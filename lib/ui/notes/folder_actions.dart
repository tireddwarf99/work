/// Действия над папками (§4, §11): создание, переименование, удаление
/// со всем содержимым в корзину.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import '../common/dialogs.dart';
import '../providers.dart';

enum FolderAction { rename, delete }

/// Создаёт папку верхнего уровня; возвращает её либо null при отмене.
Future<Folder?> createFolder(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final folders = ref.read(foldersServiceProvider);
  final name = await showTextInputDialog(
    context,
    title: l10n.newFolder,
    hint: l10n.folderNameHint,
  );
  if (name == null) return null;
  return folders.create(name);
}

Future<void> renameFolder(
  BuildContext context,
  WidgetRef ref,
  Folder folder,
) async {
  final l10n = AppLocalizations.of(context)!;
  final folders = ref.read(foldersServiceProvider);
  final name = await showTextInputDialog(
    context,
    title: l10n.rename,
    hint: l10n.folderNameHint,
    initial: folder.name,
  );
  if (name == null || name == folder.name) return;
  await folders.rename(folder.id, name);
}

/// Удаляет папку с подтверждением; true — папка перенесена в корзину.
Future<bool> deleteFolder(
  BuildContext context,
  WidgetRef ref,
  Folder folder,
) async {
  final l10n = AppLocalizations.of(context)!;
  final folders = ref.read(foldersServiceProvider);
  final notes = ref.read(notesServiceProvider);
  final confirmed = await showConfirmDialog(
    context,
    message: l10n.deleteFolderConfirm,
    confirmLabel: l10n.delete,
  );
  if (!confirmed) return false;
  // Сервис папок переносит в корзину только папки; заметки внутри
  // уходят вместе с ними, иначе они остались бы без видимой папки.
  for (final note in await notes.listInFolder(folder.id)) {
    await notes.moveToTrash(note.id);
  }
  await folders.moveToTrash(folder.id);
  return true;
}

/// Пункты меню папки.
List<PopupMenuEntry<FolderAction>> folderMenuItems(AppLocalizations l10n) => [
  PopupMenuItem(value: FolderAction.rename, child: Text(l10n.rename)),
  PopupMenuItem(value: FolderAction.delete, child: Text(l10n.delete)),
];

/// Android: полоса выбора папки над перечнем заметок. Долгое нажатие на
/// папку — переименование/удаление.
class FolderBar extends ConsumerWidget {
  final String? selectedFolderId;
  final void Function(String? folderId) onSelected;

  const FolderBar({
    super.key,
    required this.selectedFolderId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final folders = ref.watch(foldersServiceProvider);
    return StreamBuilder<List<Folder>>(
      stream: folders.watchAll(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <Folder>[];
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              ChoiceChip(
                label: Text(l10n.noFolder),
                selected: selectedFolderId == null,
                onSelected: (_) => onSelected(null),
              ),
              for (final folder in items)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: GestureDetector(
                    onLongPress: () => _showMenu(context, ref, folder),
                    child: ChoiceChip(
                      label: Text(folder.name),
                      selected: selectedFolderId == folder.id,
                      onSelected: (_) => onSelected(folder.id),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: ActionChip(
                  avatar: const Icon(
                    Icons.create_new_folder_outlined,
                    size: 18,
                  ),
                  label: Text(l10n.newFolder),
                  onPressed: () async {
                    final created = await createFolder(context, ref);
                    if (created != null) onSelected(created.id);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    Folder folder,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<FolderAction>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.rename),
              onTap: () => Navigator.pop(ctx, FolderAction.rename),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(l10n.delete),
              onTap: () => Navigator.pop(ctx, FolderAction.delete),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case FolderAction.rename:
        await renameFolder(context, ref, folder);
      case FolderAction.delete:
        if (await deleteFolder(context, ref, folder) &&
            selectedFolderId == folder.id) {
          onSelected(null);
        }
    }
  }
}
