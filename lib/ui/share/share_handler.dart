/// Android «Поделиться» (§8): принимает текст/URL и предлагает заметку
/// либо задачу во «Входящих» (без выбора папки — «Без папки», §4).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/app_database.dart';
import '../../l10n/app_localizations.dart';
import '../providers.dart';

const MethodChannel _shareChannel =
    MethodChannel('dev.notesapp.notes/share');

/// Подключение приёма «Поделиться»; вызывает [onSharedText] для каждого
/// полученного текста.
void registerShareHandler(void Function(String text) onSharedText) {
  _shareChannel.setMethodCallHandler((call) async {
    if (call.method == 'sharedText' && call.arguments is String) {
      final text = call.arguments as String;
      if (text.trim().isNotEmpty) onSharedText(text);
    }
    return null;
  });
  // Холодный старт: интент пришёл до подключения канала.
  _shareChannel
      .invokeMethod<String>('getPendingSharedText')
      .then((text) {
    if (text != null && text.trim().isNotEmpty) {
      onSharedText(text);
    }
  }).catchError((_) => null);
}

/// Диалог выбора: заметка или задача во «Входящих».
Future<void> showShareTargetDialog(
  BuildContext context,
  WidgetRef ref,
  String text,
) async {
  final l10n = AppLocalizations.of(context)!;
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.appTitle),
      content: Text(
        text,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'note'),
          child: Text(l10n.note),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'task'),
          child: Text(l10n.task),
        ),
      ],
    ),
  );
  if (choice == null) return;

  final notes = ref.watch(notesServiceProvider);
  final tasks = ref.watch(tasksServiceProvider);
  if (choice == 'note') {
    // «Поделиться» без выбора папки ведёт в «Без папки» (§4).
    final note = await notes.create();
    await notes.saveContent(
      note.id,
      delta: '{"ops":[{"insert":${_jsonString(text)}},{"insert":"\\n"}]}',
      title: _firstLine(text),
    );
  } else {
    await tasks.create(inboxListId, text: _firstLine(text));
  }
}

String _firstLine(String text) {
  final line = text.trim().split('\n').first.trim();
  return line.isEmpty ? '…' : line;
}

String _jsonString(String value) {
  final escaped = value
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '');
  return '"$escaped"';
}
