/// Редактор заметки (§4): заголовок, теги, Quill-документ, встроенные
/// списки задач. Автосохранение: debounce 500 мс + при уходе/сворачивании;
/// облако в подтверждении сохранения не участвует.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/lists_service.dart';
import '../../data/notes_service.dart';
import '../../data/tags_service.dart';
import '../../domain/due_spec.dart';
import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../providers.dart';
import 'task_list_card.dart';

/// Тип встраиваемого блока списка задач.
const String kTaskListEmbedType = 'task-list';

/// Данные embed: стабильные block_id и task_list_id (§3).
class TaskListEmbedData {
  final String blockId;
  final String taskListId;

  const TaskListEmbedData({required this.blockId, required this.taskListId});

  factory TaskListEmbedData.fromJson(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    return TaskListEmbedData(
      blockId: map['block_id'] as String,
      taskListId: map['task_list_id'] as String,
    );
  }

  String toJson() => jsonEncode({'block_id': blockId, 'task_list_id': taskListId});
}

/// Встраиваемый блок списка задач.
class TaskListBlockEmbed extends CustomBlockEmbed {
  const TaskListBlockEmbed(String data) : super(kTaskListEmbedType, data);

  static TaskListBlockEmbed fromData(TaskListEmbedData data) =>
      TaskListBlockEmbed(data.toJson());
}

/// Реестр позиций embed'ов для перехода «к списку в заметке» (§4):
/// block_id → ключ виджета карточки.
final Map<String, GlobalKey> embedKeys = {};

/// Экран/панель редактора одной заметки.
class NoteEditor extends ConsumerStatefulWidget {
  final String noteId;
  final void Function(Task task)? onOpenTask;

  const NoteEditor({super.key, required this.noteId, this.onOpenTask});

  @override
  ConsumerState<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends ConsumerState<NoteEditor>
    with WidgetsBindingObserver {
  QuillController? _controller;
  final _titleController = TextEditingController();
  Timer? _debounce;
  bool _dirty = false;
  bool _titleDirty = false;
  String? _error;

  NotesService get _notes => ref.read(notesServiceProvider);
  TaskListsService get _lists => ref.read(listsServiceProvider);
  TagsService get _tags => ref.read(tagsServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Уход с экрана: сохранить незамедлительно (§4).
    _flushNow();
    _titleController.dispose();
    _debounce?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _flushNow();
    }
  }

  Future<void> _load() async {
    final note = await _notes.get(widget.noteId);
    if (!mounted) return;
    final doc = note.delta.isEmpty
        ? Document()
        : Document.fromJson(jsonDecode(note.delta) as List<dynamic>);
    _controller = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
    _controller!.addListener(_onDocumentChanged);
    _titleController.text = note.title ?? '';
    setState(() {});
  }

  void _onDocumentChanged() {
    _dirty = true;
    _scheduleSave();
  }

