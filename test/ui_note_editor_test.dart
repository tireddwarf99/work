/// Редактор заметки: смена noteId не переносит содержимое прежней заметки
/// в новую, а несохранённые правки прежней записываются в неё.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/data/notes_service.dart';
import 'package:notes_app/data/outbox_ledger.dart';
import 'package:notes_app/db/app_database.dart';
import 'package:notes_app/l10n/app_localizations.dart';
import 'package:notes_app/ui/editor/note_editor.dart';
import 'package:notes_app/ui/providers.dart';

String _delta(String text) => jsonEncode({
      'ops': [
        {'insert': '$text\n'},
      ],
    });

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));

  /// Реальное ожидание: запросы drift идут вне FakeAsync тестового виджета.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  Widget app(String noteId) => ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          locale: const Locale('uk'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            FlutterQuillLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: NoteEditor(noteId: noteId)),
        ),
      );

  testWidgets('смена noteId загружает новую заметку и не портит прежнюю',
      (tester) async {
    final notes = NotesService(db, OutboxLedger(db));
    final a = await tester.runAsync(() => notes.create(title: 'A'));
    final b = await tester.runAsync(() => notes.create(title: 'B'));
    await tester.runAsync(() async {
      await notes.saveContent(a!.id, delta: _delta('alpha'), title: 'A');
      await notes.saveContent(b!.id, delta: _delta('beta'), title: 'B');
    });

    await tester.pumpWidget(app(a!.id));
    await settle(tester);
    QuillController current() =>
        tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    expect(current().document.toPlainText(), 'alpha\n');

    // Правка заметки A без ожидания debounce.
    current().replaceText(0, 0, 'X', null);

    // Переключение на B тем же виджетом, без ключа.
    await tester.pumpWidget(app(b!.id));
    await settle(tester);
    await settle(tester);

    expect(current().document.toPlainText(), 'beta\n');

    final savedA = await tester.runAsync(() => notes.get(a.id));
    final savedB = await tester.runAsync(() => notes.get(b.id));
    expect(savedA!.searchText, contains('Xalpha'));
    expect(savedB!.searchText, contains('beta'));
    expect(savedB.searchText, isNot(contains('alpha')));
    expect(savedB.title, 'B');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  });
}

