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
import '../common/tag_actions.dart';
import '../providers.dart';
import '../queries.dart';
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

/// Реестр позиций embed'ов одного редактора для перехода «к списку в
/// заметке» (§4): block_id → ключ виджета карточки.
class EmbedKeyRegistry {
  final Map<String, GlobalKey> _keys = {};

  GlobalKey keyFor(String blockId) =>
      _keys.putIfAbsent(blockId, GlobalKey.new);

  BuildContext? contextFor(String blockId) => _keys[blockId]?.currentContext;

  void clear() => _keys.clear();
}

/// Документ из строки Delta: хранится `{"ops": [...]}` (его читают FTS и
/// синхронизация); голый список ops принимается как более ранний формат.
Document documentFromDelta(String delta) {
  if (delta.isEmpty) return Document();
  final decoded = jsonDecode(delta);
  final ops = decoded is Map<String, dynamic> ? decoded['ops'] : decoded;
  return Document.fromJson(ops as List<dynamic>);
}

/// Строка Delta для хранения.
String deltaFromDocument(Document document) =>
    jsonEncode({'ops': document.toDelta().toJson()});

/// Экран/панель редактора одной заметки. При смене [noteId] несохранённые
/// правки прежней заметки записываются в неё, затем загружается новая.
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
  StreamSubscription<DocChange>? _changes;
  final _titleController = TextEditingController();
  final _embeds = EmbedKeyRegistry();
  Timer? _debounce;
  bool _dirty = false;
  bool _titleDirty = false;
  bool _saveFailed = false;
  bool _loadFailed = false;

  // Сервисы берутся один раз: dispose сохраняет правки уже без доступа к ref.
  late final NotesService _notes;
  late final TaskListsService _lists;
  late final TagsService _tags;

  @override
  void initState() {
    super.initState();
    _notes = ref.read(notesServiceProvider);
    _lists = ref.read(listsServiceProvider);
    _tags = ref.read(tagsServiceProvider);
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didUpdateWidget(covariant NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.noteId == widget.noteId) return;
    // Правки старой заметки уходят в неё до того, как контроллер заменён.
    _persist(oldWidget.noteId);
    _release();
    _saveFailed = false;
    _loadFailed = false;
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Уход с экрана: сохранить незамедлительно (§4).
    _persist(widget.noteId);
    _titleController.dispose();
    _release();
    super.dispose();
  }

  /// Освобождает документ и связанные с ним подписки и ключи embed'ов.
  void _release() {
    _debounce?.cancel();
    _changes?.cancel();
    _changes = null;
    _controller?.dispose();
    _controller = null;
    _embeds.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _persist(widget.noteId);
    }
  }

  Future<void> _load() async {
    final noteId = widget.noteId;
    try {
      final note = await _notes.get(noteId);
      if (!mounted || noteId != widget.noteId) return;
      final controller = QuillController(
        document: documentFromDelta(note.delta),
        selection: const TextSelection.collapsed(offset: 0),
      );
      // Только изменения текста: перемещение курсора не требует сохранения.
      _changes = controller.document.changes.listen((_) => _markDirty());
      _controller = controller;
      _titleController.text = note.title ?? '';
      setState(() {});
    } catch (e, st) {
      debugPrint('note load failed: $e\n$st');
      if (mounted && noteId == widget.noteId) {
        setState(() => _loadFailed = true);
      }
    }
  }

  void _markDirty() {
    _dirty = true;
    _scheduleSave();
  }

  void _onTitleChanged() {
    _titleDirty = true;
    _scheduleSave();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _persist(widget.noteId);
    });
  }

  /// Локальное сохранение: подтверждение не требует сети (§4). Состояние
  /// документа снимается синхронно, поэтому запись не зависит от того,
  /// что редактор покажет дальше. Ошибка диска видна, пока не пройдёт
  /// следующее сохранение.
  Future<void> _persist(String noteId) async {
    if (!_dirty && !_titleDirty) return;
    final controller = _controller;
    if (controller == null) return;
    _debounce?.cancel();
    final delta = deltaFromDocument(controller.document);
    final title =
        _titleController.text.trim().isEmpty ? null : _titleController.text;
    _dirty = false;
    _titleDirty = false;
    try {
      await _notes.saveContent(noteId, delta: delta, title: title);
      if (mounted && _saveFailed) setState(() => _saveFailed = false);
    } catch (e, st) {
      debugPrint('note save failed: $e\n$st');
      if (!mounted || noteId != widget.noteId) return;
      _dirty = true;
      setState(() => _saveFailed = true);
    }
  }

  /// Вставка встроенного списка задач (кнопка чеклиста в тулбаре).
  Future<void> _insertTaskList() async {
    final controller = _controller;
    if (controller == null) return;
    final blockId = DateTime.now().microsecondsSinceEpoch.toString();
    final list = await _lists.createInNote(widget.noteId, blockId);
    if (!mounted || _controller != controller) return;
    final index = controller.selection.baseOffset;
    final safeIndex = index < 0 ? controller.document.length : index;
    controller.replaceText(
      safeIndex,
      0,
      BlockEmbed(
        kTaskListEmbedType,
        TaskListEmbedData(blockId: blockId, taskListId: list.id).toJson(),
      ),
      const TextSelection.collapsed(offset: 0),
    );
  }

  /// Переход «к списку в заметке»: прокрутка к embed и подсветка (§4).
  void _handlePendingJump() {
    if (!mounted) return;
    final pending = ref.read(pendingEmbedJumpProvider);
    if (pending == null || pending.noteId != widget.noteId) return;
    final target = _embeds.contextFor(pending.blockId);
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 350),
      alignment: 0.15,
    );
    ref.read(embedHighlightProvider.notifier).state = pending.blockId;
    ref.read(pendingEmbedJumpProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_loadFailed) {
      return Center(child: Text(l10n.actionFailed));
    }
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (ref.watch(pendingEmbedJumpProvider)?.noteId == widget.noteId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handlePendingJump());
    }
    return Column(
      children: [
        // Тулбар форматирования из макета: стиль, B, I, H1, H2, чеклист.
        Container(
          decoration: BoxDecoration(
            color: sidebarBackground(context),
            border: Border(bottom: BorderSide(color: cardBorder(context))),
          ),
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
        if (_saveFailed)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                l10n.saveFailed,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          ),
        Expanded(child: _buildBody(context, l10n, controller)),
      ],
    );
  }

  Widget _buildBody(
      BuildContext context, AppLocalizations l10n, QuillController controller) {
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
            decoration: InputDecoration(
              filled: false,
              border: InputBorder.none,
              hintText: l10n.noteTitleHint,
            ),
            maxLines: 1,
          ),
          // Теги-чипы.
          _TagChips(
            tagsAsync: ref.watch(tagsForProvider(
                (kind: EntityKind.note, id: widget.noteId))),
            onAdd: () => pickAndAttachTag(
                context, ref, EntityKind.note, widget.noteId),
            onRemove: _removeTag,
          ),
          const SizedBox(height: 8),
          // Документ.
          QuillEditor.basic(
            controller: controller,
            config: QuillEditorConfig(
              embedBuilders: [
                TaskListEmbedBuilder(
                    registry: _embeds, onOpenTask: _openTask),
              ],
              padding: EdgeInsets.zero,
              placeholder: l10n.noteBodyHint,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _removeTag(String tagId) async {
    final noteId = widget.noteId;
    await _tags.detach(EntityKind.note, noteId, tagId);
    if (mounted) {
      ref.invalidate(tagsForProvider((kind: EntityKind.note, id: noteId)));
    }
  }

  void _openTask(Task task) => widget.onOpenTask?.call(task);
}

/// Строка тегов заметки.
class _TagChips extends StatelessWidget {
  final AsyncValue<List<Tag>> tagsAsync;
  final VoidCallback onAdd;
  final void Function(String tagId) onRemove;

  const _TagChips({
    required this.tagsAsync,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tags = tagsAsync.value ?? const <Tag>[];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 8,
        children: [
          for (final tag in tags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: chipBackground(context),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tag.name,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary),
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
            tooltip: l10n.tagsLabel,
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

/// Построитель embed внутри документа Quill.
class TaskListEmbedBuilder extends EmbedBuilder {
  final EmbedKeyRegistry registry;
  final void Function(Task task) onOpenTask;

  TaskListEmbedBuilder({required this.registry, required this.onOpenTask});

  @override
  String get key => kTaskListEmbedType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final data =
        TaskListEmbedData.fromJson(embedContext.node.value.data as String);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: KeyedSubtree(
        key: registry.keyFor(data.blockId),
        child: TaskListCard(
          listId: data.taskListId,
          blockId: data.blockId,
          onOpenTask: onOpenTask,
        ),
      ),
    );
  }
}
