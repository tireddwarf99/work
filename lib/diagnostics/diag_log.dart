/// Журнал диагностики (кольцевой буфер) для экрана отладки: события
/// входа, обновления токенов и синхронизации с таймстампами.
library;

import 'dart:async';

class DiagLog {
  DiagLog._();
  static final DiagLog instance = DiagLog._();

  static const int _maxEntries = 400;
  final List<String> _entries = [];
  final _controller = StreamController<void>.broadcast();

  /// Событие входа/обновления/синхронизации.
  void add(String message) {
    final now = DateTime.now().toLocal();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    _entries.add('$ts  $message');
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    if (!_controller.isClosed) _controller.add(null);
  }

  List<String> get entries => List.unmodifiable(_entries.reversed);

  Stream<void> get changes => _controller.stream;

  String get asText => _entries.reversed.join('\n');
}

void dlog(String message) => DiagLog.instance.add(message);
