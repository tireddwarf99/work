/// Стартовый экран «Огляд» (§5): блоки Сьогодні / Наближається термін /
/// Цього тижня / Загальні / Пропущені, быстрое добавление во «Входящие».
///
/// Этап 2: блоки строятся по собственному сроку корневых задач; логика
/// предков и индикаторов внимания — этап 4 (§5 полностью).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../db/app_database.dart';
import '../../domain/due_spec.dart';
import '../../domain/time_rules.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../common/section_card.dart';
import '../common/task_actions.dart';
import '../common/task_row.dart';
import '../common/task_sorting.dart';
import '../editor/task_list_card.dart';
import '../providers.dart';

/// Содержимое блоков dashboard.
class DashboardData {
  final List<Task> overdue;
  final List<Task> today;
  final List<Task> dueSoon;
  final List<Task> week;
  final List<Task> general;

  const DashboardData({
    required this.overdue,
    required this.today,
    required this.dueSoon,
    required this.week,
    required this.general,
  });
}

/// Раскладка корневых невыполненных задач по блокам (§5). Задача попадает
/// во все подходящие блоки, в «Пропущені» — не более одного раза.
DashboardData buildDashboardData(List<Task> roots, tz.TZDateTime now) {
  const window = Duration(hours: 48);
  final todayYmd = ymdOf(now);
  final overdue = <Task>[];
  final today = <Task>[];
  final dueSoon = <Task>[];
  final week = <Task>[];
  final general = <Task>[];
  for (final task in roots) {
    final due = dueSpecFromRow(task);
    if (due.isNone) {
      general.add(task);
      continue;
    }
    if (isOverdue(due, now)) overdue.add(task);
    if (due.date == todayYmd) today.add(task);
    if (isDateInWeekOf(due.date!, now)) week.add(task);
    if (isDueWithin(due, now, window)) dueSoon.add(task);
  }
  tz.TZDateTime deadline(Task t) =>
      dueDeadline(dueSpecFromRow(t), now.location)!;
  // Недавно пропущенные — первыми (§5).
  overdue.sort((a, b) => deadline(b).compareTo(deadline(a)));
  general.sort((a, b) => a.manualOrder.compareTo(b.manualOrder));
  return DashboardData(
    overdue: overdue,
    today: sortTasks(SortMode.due, today),
    dueSoon: sortTasks(SortMode.due, dueSoon),
    week: sortTasks(SortMode.due, week),
    general: general,
  );
}

class DashboardScreen extends ConsumerStatefulWidget {
  final void Function(String taskId)? onOpenTask;

  const DashboardScreen({super.key, this.onOpenTask});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  Map<String, bool> _collapsed = {};
  bool _loaded = false;
  late final Stream<List<Task>> _roots;

  @override
  void initState() {
    super.initState();
    final db = ref.read(appDatabaseProvider);
    _roots = (db.select(db.tasks)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.completedAt.isNull() &
              t.parentId.isNull()))
        .watch();
    _loadCollapsedState();
  }

  /// Состояние сворачивания блоков запоминается локально (§8).
  Future<void> _loadCollapsedState() async {
    final raw = await ref
        .read(settingsServiceProvider)
        .getDevice('dashboard_collapsed');
    if (!mounted) return;
    setState(() {
      _collapsed = raw == null ? {} : _decode(raw);
      _loaded = true;
    });
  }

  Map<String, bool> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded.map((k, v) => MapEntry(k, v == true));
      }
    } on FormatException {
      // повреждённое значение — начинаем с раскрытых блоков
    }
    return {};
  }

  void _toggleCollapsed(String key, bool expanded) {
    setState(() => _collapsed[key] = !expanded);
    ref
        .read(settingsServiceProvider)
        .setDevice('dashboard_collapsed', _collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return StreamBuilder<List<Task>>(
      stream: _roots,
      builder: (context, snapshot) {
        final now = localNow();
        final data = buildDashboardData(snapshot.data ?? const <Task>[], now);
        final dateLabel = DateFormat('EEEE, d MMMM', l10n.localeName)
            .format(DateTime(now.year, now.month, now.day));
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              l10n.dashboard,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(dateLabel, style: mutedStyle(context)),
            const SizedBox(height: 20),
            _block(l10n, key: 'overdue', title: l10n.overdue,
                tasks: data.overdue, allowAdd: false),
            _block(l10n, key: 'today', title: l10n.today, tasks: data.today),
            _block(l10n,
                key: 'dueSoon', title: l10n.dueSoon, tasks: data.dueSoon),
            _block(l10n, key: 'week', title: l10n.thisWeek, tasks: data.week),
            _block(l10n,
                key: 'general', title: l10n.general, tasks: data.general),
          ],
        );
      },
    );
  }

  Widget _block(
    AppLocalizations l10n, {
    required String key,
    required String title,
    required List<Task> tasks,
    bool allowAdd = true,
  }) {
    final service = ref.read(tasksServiceProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SectionCard(
        title: title,
        initiallyExpanded: !(_collapsed[key] ?? false),
        addTooltip: l10n.addTask,
        // Быстрое добавление по умолчанию — во «Входящие» (§5).
        onAdd: allowAdd
            ? () => showQuickAddTask(context, ref, inboxListId)
            : null,
        onExpansionChanged: (expanded) => _toggleCollapsed(key, expanded),
        children: [
          for (final task in tasks)
            TaskRow(
              task: task,
              onToggle: () => toggleTaskCompletion(context, service, task),
              onOpen: () => widget.onOpenTask?.call(task.id),
            ),
        ],
      ),
    );
  }
}
