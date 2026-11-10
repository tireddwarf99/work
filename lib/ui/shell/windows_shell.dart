/// Windows: утверждённая трёхпанельная компоновка (§8) — навигация,
/// перечень заметок, редактор/содержимое; детали задачи — правая панель.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'panel_resizer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_service.dart';
import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import '../../sync/sync_engine.dart';
import '../app_theme.dart';
import '../dashboard/dashboard_screen.dart';
import '../editor/note_editor.dart';
import '../lists/lists_screen.dart';
import '../notes/notes_pane.dart';
import '../providers.dart';
import '../search_screen.dart';
import '../settings_screen.dart';
import '../task_details/task_details.dart';
import '../trash_screen.dart';

enum WindowsSection { dashboard, notes, lists, trash, search, settings }

/// Sentinel «Без папки» для средней панели (folderId = null).
const String kNoFolderSentinel = '';

String? folderIdFromSentinel(String? v) =>
    v == null || v == kNoFolderSentinel ? null : v;

class WindowsShell extends ConsumerStatefulWidget {
  const WindowsShell({super.key});

  @override
  ConsumerState<WindowsShell> createState() => _WindowsShellState();
}

class _WindowsShellState extends ConsumerState<WindowsShell> {
  WindowsSection _section = WindowsSection.dashboard;
  String? _selectedFolderId;
  String? _selectedNoteId;
  String? _openListId;
  String? _searchQuery;

  // Изменение ширины областей (§8); минимальные ширины соблюдаются
  // в [PanelResizer].
  double _navWidth = 240;
  double _listWidth = 300;
  double _panelWidth = 360;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final panelTaskId = ref.watch(windowsTaskPanelProvider);

