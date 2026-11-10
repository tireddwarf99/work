/// Действия над заметкой: «Переместить…» (§4, назначение недоступное
/// на экране), закрепление, корзина.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import '../providers.dart';

/// Диалог выбора папки: дерево + «Без папки».
Future<String?> showMoveNoteDialog(
  BuildContext context,
  WidgetRef ref, {
  String? currentFolderId,
}) async {
  final folders = ref.read(foldersServiceProvider);
  final items = await folders.watchAll().first;
  if (!context.mounted) return null;
  final l10n = AppLocalizations.of(context)!;
  return showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(l10n.moveToFolder),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, ''),
          child: Row(
            children: [
              const Icon(Icons.folder_open),
              const SizedBox(width: 10),
              Text(l10n.noFolder),
              if (currentFolderId == null) ...[
                const Spacer(),
                const Icon(Icons.check, size: 18),
              ],
            ],
          ),
        ),
        for (final folder in items)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, folder.id),
            child: Row(
              children: [
                const Icon(Icons.folder_outlined),
                const SizedBox(width: 10),
                Expanded(child: Text(folder.name)),
                if (currentFolderId == folder.id) ...[
                  const Spacer(),
                  const Icon(Icons.check, size: 18),
                ],
              ],
            ),
          ),
      ],
    ),
  );
}

/// Меню заметки; возвращает true, если заметка удалена в корзину.
Future<bool> showNoteMenu(
  BuildContext context,
  WidgetRef ref,
  Note note,
) async {
  final l10n = AppLocalizations.of(context)!;
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline),
            title: Text(l10n.moveToFolder),
            onTap: () => Navigator.pop(ctx, 'move'),
          ),
          ListTile(
            leading: Icon(
              note.pinned ? Icons.push_pin_outlined : Icons.push_pin,
            ),
            title: Text(note.pinned ? l10n.unpin : l10n.pin),
            onTap: () => Navigator.pop(ctx, 'pin'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(l10n.delete),
            onTap: () => Navigator.pop(ctx, 'trash'),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return false;

  final notes = ref.read(notesServiceProvider);
  switch (action) {
    case 'move':
      final target = await showMoveNoteDialog(
        context,
        ref,
        currentFolderId: note.folderId,
      );
      if (target == null || !context.mounted) return false;
      await notes.moveToFolder(note.id, target.isEmpty ? null : target);
      return false;
    case 'pin':
      await notes.setPinned(note.id, !note.pinned);
      return false;
    case 'trash':
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(l10n.deleteNoteConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.delete),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await notes.moveToTrash(note.id);
        return true;
      }
      return false;
  }
  return false;
}
