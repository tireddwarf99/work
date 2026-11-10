/// Android «Поделиться» (§8): принимает текст/URL и предлагает заметку
/// либо задачу во «Входящих» (без выбора папки — «Без папки», §4).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../providers.dart';

const MethodChannel _shareChannel = MethodChannel('dev.notesapp.notes/share');

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
  _deliverPendingText(onSharedText);
}

/// Холодный старт: интент пришёл до подключения канала. На платформах без
/// нативной части канала нет — это не ошибка; прочие сбои пишутся в лог.
Future<void> _deliverPendingText(
  void Function(String text) onSharedText,
) async {
  try {
    final text = await _shareChannel.invokeMethod<String>(
      'getPendingSharedText',
    );
    if (text != null && text.trim().isNotEmpty) onSharedText(text);
  } on MissingPluginException {
    // Платформа без приёма «Поделиться».
  } on PlatformException catch (e) {
    debugPrint('share: pending text unavailable: ${e.code} ${e.message}');
  }
}

/// Диалог выбора: заметка или задача во «Входящих».
Future<void> showShareTargetDialog(
  BuildContext context,
  WidgetRef ref,
  String text,
) async {
  final l10n = AppLocalizations.of(context)!;
  final notes = ref.read(notesServiceProvider);
  final tasks = ref.read(tasksServiceProvider);
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.appTitle),
      content: Text(text, maxLines: 4, overflow: TextOverflow.ellipsis),
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

  if (choice == 'note') {
    // «Поделиться» без выбора папки ведёт в «Без папки» (§4).
    final note = await notes.create();
    await notes.saveContent(
      note.id,
      delta: jsonEncode({
        'ops': [
          {'insert': text.endsWith('\n') ? text : '$text\n'},
        ],
      }),
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
