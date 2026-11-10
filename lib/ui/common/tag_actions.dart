/// Привязка тега к заметке/задаче через общий диалог выбора.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/due_spec.dart';
import '../providers.dart';
import '../queries.dart';
import 'dialogs.dart';

/// Показывает выбор тега и привязывает выбранный (или созданный) к сущности.
Future<void> pickAndAttachTag(
  BuildContext context,
  WidgetRef ref,
  EntityKind kind,
  String entityId,
) async {
  final tags = ref.read(tagsServiceProvider);
  final available = await tags.listAll();
  if (!context.mounted) return;
  final choice = await showTagPickerDialog(context, available);
  if (choice == null) return;
  final tagId = choice.tagId ?? (await tags.create(choice.newName!)).id;
  await tags.attach(kind, entityId, tagId);
  if (context.mounted) {
    ref.invalidate(tagsForProvider((kind: kind, id: entityId)));
  }
}
