/// Drag-and-drop по платформам (§4): Windows — перетаскивание мышью,
/// Android — долгое нажатие и перетаскивание.
library;

import 'dart:io';

import 'package:flutter/material.dart';

/// Обёртка: на десктопе тянется сразу, на мобильных — по долгому нажатию.
class PlatformDraggable<T extends Object> extends StatelessWidget {
  final T data;
  final Widget child;
  final Widget feedback;
  final void Function()? onDragStarted;

  const PlatformDraggable({
    super.key,
    required this.data,
    required this.child,
    required this.feedback,
    this.onDragStarted,
  });

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    if (_isMobile) {
      return LongPressDraggable<T>(
        data: data,
        feedback: feedback,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: onDragStarted,
        childWhenDragging: Opacity(opacity: 0.4, child: child),
        child: child,
      );
    }
    return Draggable<T>(
      data: data,
      feedback: feedback,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: onDragStarted,
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    );
  }
}

/// Сниппет перетаскиваемой строки задачи/заметки.
Widget dragFeedbackCard(BuildContext context, Widget child) {
  return Material(
    elevation: 4,
    borderRadius: BorderRadius.circular(10),
    color: Theme.of(context).cardColor,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: child,
    ),
  );
}
