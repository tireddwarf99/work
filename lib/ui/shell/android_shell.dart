/// Android: нижняя навигация «Огляд», «Заметки», «Списки» (§8); папки/теги
/// внутри заметок, отдельная кнопка настроек.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../providers.dart';
import '../dashboard/dashboard_screen.dart';
import '../lists/lists_screen.dart';
import '../notes/folder_actions.dart';
import '../notes/notes_pane.dart';
import '../settings_screen.dart';

/// Оболочка Android с нижней навигацией; go_router управляет вложенными
/// маршрутами: /, /notes, /lists, /note/:id, /task/:id, /settings.
class AndroidShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;

  const AndroidShell({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (navigationShell.currentIndex) {
          0 => l10n.dashboard,
          1 => l10n.notes,
          _ => l10n.allLists,
        }),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.settingsTooltip,
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.grid_view_outlined),
            selectedIcon: const Icon(Icons.grid_view),
            label: l10n.dashboard,
          ),
          NavigationDestination(
            icon: const Icon(Icons.notes_outlined),
            selectedIcon: const Icon(Icons.notes),
            label: l10n.notes,
          ),
          NavigationDestination(
            icon: const Icon(Icons.format_list_bulleted_outlined),
            selectedIcon: const Icon(Icons.format_list_bulleted),
            label: l10n.allLists,
          ),
        ],
      ),
    );
  }
}

/// Ветка «Обзор» — dashboard.
class AndroidDashboardTab extends ConsumerWidget {
  const AndroidDashboardTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DashboardScreen(
      onOpenTask: (taskId) => context.push('/task/$taskId'),
    );
  }
}

/// Ветка «Заметки»: перечень + создание.
class AndroidNotesTab extends StatefulWidget {
  const AndroidNotesTab({super.key});

  @override
  State<AndroidNotesTab> createState() => _AndroidNotesTabState();
}

class _AndroidNotesTabState extends State<AndroidNotesTab> {
  /// null — «Без папки».
  String? _folderId;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FolderBar(
          selectedFolderId: _folderId,
          onSelected: (id) => setState(() => _folderId = id),
        ),
        Expanded(
          child: NotesPane(
            folderId: _folderId,
            selectedNoteId: null,
            onNoteSelected: (noteId) => context.push('/note/$noteId'),
            trailingFab: true,
          ),
        ),
      ],
    );
  }
}

/// Ветка «Списки».
class AndroidListsTab extends ConsumerWidget {
  const AndroidListsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListsScreen(
      onOpenList: (listId) => context.push('/list/$listId'),
      onOpenTask: (taskId) => context.push('/task/$taskId'),
      onOpenEmbeddedNote: (noteId, blockId) {
        ref.read(pendingEmbedJumpProvider.notifier).state = (
          noteId: noteId,
          blockId: blockId,
        );
        context.push('/note/$noteId');
      },
    );
  }
}

/// Настройки как отдельный экран Android.
class AndroidSettingsScreen extends StatelessWidget {
  const AndroidSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(AppLocalizations.of(context)!.settings),
      ),
      body: const SettingsScreen(),
    );
  }
}
