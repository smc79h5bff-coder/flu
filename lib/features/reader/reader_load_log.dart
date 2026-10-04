import 'package:flutter/foundation.dart';

/// 阅读器加载过程的日志缓冲区。
///
/// 全局单例，跨 reader_screen / reader_pagination / reader_scroll_view 共享。
/// 一次加载用 [start] 清空并开始计时，[mark] 记录节点耗时。
/// 用户可以导出全部内容。
class ReaderLoadLog {
  ReaderLoadLog._();
  static final ReaderLoadLog instance = ReaderLoadLog._();

  static const int _maxEntries = 10000;
  final List<String> _entries = [];
  final Stopwatch _sw = Stopwatch();
  int _lastMark = 0;

  List<String> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;

  /// 开始一次新的加载日志。会清空旧内容。
  void start(String label) {
    _entries.clear();
    _sw.reset();
    _sw.start();
    _lastMark = 0;
    _add('══════ $label ══════');
    _add('开始时间：${DateTime.now().toIso8601String()}');
  }

  /// 打一个带耗时的节点。自动计算与上一个 mark 的间隔。
  void mark(String msg) {
    final now = _sw.elapsedMilliseconds;
    _add('[+${now - _lastMark}ms] $msg  (累计 ${now}ms)');
    _lastMark = now;
  }

  /// 不带耗时的补充信息。
  void info(String msg) {
    _add('  └ $msg');
  }

  /// 记录一次加载的结束。
  void end(String label) {
    _add('══════ $label 结束，总计 ${_sw.elapsedMilliseconds}ms ══════');
  }

  void clear() => _entries.clear();

  String dump() => _entries.join('\n');

  int get sizeInBytes => _entries.fold(0, (s, e) => s + e.length + 1);

  void _add(String line) {
    _entries.add(line);
    if (_entries.length > _maxEntries) {
      // 超过上限时丢最旧的 1000 条
      _entries.removeRange(0, 1000);
    }
    if (kDebugMode) debugPrint('[ReaderLoad] $line');
  }
}
