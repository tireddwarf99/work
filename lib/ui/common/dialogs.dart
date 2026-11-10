/// Общие диалоги: ввод строки, подтверждение, выбор тега. Контроллеры
/// принадлежат состоянию диалога и освобождаются вместе с ним.
library;

import 'package:flutter/material.dart';

import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';

/// Диалог ввода строки; возвращает обрезанный непустой текст либо null
/// (отмена или пустой ввод). [allowEmpty] — пустая строка допустима
/// (например, сброс названия списка) и возвращается как ''.
Future<String?> showTextInputDialog(
  BuildContext context, {
  String? title,
  required String hint,
  String initial = '',
  bool allowEmpty = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextInputDialog(
      title: title,
      hint: hint,
      initial: initial,
      allowEmpty: allowEmpty,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  final String? title;
  final String hint;
  final String initial;
  final bool allowEmpty;

  const _TextInputDialog({
    required this.title,
    required this.hint,
    required this.initial,
    required this.allowEmpty,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty && !widget.allowEmpty) return;
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: widget.title == null ? null : Text(widget.title!),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.ok)),
      ],
    );
  }
}

/// Подтверждение действия; true — пользователь согласился.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String message,
  String? title,
  required String confirmLabel,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: title == null ? null : Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Выбор тега: существующий (по чипу) либо новое имя из поля ввода.
typedef TagChoice = ({String? tagId, String? newName});

Future<TagChoice?> showTagPickerDialog(
  BuildContext context,
  List<Tag> available,
) {
  return showDialog<TagChoice>(
    context: context,
    builder: (_) => _TagPickerDialog(available: available),
  );
}

class _TagPickerDialog extends StatefulWidget {
  final List<Tag> available;

  const _TagPickerDialog({required this.available});

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submitName() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (tagId: null, newName: name));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.tagsLabel),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(hintText: l10n.tagNameHint),
            onSubmitted: (_) => _submitName(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (final tag in widget.available)
                ActionChip(
                  label: Text(tag.name),
                  onPressed: () =>
                      Navigator.pop(context, (tagId: tag.id, newName: null)),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submitName, child: Text(l10n.ok)),
      ],
    );
  }
}

/// Короткое сообщение об ошибке действия (без технических деталей в тексте).
void showActionError(BuildContext context, [String? message]) {
  final l10n = AppLocalizations.of(context)!;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message ?? l10n.actionFailed)));
}
