/// Сворачиваемая карточка блока из макетов: шеврон, заголовок, кнопка «+».
library;

import 'package:flutter/material.dart';

import '../app_theme.dart';

class SectionCard extends StatelessWidget {
  final String title;
  final bool initiallyExpanded;
  final VoidCallback? onAdd;
  final String? addTooltip;
  final List<Widget> actions;
  final ValueChanged<bool>? onExpansionChanged;
  final List<Widget> children;
  final EdgeInsets padding;

  const SectionCard({
    super.key,
    required this.title,
    this.initiallyExpanded = true,
    this.onAdd,
    this.addTooltip,
    this.actions = const [],
    this.onExpansionChanged,
    this.children = const [],
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return _CollapsibleCard(
      title: title,
      initiallyExpanded: initiallyExpanded,
      onAdd: onAdd,
      addTooltip: addTooltip,
      actions: actions,
      onExpansionChanged: onExpansionChanged,
      padding: padding,
      children: children,
    );
  }
}

class _CollapsibleCard extends StatefulWidget {
  final String title;
  final bool initiallyExpanded;
  final VoidCallback? onAdd;
  final String? addTooltip;
  final List<Widget> actions;
  final ValueChanged<bool>? onExpansionChanged;
  final List<Widget> children;
  final EdgeInsets padding;

  const _CollapsibleCard({
    required this.title,
    required this.initiallyExpanded,
    required this.onAdd,
    required this.addTooltip,
    required this.actions,
    required this.onExpansionChanged,
    required this.children,
    required this.padding,
  });

  @override
  State<_CollapsibleCard> createState() => _CollapsibleCardState();
}

class _CollapsibleCardState extends State<_CollapsibleCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant _CollapsibleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _expanded = widget.initiallyExpanded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() => _expanded = !_expanded);
              widget.onExpansionChanged?.call(_expanded);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: _expanded ? 0 : -0.25,
                    duration: const Duration(milliseconds: 150),
                    child: const Icon(Icons.expand_more, size: 20),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  ...widget.actions,
                  if (widget.onAdd != null)
                    IconButton(
                      icon: const Icon(Icons.add),
                      color: theme.colorScheme.primary,
                      tooltip: widget.addTooltip,
                      onPressed: widget.onAdd,
                    ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: cardBorder(context)),
          if (_expanded)
            Padding(
              padding: widget.padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.children,
              ),
            ),
        ],
      ),
    );
  }
}