  void _onTitleChanged() {
    _titleDirty = true;
    _scheduleSave();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _flushNow);
  }

  /// Локальное сохранение: подтверждение не требует сети (§4). Ошибка диска
  /// показывается пользователю.
  Future<void> _flushNow() async {
    if (!_dirty && !_titleDirty) return;
    final controller = _controller;
    if (controller == null) return;
    _dirty = false;
    _titleDirty = false;
    try {
      final delta = jsonEncode(controller.document.toDelta().toJson());
      final title =
          _titleController.text.trim().isEmpty ? null : _titleController.text;
      await _notes.saveContent(widget.noteId, delta: delta, title: title);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  /// Вставка встроенного списка задач (кнопка чеклиста в тулбаре).
  Future<void> _insertTaskList() async {
    final controller = _controller;
    if (controller == null) return;
    final blockId = DateTime.now().microsecondsSinceEpoch.toString();
    final list = await _lists.createInNote(widget.noteId, blockId);
    final index = controller.selection.baseOffset;
    final safeIndex = index < 0 ? controller.document.length : index;
    controller.replaceText(
      safeIndex,
      0,
      BlockEmbed(kTaskListEmbedType, TaskListEmbedData(
              blockId: blockId, taskListId: list.id)
          .toJson()),
      const TextSelection.collapsed(offset: 0),
    );
    _dirty = true;
    _scheduleSave();
  }

  Future<void> _addTag() async {
    final l10n = AppLocalizations.of(context)!;
    final available = await _tags.listAll();
    if (!mounted) return;
    final controller = TextEditingController();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: StatefulBuilder(
          builder: (ctx, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: InputDecoration(hintText: l10n.tagsLabel),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final tag in available)
                    ActionChip(
                      label: Text(tag.name),
                      onPressed: () => Navigator.pop(ctx, tag.id),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    final isId = available.any((t) => t.id == picked);
    final tagId =
        isId ? picked : (await _tags.create(picked.trim())).id;
    await _tags.attach(EntityKind.note, widget.noteId, tagId);
    if (mounted) setState(() {});
  }

  /// Переход «к списку в заметке»: прокрутка к embed и подсветка (§4).
  void _handlePendingJump() {
    final pending = ref.read(pendingEmbedJumpProvider);
    if (pending == null || pending.noteId != widget.noteId) return;
    final key = embedKeys[pending.blockId];
    if (key?.currentContext == null) return;
    final highlight = ref.read(embedHighlightProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 350),
        alignment: 0.15,
      );
      highlight.state = pending.blockId;
    });
    ref.read(pendingEmbedJumpProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _handlePendingJump());
    return Column(
      children: [
        // Тулбар форматирования из макета: стиль, B, I, H1, H2, чеклист.
        Container(
          decoration: BoxDecoration(
            color: sidebarBackground(context),
            border: Border(bottom: BorderSide(color: cardBorder(context))),
          ),
          child: Row(
            children: [
              Expanded(
                child: QuillSimpleToolbar(
                  controller: controller,
                  config: QuillSimpleToolbarConfig(
                    showUndo: true,
                    showRedo: true,
                    showBoldButton: true,
                    showItalicButton: true,
                    showUnderLineButton: false,
                    showFontFamily: false,
                    showFontSize: false,
                    showColorButton: false,
                    showBackgroundColorButton: false,
                    showClearFormat: false,
                    showAlignmentButtons: false,
                    showCodeBlock: false,
                    showQuote: false,
                    showLink: true,
                    showListNumbers: true,
                    showListBullets: true,
                    showIndent: false,
                    showSubscript: false,
                    showSuperscript: false,
                    showStrikeThrough: false,
                    showInlineCode: false,
                    showSearchButton: false,
                    showHeaderStyle: true,
                    headerStyleType: HeaderStyleType.buttons,
                    customButtons: [
                      QuillToolbarCustomButtonOptions(
                        icon: const Icon(Icons.checklist),
                        tooltip: l10n.addTask,
                        onPressed: _insertTaskList,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_error != null)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                l10n.notSynced,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          ),
        Expanded(
          child: StreamBuilder<Note>(
            stream: _notes.watchSingle(widget.noteId),
            builder: (context, snapshot) {
              final note = snapshot.data;
              return _buildBody(context, controller, note);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBody(
      BuildContext context, QuillController controller, Note? note) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Заголовок.
          TextField(
            controller: _titleController,
            onChanged: (_) => _onTitleChanged(),
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(fontWeight: FontWeight.w800),
            decoration: const InputDecoration(
              filled: false,
              border: InputBorder.none,
              hintText: ' ',
            ),
            maxLines: 1,
          ),
          // Теги-чипы.
          if (note != null)
            _TagChips(
              tagsFuture: _tags.tagsFor(EntityKind.note, widget.noteId),
              onAdd: _addTag,
              onRemove: (tagId) async {
                await _tags.detach(EntityKind.note, widget.noteId, tagId);
                if (mounted) setState(() {});
              },
            ),
          const SizedBox(height: 8),
          // Документ.
          QuillEditor.basic(
            controller: controller,
            config: QuillEditorConfig(
              embedBuilders: [TaskListEmbedBuilder(onOpenTask: _openTask)],
              padding: EdgeInsets.zero,
              placeholder: '',
            ),
          ),
        ],
      ),
    );
  }

  void _openTask(Task task) {
    final callback = widget.onOpenTask;
    if (callback != null) {
      callback(task);
    }
  }
}

/// Строка тегов заметки.
class _TagChips extends StatelessWidget {
  final Future<List<Tag>> tagsFuture;
  final VoidCallback onAdd;
  final void Function(String tagId) onRemove;

  const _TagChips({
    required this.tagsFuture,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Tag>>(
      future: tagsFuture,
      builder: (context, snapshot) {
        final tags = snapshot.data ?? const <Tag>[];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(
            spacing: 8,
            children: [
              for (final tag in tags)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: chipBackground(context),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        tag.name,
                        style: TextStyle(color: Theme.of(context).colorScheme.primary),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () => onRemove(tag.id),
                        child: Icon(Icons.close,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ActionChip(
                label: const Icon(Icons.add, size: 16),
                onPressed: onAdd,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Построитель embed внутри документа Quill.
class TaskListEmbedBuilder extends EmbedBuilder {
  final void Function(Task task) onOpenTask;

  TaskListEmbedBuilder({required this.onOpenTask});

  @override
  String get key => kTaskListEmbedType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final data =
        TaskListEmbedData.fromJson(embedContext.node.value.data as String);
    final key = embedKeys.putIfAbsent(data.blockId, GlobalKey.new);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: KeyedSubtree(
        key: key,
        child: TaskListCard(
          listId: data.taskListId,
          blockId: data.blockId,
          onOpenTask: onOpenTask,
        ),
      ),
    );
  }
}
