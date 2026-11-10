/// Ручка изменения ширины областей Windows (§8): перетаскивание мышью
/// с минимально допустимой шириной.
library;

import 'package:flutter/material.dart';

class PanelResizer extends StatefulWidget {
  final double startWidth;
  final ValueChanged<double> onDrag;
  final double minWidth;
  final double maxWidth;

  const PanelResizer({
    super.key,
    required this.startWidth,
    required this.onDrag,
    this.minWidth = 180,
    this.maxWidth = 560,
  });

  @override
  State<PanelResizer> createState() => _PanelResizerState();
}

class _PanelResizerState extends State<PanelResizer> {
  late double _dragStartWidth;
  Offset? _dragStartPosition;

  @override
  void didUpdateWidget(covariant PanelResizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startWidth != widget.startWidth) {
      _dragStartPosition = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (details) {
          _dragStartWidth = widget.startWidth;
          _dragStartPosition = details.globalPosition;
        },
        onHorizontalDragUpdate: (details) {
          final start = _dragStartPosition;
          if (start == null) return;
          final delta = details.globalPosition.dx - start.dx;
          final width = (_dragStartWidth + delta).clamp(
            widget.minWidth,
            widget.maxWidth,
          );
          widget.onDrag(width);
        },
        onHorizontalDragEnd: (_) => _dragStartPosition = null,
        child: const SizedBox(
          width: 6,
          child: MouseRegion(cursor: SystemMouseCursors.resizeColumn),
        ),
      ),
    );
  }
}
