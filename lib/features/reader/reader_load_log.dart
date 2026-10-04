import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 全局诊断日志缓冲区。
///
/// 单例，跨 main / reader_screen / reader_pagination / reader_scroll_view /
/// file_browser_screen / encoding_detector 共享。
///
/// 三类用途：
///   1. 【加载】一次加载用 [start] 清空并开始计时，[mark] 记录节点耗时。
///   2. 【帧】[recordFrame] 累积超时帧统计（启动时挂 SchedulerBinding）。
///   3. 【IO】[time] 包一段同步代码测耗时。
///
/// 全部日志驻留内存，不写盘；用户点「导出加载日志」时一次性导出。
/// 有总量上限，超了丢最旧。
class ReaderLoadLog {
  ReaderLoadLog._();
  static final ReaderLoadLog instance = ReaderLoadLog._();

  static const int _maxLines = 40000;
  static const int _maxTotalChars = 4 * 1024 * 1024; // 4MB 字符上限

  final List<String> _entries = [];
  int _totalChars = 0;

  /// 加载阶段的计时器（只在 [start] 后有效）。
  final Stopwatch _sw = Stopwatch();
  int _lastMark = 0;

  // ---------------- 帧统计 ----------------

  /// 超时帧（>16.67ms）累计条数。
  int slowFrameCount = 0;

  /// 超过 [frameWarnMs] 的帧，最多保留这么多条明细。
  static const int _maxSlowFrameDetails = 500;
  final List<String> _slowFrameDetails = [];

  /// 帧耗时告警线（毫秒）。超过就记一条明细。
  static const int frameWarnMs = 32;

  /// 全局会话计时器（App 一启动就开始）。
  final Stopwatch _sessionSw = Stopwatch()..start();

  List<String> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;
  int get sizeInBytes => _totalChars;

  // ---------------- 加载阶段 ----------------

  /// 开始一次新的加载日志。会清空旧内容（包括帧明细）。
  void start(String label) {
    _entries.clear();
    _totalChars = 0;
    _sw.reset();
    _sw.start();
    _lastMark = 0;
    _add('══════ $label ══════');
    _add('开始时间：${DateTime.now().toIso8601String()}');
    _add('会话启动至今：${_sessionSw.elapsedMilliseconds}ms');
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

  /// 包一段同步代码，返回耗时（毫秒），并把结果写进日志。
  /// 用于没法在里面插 mark 的短代码块。
  int time(String label, void Function() body) {
    final sw = Stopwatch()..start();
    try {
      body();
    } finally {
      sw.stop();
    }
    final ms = sw.elapsedMilliseconds;
    _add('[${ms}ms] $label');
    return ms;
  }

  // ---------------- 帧监控 ----------------

  /// 注册全局帧回调。main() 里调一次。
  ///
  /// 每帧结束时 Flutter 会回调本方法。>16.67ms 视为卡帧，
  /// >32ms 记一条明细（最多 500 条），并在最后一条明细前面加统计头。
  void installFrameMonitor() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _add('══════ 帧监控已安装 ══════');
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final totalMs = t.totalSpan.inMicroseconds / 1000.0;
      if (totalMs <= 16.67) continue;
      slowFrameCount++;
      if (totalMs >= frameWarnMs &&
          _slowFrameDetails.length < _maxSlowFrameDetails) {
        final buildMs = t.buildDuration.inMicroseconds / 1000.0;
        final rasterMs = t.rasterDuration.inMicroseconds / 1000.0;
        _slowFrameDetails.add(
          '帧 ${_sessionSw.elapsedMilliseconds}ms  '
          '总 ${totalMs.toStringAsFixed(1)}ms  '
          'build ${buildMs.toStringAsFixed(1)}ms  '
          'raster ${rasterMs.toStringAsFixed(1)}ms',
        );
      }
    }
  }

  // ---------------- 异常钩子 ----------------

  /// 装全局未捕获异常钩子。main() 里调一次。
  void installErrorHooks() {
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      _add('❌ FlutterError: ${details.exceptionAsString()}');
      _add('    library=${details.library}  context=${details.context}');
      if (details.stack != null) {
        _add('    栈：${details.stack.toString().split('\n').take(8).join('\n     ')}');
      }
      prev?.call(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      _add('❌ PlatformDispatcher: $error');
      _add('    栈：${stack.toString().split('\n').take(8).join('\n     ')}');
      return true;
    };

    _add('══════ 异常钩子已安装 ══════');
  }

  // ---------------- 导出 ----------------

  void clear() {
    _entries.clear();
    _totalChars = 0;
    _slowFrameDetails.clear();
    slowFrameCount = 0;
  }

  String dump() {
    final buf = StringBuffer();
    buf.writeln('══════ 帧统计 ══════');
    buf.writeln('会话启动至今：${_sessionSw.elapsedMilliseconds}ms');
    buf.writeln('慢帧（>16.67ms）总数：$slowFrameCount');
    buf.writeln('慢帧明细条数：${_slowFrameDetails.length}');
    buf.writeln();
    if (_slowFrameDetails.isNotEmpty) {
      buf.writeln('── 慢帧明细（最多 500 条）──');
      for (final line in _slowFrameDetails) {
        buf.writeln(line);
      }
      buf.writeln();
    }
    buf.writeln('══════ 事件日志 ══════');
    buf.writeln(_entries.join('\n'));
    return buf.toString();
  }

  // ---------------- 内部 ----------------

  void _add(String line) {
    _entries.add(line);
    _totalChars += line.length + 1;
    if (_entries.length > _maxLines || _totalChars > _maxTotalChars) {
      // 丢最旧的 1000 条
      var dropCount = 0;
      while (dropCount < 1000 && _entries.isNotEmpty) {
        final removed = _entries.removeAt(0);
        _totalChars -= removed.length + 1;
        dropCount++;
      }
    }
  }
}