    return CallbackShortcuts(
      bindings: {
        // Windows shortcuts (§8): Ctrl+N — заметка, Ctrl+K — поиск,
        // Esc — закрытие панели деталей.
        SingleActivator(LogicalKeyboardKey.keyN, control: true): _createNote,
        SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            setState(() {
              _section = WindowsSection.search;
            }),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            ref.read(windowsTaskPanelProvider.notifier).close(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      body: Row(
        children: [
          SizedBox(width: _navWidth, child: _buildNav(context, l10n)),
          PanelResizer(
            startWidth: _navWidth,
            onDrag: (w) => setState(() => _navWidth = w),
          ),
          VerticalDivider(width: 1, color: cardBorder(context)),
          // Средняя панель: перечень заметок либо содержимое раздела.
          SizedBox(
            width: _listWidth,
            child: _buildMiddle(context, l10n),
          ),
          PanelResizer(
            startWidth: _listWidth,
            onDrag: (w) => setState(() => _listWidth = w),
          ),
          VerticalDivider(width: 1, color: cardBorder(context)),
          // Правая рабочая область: редактор/список/поиск.
          Expanded(
            child: _buildWorkArea(context, l10n),
          ),
          // Детали задачи — правая боковая панель (§8).
          if (panelTaskId != null) ...[
            PanelResizer(
              startWidth: _panelWidth,
              minWidth: 280,
              onDrag: (w) => setState(() => _panelWidth = w),
            ),
            VerticalDivider(width: 1, color: cardBorder(context)),
            SizedBox(
              width: _panelWidth,
              child: TaskDetails(
                taskId: panelTaskId,
                onClose: () =>
                    ref.read(windowsTaskPanelProvider.notifier).close(),
              ),
            ),
          ],
        ],
      ),
        ),
      ),
    );
  }

  Widget _buildNav(BuildContext context, AppLocalizations l10n) {
    return Container(
      width: 240,
      color: sidebarBackground(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              l10n.appTitle,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.create),
                onPressed: _createNote,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _NavItem(
            icon: Icons.search,
            label: l10n.search,
            selected: _section == WindowsSection.search,
            onTap: () => setState(() {
              _section = WindowsSection.search;
            }),
          ),
          _NavItem(
            icon: Icons.grid_view,
            label: l10n.dashboard,
            selected: _section == WindowsSection.dashboard,
            onTap: () => setState(() => _section = WindowsSection.dashboard),
          ),
          _NavItem(
            icon: Icons.notes,
            label: l10n.notes,
            selected: _section == WindowsSection.notes,
            onTap: () => setState(() {
              _section = WindowsSection.notes;
              _selectedFolderId = null;
            }),
          ),
          _NavItem(
            icon: Icons.format_list_bulleted,
            label: l10n.allLists,
            selected: _section == WindowsSection.lists,
            onTap: () => setState(() => _section = WindowsSection.lists),
          ),
          _DropNavItem(
            icon: Icons.delete_outline,
            label: l10n.trash,
            selected: _section == WindowsSection.trash,
            onTap: () => setState(() => _section = WindowsSection.trash),
            onAcceptNote: (noteId) =>
                ref.read(notesServiceProvider).moveToTrash(noteId),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              l10n.folders,
              style: mutedStyle(context)
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 1),
            ),
          ),
          Expanded(
            child: _FolderList(
              selectedFolderId: _selectedFolderId,
              onFolderSelected: (id) => setState(() {
                _section = WindowsSection.notes;
                _selectedFolderId = id;
                _selectedNoteId = null;
              }),
            ),
          ),
          Divider(height: 1, color: cardBorder(context)),
          _NavItem(
            icon: Icons.settings_outlined,
            label: l10n.settings,
            selected: _section == WindowsSection.settings,
            onTap: () => setState(() => _section = WindowsSection.settings),
          ),
          const SizedBox(height: 8),
          const _SyncStatusLine(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildMiddle(BuildContext context, AppLocalizations l10n) {
    switch (_section) {
      case WindowsSection.notes:
        return NotesPane(
          folderId: folderIdFromSentinel(_selectedFolderId),
          selectedNoteId: _selectedNoteId,
          onNoteSelected: (id) => setState(() => _selectedNoteId = id),
        );
      case WindowsSection.lists:
        return ListsScreen(
          openListId: _openListId,
          onOpenList: (id) => setState(() => _openListId = id),
          onOpenTask: (taskId) =>
              ref.read(windowsTaskPanelProvider.notifier).open(taskId),
          onOpenEmbeddedNote: (noteId, blockId) {
            ref.read(pendingEmbedJumpProvider.notifier).state =
                (noteId: noteId, blockId: blockId);
            setState(() {
              _section = WindowsSection.notes;
              _selectedFolderId = null;
              _selectedNoteId = noteId;
            });
          },
        );
      case WindowsSection.trash:
        return const TrashScreen();
      case WindowsSection.search:
        return SearchScreen(
          query: _searchQuery,
          onQueryChanged: (q) => setState(() => _searchQuery = q),
          onOpenNote: (id) => setState(() {
            _section = WindowsSection.notes;
            _selectedFolderId = null;
            _selectedNoteId = id;
          }),
          onOpenTask: (id) =>
              ref.read(windowsTaskPanelProvider.notifier).open(id),
        );
      case WindowsSection.settings:
        return const SettingsScreen();
      case WindowsSection.dashboard:
        // Dashboard занимает две правые области (§8) — средняя пуста.
        return const SizedBox.shrink();
    }
  }

  Widget _buildWorkArea(BuildContext context, AppLocalizations l10n) {
    switch (_section) {
      case WindowsSection.notes:
        if (_selectedNoteId != null) {
          return NoteEditor(
            noteId: _selectedNoteId!,
            onOpenTask: (task) =>
                ref.read(windowsTaskPanelProvider.notifier).open(task.id),
          );
        }
        return Center(
          child: Text(
            l10n.emptyNotesHint,
            style: mutedStyle(context),
          ),
        );
      case WindowsSection.lists:
        if (_openListId != null) {
          return NoteEditorHostForList(listId: _openListId!);
        }
        return const SizedBox.shrink();
      case WindowsSection.dashboard:
        return DashboardScreen(
          onOpenTask: (id) =>
              ref.read(windowsTaskPanelProvider.notifier).open(id),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _createNote() async {
    final notes = ref.read(notesServiceProvider);
    final note =
        await notes.create(folderId: folderIdFromSentinel(_selectedFolderId));
    setState(() {
      _section = WindowsSection.notes;
      _selectedNoteId = note.id;
    });
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? accentBackground(context) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 18,
                  color:
                      selected ? theme.colorScheme.primary : mutedText(context)),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color:
                      selected ? theme.colorScheme.primary : theme.textTheme.bodyMedium?.color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderList extends ConsumerWidget {
  final String? selectedFolderId;
  final void Function(String? folderId) onFolderSelected;

  const _FolderList({
    required this.selectedFolderId,
    required this.onFolderSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersServiceProvider);
    final l10n = AppLocalizations.of(context)!;
    return StreamBuilder<List<Folder>>(
      stream: folders.watchAll(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <Folder>[];
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final folder in items)
              _DropNavItem(
                icon: Icons.folder_outlined,
                label: folder.name,
                selected: selectedFolderId == folder.id,
                onTap: () => onFolderSelected(folder.id),
                onAcceptNote: (noteId) => ref
                    .read(notesServiceProvider)
                    .moveToFolder(noteId, folder.id),
              ),
            _DropNavItem(
              icon: Icons.folder_open,
              label: l10n.noFolder,
              selected: selectedFolderId == kNoFolderSentinel,
              onTap: () => onFolderSelected(kNoFolderSentinel),
              onAcceptNote: (noteId) =>
                  ref.read(notesServiceProvider).moveToFolder(noteId, null),
            ),
          ],
        );
      },
    );
  }
}

class NoteEditorHostForList extends ConsumerWidget {
  final String listId;

  const NoteEditorHostForList({super.key, required this.listId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Список без заметки отображается в средней панели; рабочая область
    // пуста. Переход к списку в заметке открывает заметку (§4) — реализовано
    // через NotesPane.
    return const SizedBox.shrink();
  }
}


/// Пункт навигации, принимающий перетаскиваемые заметки (§4):
/// перемещение в папку, «Без папки» или в корзину.
class _DropNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final void Function(String noteId) onAcceptNote;

  const _DropNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onAcceptNote,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      builder: (context, candidates, rejected) {
        final hovered = candidates.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: hovered
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
            ),
          ),
          child: _NavItem(
            icon: icon,
            label: label,
            selected: selected,
            onTap: onTap,
          ),
        );
      },
      onAcceptWithDetails: (details) => onAcceptNote(details.data),
    );
  }
}


/// Статус синхронизации в нижней части навигации (макет: «Синхронізовано»)
/// с индикатором нерешённых конфликтов (§10).
class _SyncStatusLine extends ConsumerWidget {
  const _SyncStatusLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final authAsync = ref.watch(authStateProvider);
    final syncAsync = ref.watch(syncStatusProvider);
    final authState = authAsync.value ?? const AuthSignedOut();
    final sync = syncAsync.value ?? const SyncStatus();

    final db = ref.watch(appDatabaseProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(
            authState is! AuthSignedIn
                ? Icons.cloud_off
                : sync.error != null
                    ? Icons.sync_problem
                    : Icons.cloud_done,
            size: 14,
            color: mutedText(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              authState is! AuthSignedIn
                  ? l10n.syncOff
                  : sync.error != null
                      ? l10n.syncError
                      : l10n.synced,
              style: mutedStyle(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          StreamBuilder<int>(
            stream: (db.select(db.conflicts)).watch().map((r) => r.length),
            builder: (context, snap) {
              final n = snap.data ?? 0;
              if (n == 0) return const SizedBox.shrink();
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$n',
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onErrorContainer),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
