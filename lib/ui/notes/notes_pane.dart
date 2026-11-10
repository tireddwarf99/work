/// Перечень заметок (средняя панель Windows / экран Android): закреплённые
/// выше, остальные по последнему изменению (§4). Drag-and-drop: заметка
/// между папками и порядок закреплённых (Windows — мышью, Android — долгим
/// нажатием).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/folders_service.dart';
import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../common/platform_drag.dart';
import '../providers.dart';
import 'note_actions.dart';

class NotesPane extends ConsumerWidget {
  final String? folderId;
  final String? selectedNoteId;
  final void Function(String noteId) onNoteSelected;

  /// Android: кнопка создания заметки поверх перечня.
  final bool trailingFab;

  const NotesPane({
    super.key,
    required this.folderId,
    required this.selectedNoteId,
    required this.onNoteSelected,
    this.trailingFab = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesServiceProvider);
    final folders = ref.watch(foldersServiceProvider);
    final l10n = AppLocalizations.of(context)!;

    Widget pane = Container(
      color: sidebarBackground(context),
      child: StreamBuilder<List<Note>>(
        stream: notes.watchInFolder(folderId),
        builder: (context, snapshot) {
          final items = snapshot.data ?? const <Note>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: FutureBuilder<String>(
                  future: _headerText(folders, l10n),
                  builder: (context, snap) => Text(
                    snap.data ?? l10n.notes,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.emptyNotes, style: mutedStyle(context)),
                      const SizedBox(height: 4),
                      Text(l10n.emptyNotesHint, style: mutedStyle(context)),
                    ],
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final note = items[index];
                    return _NoteTile(
                      note: note,
                      selected: note.id == selectedNoteId,
                      showPinDropTarget: note.pinned,
                      onNoteSelected: onNoteSelected,
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );

    if (!trailingFab) return pane;
    return Stack(
      children: [
        pane,
        Positioned(
          right: 16,
          bottom: 16,
          child: Consumer(
            builder: (context, ref, _) => FloatingActionButton(
              onPressed: () async {
                final notesService = ref.read(notesServiceProvider);
                final note = await notesService.create(folderId: folderId);
                onNoteSelected(note.id);
              },
              child: const Icon(Icons.add),
            ),
          ),
        ),
      ],
    );
  }

  Future<String> _headerText(
      FoldersService folders, AppLocalizations l10n) async {
    final target = folderId;
    if (target == null) return l10n.notes;
    try {
      final folder = await folders.get(target);
      return folder.name;
    } on StateError {
      return l10n.noFolder;
    }
  }
}

/// Плитка заметки: перетаскивается; закреплённая принимает перетаскиваемые
/// заметки для перестановки (§4).
class _NoteTile extends ConsumerWidget {
  final Note note;
  final bool selected;
  final bool showPinDropTarget;
  final void Function(String noteId) onNoteSelected;

  const _NoteTile({
    required this.note,
    required this.selected,
    required this.showPinDropTarget,
    required this.onNoteSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesServiceProvider);
    final l10n = AppLocalizations.of(context)!;
    final tile = Material(
      color: selected ? accentBackground(context) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: () => onNoteSelected(note.id),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.title ?? l10n.untitled,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: selected || note.pinned
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                  if (note.pinned)
                    Icon(
                      Icons.push_pin,
                      size: 14,
                      color: mutedText(context),
                    ),
                  InkWell(
                    onTap: () async {
                      await showNoteMenu(context, ref, note);
                    },
                    child: Icon(Icons.more_vert,
                        size: 16, color: mutedText(context)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _subtitle(note, l10n),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mutedStyle(context),
              ),
            ],
          ),
        ),
      ),
    );

    final draggable = PlatformDraggable<String>(
      data: note.id,
      feedback: dragFeedbackCard(
        context,
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(note.title ?? l10n.untitled),
        ),
      ),
      child: tile,
    );

    if (!showPinDropTarget) return draggable;

    return DragTarget<String>(
      builder: (context, candidates, rejected) {
        final hovered = candidates.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: hovered
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: draggable,
        );
      },
      onWillAcceptWithDetails: (details) => details.data != note.id,
      onAcceptWithDetails: (details) {
        notes.reorderPinned(details.data, afterId: note.id);
      },
    );
  }

  String _subtitle(Note note, AppLocalizations l10n) {
    final text = note.searchText.trim();
    final snippet = text.isEmpty ? '' : text.split('\n').first;
    final date =
        DateFormat('d MMM', l10n.localeName).format(note.modifiedAt.toLocal());
    return '$snippet · $date'.trim();
  }
}
