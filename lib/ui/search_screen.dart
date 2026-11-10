/// Общий поиск по заметкам и задачам (§4): название/текст, Ctrl+K (Windows).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import 'app_theme.dart';
import 'common/task_row.dart';
import '../../data/search_service.dart';
import 'providers.dart';

class SearchScreen extends ConsumerStatefulWidget {
  final String? query;
  final void Function(String query)? onQueryChanged;
  final void Function(String noteId)? onOpenNote;
  final void Function(String taskId)? onOpenTask;

  const SearchScreen({
    super.key,
    this.query,
    this.onQueryChanged,
    this.onOpenNote,
    this.onOpenTask,
  });

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  String _query = '';

  @override
  void initState() {
    super.initState();
    _query = widget.query ?? '';
  }

  Future<(List<Note>, List<Task>)> _runSearch(
      SearchService search, String query) async {
    final results = await Future.wait<Object?>(
        [search.notes(query), search.tasks(query)]);
    return (
      results[0] as List<Note>,
      results[1] as List<Task>,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final search = ref.watch(searchServiceProvider);
    final controller = TextEditingController(text: _query);
    return Container(
      color: sidebarBackground(context),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: l10n.searchHint,
            ),
            onChanged: (v) {
              setState(() => _query = v);
              widget.onQueryChanged?.call(v);
            },
          ),
          const SizedBox(height: 12),
          if (_query.trim().isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(l10n.searchHint, style: mutedStyle(context)),
            )
          else
            Expanded(
              child: FutureBuilder<(List<Note>, List<Task>)>(
                future: _runSearch(search, _query),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const SizedBox.shrink();
                  }
                  final (notes, tasks) = snapshot.data!;
                  if (notes.isEmpty && tasks.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(l10n.noResults, style: mutedStyle(context)),
                    );
                  }
                  return ListView(
                    children: [
                      for (final note in notes)
                        ListTile(
                          title: Text(note.title ?? l10n.untitled),
                          subtitle: Text(
                            note.searchText.split('\n').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => widget.onOpenNote?.call(note.id),
                        ),
                      for (final task in tasks)
                        TaskRow(
                          task: task,
                          onToggle: () async {
                            final tasksService =
                                ref.watch(tasksServiceProvider);
                            await tasksService.setCompleted(
                                task.id, task.completedAt == null);
                            setState(() {});
                          },
                          onOpen: () => widget.onOpenTask?.call(task.id),
                        ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
