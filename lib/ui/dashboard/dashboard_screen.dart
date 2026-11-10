/// Стартовый экран «Огляд» (§5): блоки Сьогодні / Наближається термін /
/// Цього тижня / Загальні / Пропущені, быстрое добавление во «Входящие».
///
/// Этап 2: блоки строятся по собственному сроку корневых задач; логика
/// предков и индикаторов внимания — этап 4 (§5 полностью).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';

import 'package:intl/intl.dart';

import '../../db/app_database.dart';
import '../../domain/due_spec.dart';
import '../../domain/time_rules.dart';
import '../../l10n/app_localizations.dart';
import '../app_theme.dart';
import '../common/section_card.dart';
import '../common/task_actions.dart';
import '../common/task_row.dart';
import '../editor/task_list_card.dart';
import '../providers.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  final void Function(String taskId)? onOpenTask;

  const DashboardScreen({super.key, this.onOpenTask});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  Map<String, bool> _collapsed = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
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
    final now = localNow();
    final dateLabel = DateFormat('EEEE, d MMMM', l10n.localeName)
        .format(DateTime(now.year, now.month, now.day));

    return FutureBuilder<_DashboardData>(
      future: _loadData(),
      builder: (context, snapshot) {
        final data = snapshot.data ?? _DashboardData.empty();
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
            _block(
              context,
              key: 'overdue',
              title: l10n.overdue,
              tasks: data.overdue,
              allowAdd: false,
            ),
            _block(
              context,
              key: 'today',
              title: l10n.today,
              tasks: data.today,
            ),
            _block(
              context,
              key: 'dueSoon',
              title: l10n.dueSoon,
              tasks: data.dueSoon,
            ),
            _block(
              context,
              key: 'week',
              title: l10n.thisWeek,
              tasks: data.week,
            ),
            _block(
              context,
              key: 'general',
              title: l10n.general,
              tasks: data.general,
            ),
          ],
        );
      },
    );
  }

  Widget _block(
    BuildContext context, {
    required String key,
    required String title,
    required List<Task> tasks,
    bool allowAdd = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SectionCard(
        title: title,
        initiallyExpanded: !(_collapsed[key] ?? false),
        onAdd: allowAdd ? () => _quickAdd(context) : null,
        onExpansionChanged: (expanded) => _toggleCollapsed(key, expanded),
        children: [
          for (final task in tasks) _dashboardRow(context, task),
        ],
      ),
    );
  }

  Widget _dashboardRow(BuildContext context, Task task) {
    final tasks = ref.watch(tasksServiceProvider);
    return TaskRow(
      task: task,
      onToggle: () => toggleTaskCompletion(context, tasks, task),
      onOpen: () => widget.onOpenTask?.call(task.id),
    );
  }

  Future<void> _quickAdd(BuildContext context) async {
    // Быстрое добавление по умолчанию — во «Входящие» (§5).
    await showQuickAddTask(context, ref, inboxListId);
    setState(() {});
  }

  Future<_DashboardData> _loadData() async {
    final db = ref.read(appDatabaseProvider);
    final now = localNow();
    final window = const Duration(hours: 48);

    final roots = await (db.select(db.tasks)
          ..where((t) => t.deletedAt.isNull())
          ..where((t) => t.completedAt.isNull())
          ..where((t) => t.parentId.isNull()))
        .get();

    final data = _DashboardData.empty();
    for (final task in roots) {
      final due = dueSpecFromRow(task);
      final overdue = isOverdue(due, now);
      if (overdue) {
        data.overdue.add(task);
      }
      switch (due.kind) {
        case DueKind.none:
          data.general.add(task);
          break;
        case DueKind.date:
          if (isDateInWeekOf(due.date!, now)) data.week.add(task);
          if (_isSameYmd(due.date!, _ymdOf(now))) data.today.add(task);
          if (isDueWithin(due, now, window)) data.dueSoon.add(task);
          break;
        case DueKind.dateTime:
          final deadline = dueDeadline(due, now.location)!;
          if (_isSameYmd(due.date!, _ymdOf(now))) data.today.add(task);
          if (isDateInWeekOf(due.date!, now)) data.week.add(task);
          if (isDueWithin(due, now, window)) data.dueSoon.add(task);
          if (deadline.isBefore(now)) data.overdue.add(task);
          break;
      }
    }

    int byOrder(Task a, Task b) => a.manualOrder.compareTo(b.manualOrder);
    int byDuePriority(Task a, Task b) {
      final da = dueSpecFromRow(a);
      final dbDue = dueSpecFromRow(b);
      final ka = da.isNone ? 0x7FFFFFFFFFFFFFFF : _dueKey(da);
      final kb = dbDue.isNone ? 0x7FFFFFFFFFFFFFFF : _dueKey(dbDue);
      if (ka != kb) return ka.compareTo(kb);
      final p = b.priority.index.compareTo(a.priority.index);
      if (p != 0) return p;
      return a.manualOrder.compareTo(b.manualOrder);
    }

    data.today.sort(byDuePriority);
    data.dueSoon.sort(byDuePriority);
    data.week.sort(byDuePriority);
    data.general.sort(byOrder);
    return data;
  }

  int _dueKey(DueSpec due) {
    final dayIndex = int.parse(due.date!.substring(0, 4)) * 10000 +
        int.parse(due.date!.substring(5, 7)) * 100 +
        int.parse(due.date!.substring(8, 10));
    if (due.hasTime) return dayIndex * 100000 + due.minutes! + 1;
    return (dayIndex + 1) * 100000 + 1;
  }

  bool _isSameYmd(String a, String b) => a == b;

  String _ymdOf(DateTime now) {
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

class _DashboardData {
  final List<Task> overdue = [];
  final List<Task> today = [];
  final List<Task> dueSoon = [];
  final List<Task> week = [];
  final List<Task> general = [];

  static _DashboardData empty() => _DashboardData();
}
