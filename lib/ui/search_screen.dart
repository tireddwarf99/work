/// Общий поиск по заметкам и задачам (§4): название/текст, Ctrl+K (Windows).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_database.dart';
import '../l10n/app_localizations.dart';
import 'app_theme.dart';
import 'common/task_actions.dart';
import 'common/task_row.dart';
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
  late final TextEditingController _controller = TextEditingController(
    text: widget.query ?? '',
  );
  Future<(List<Note>, List<Task>)>? _results;

  @override
  void initState() {
    super.initState();
    _results = _search(_controller.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Запрос выполняется один раз на изменение текста или результата действия.
  Future<(List<Note>, List<Task>)>? _search(String query) {
    if (query.trim().isEmpty) return null;
    final search = ref.read(searchServiceProvider);
    return Future.wait<Object?>([search.notes(query), search.tasks(query)])
        .then((r) => (r[0] as List<Note>, r[1] as List<Task>));
  }

  void _onChanged(String value) {
    setState(() => _results = _search(value));
    widget.onQueryChanged?.call(value);
  }

  Future<void> _toggle(Task task) async {
    await toggleTaskCompletion(context, ref.read(tasksServiceProvider), task);
    if (!mounted) return;
    setState(() => _results = _search(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      color: sidebarBackground(context),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: l10n.searchHint,
            ),
            onChanged: _onChanged,
          ),
          const SizedBox(height: 12),
          if (_results == null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(l10n.searchHint, style: mutedStyle(context)),
            )
          else
            Expanded(
              child: FutureBuilder<(List<Note>, List<Task>)>(
                future: _results,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const SizedBox.shrink();
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
                          onToggle: () => _toggle(task),
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
