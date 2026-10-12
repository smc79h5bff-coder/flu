import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 崩溃/异常诊断日志。
///
/// 【开关】
/// 默认关闭。开启后才真正记录。关闭时：
///   · log() / mark() 直接 return，不写盘
///   · 看门狗心跳停止，watchdog 不再写日志
///   · 内存监控 timer 停止
/// 异常钩子（FlutterError.onError / PlatformDispatcher.onError）始终挂着，
/// 但里面检查开关后早退，日常运行（无异常）时开销为零。
class CrashLogger {
  CrashLogger._();
  static final CrashLogger instance = CrashLogger._();

  static const int _maxBytes = 1024 * 1024;
  static const int _keepBytes = 512 * 1024;
  static const int _recentOpsMax = 30;

  File? _file;
  File? _watchdogFile;
  bool _initialized = false;

  /// 开关。默认关。由诊断页控制。
  bool _enabled = false;
  bool get enabled => _enabled;

  final _recentOps = <String>[];

  Timer? _heartbeat;
  SendPort? _watchdogPort;
  final _watchdogRecv = ReceivePort();
  bool _watchdogStarted = false;

  Timer? _memTimer;
  int _lastRss = 0;

  /// 开关切换。
  /// 打开：启动看门狗 + 内存监控，开始记录。
  /// 关闭：停止心跳 + 内存监控，后续 log 不再写盘。
  void setEnabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    if (!_initialized) {
      // 兜底：init 还没跑过。等 init 完成后如果仍是开，就启动。
      init().then((_) {
        if (_enabled) _startAll();
      });
      return;
    }
    if (v) {
      _startAll();
    } else {
      _stopAll();
    }
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/crash_log.txt');
      _watchdogFile = File('${dir.path}/crash_log_watchdog.txt');

      if (await _file!.exists() && await _file!.length() > _maxBytes) {
        final s = await _file!.readAsString();
        await _file!.writeAsString(s.substring(s.length - _keepBytes));
      }
      if (await _watchdogFile!.exists() &&
          await _watchdogFile!.length() > 200 * 1024) {
        await _watchdogFile!.writeAsString('');
      }
    } catch (e) {
      debugPrint('CrashLogger init 失败: $e');
    }

    // 1) Flutter 框架错误
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      prev?.call(details);
      log(
        'FlutterError',
        details.exceptionAsString(),
        details.stack,
        _dumpRecentOps(),
      );
    };

    // 2) 未捕获异步异常
    PlatformDispatcher.instance.onError = (error, stack) {
      log(
        'Uncaught',
        error.toString(),
        stack,
        _dumpRecentOps(),
      );
      return false;
    };

    // 3) isolate 错误
    try {
      Isolate.current.addErrorListener(
        RawReceivePort((pair) {
          final list = pair as List<dynamic>;
          log('Isolate', list[0].toString(), list[1] as StackTrace?);
        }).sendPort,
      );
    } catch (_) {}

    // 不再自动启动 watchdog / memTimer / 写启动信息。
    // 等用户在诊断页打开开关后再启动。
    if (_enabled) _startAll();
  }

  // ==================== 启停 ====================

  void _startAll() {
    _logStartupInfo();
    _startWatchdog();
    _startMemMonitor();
    log('CrashLogger', '开始记录');
  }

  void _stopAll() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _memTimer?.cancel();
    _memTimer = null;
    // 不写"停止记录"（因为已经关了）
  }

  void _logStartupInfo() {
    try {
      final rss = ProcessInfo.currentRss;
      log(
        'Startup',
        '系统=${Platform.operatingSystem} '
        '版本=${Platform.operatingSystemVersion} '
        'CPU核心=${Platform.numberOfProcessors} '
        'locale=${Platform.localeName} '
        '起始RSS=${(rss / 1024 / 1024).toStringAsFixed(1)}MB',
      );
    } catch (_) {}
  }

  /// 记录一条关键操作。进环形缓冲，并且立即写盘。
  /// 用法：CrashLogger.instance.mark('切视图: diffOnly');
  void mark(String op) {
    if (!_enabled) return;
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] [Mark] $op';
    _recentOps.add(line);
    if (_recentOps.length > _recentOpsMax) {
      _recentOps.removeAt(0);
    }
    _writeSync('$line\n---\n');
  }

  String _dumpRecentOps() {
    if (_recentOps.isEmpty) return '（无最近操作）';
    return '【最近操作】\n${_recentOps.join('\n')}';
  }

  void log(String tag, String message, [StackTrace? stack, String? extra]) {
    if (!_enabled) return;
    final ts = DateTime.now().toIso8601String();
    final sb = StringBuffer()..writeln('[$ts] [$tag] $message');
    if (stack != null && stack.toString().trim().isNotEmpty) {
      sb.writeln(stack);
    }
    if (extra != null) {
      sb.writeln(extra);
    }
    sb.writeln('---');
    final line = sb.toString();

    debugPrint(line);
    _writeSync(line);
  }

  // 同步写，保证崩溃前落盘。
  void _writeSync(String line) {
    try {
      _file?.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  // ==================== 看门狗 ====================

  void _startWatchdog() {
    if (_watchdogStarted) {
      // 已启动过，只重启心跳
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _sendHeartbeat(),
      );
      return;
    }
    try {
      if (_watchdogFile == null) return;
      Isolate.spawn(
        _watchdogEntry,
        <dynamic>[_watchdogRecv.sendPort, _watchdogFile!.path],
        onError: _watchdogRecv.sendPort,
        onExit: _watchdogRecv.sendPort,
        errorsAreFatal: false,
      ).then((_) {}, onError: (_) {});

      _watchdogStarted = true;

      _watchdogRecv.listen((msg) {
        if (msg is SendPort) {
          _watchdogPort = msg;
          _heartbeat?.cancel();
          _heartbeat = Timer.periodic(
            const Duration(milliseconds: 500),
            (_) => _sendHeartbeat(),
          );
        }
      });
    } catch (_) {}
  }

  void _sendHeartbeat() {
    if (!_enabled) return;
    final st = WidgetsBinding.instance.lifecycleState;
    if (st == AppLifecycleState.resumed || st == null) {
      _watchdogPort?.send('ping');
    } else {
      _watchdogPort?.send('paused');
    }
  }

  // ==================== 内存监控 ====================

  void _startMemMonitor() {
    _memTimer?.cancel();
    _lastRss = 0;
    _memTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_enabled) return;
      try {
        final rss = ProcessInfo.currentRss;
        final delta = rss - _lastRss;
        final rssMb = rss / 1024 / 1024;
        if (_lastRss == 0 ||
            delta.abs() > 30 * 1024 * 1024 ||
            rssMb > 300) {
          log(
            'Memory',
            'RSS=${rssMb.toStringAsFixed(1)}MB '
            '(${delta >= 0 ? "+" : ""}${(delta / 1024 / 1024).toStringAsFixed(1)}MB)',
          );
        }
        _lastRss = rss;
      } catch (_) {}
    });
  }

  // ==================== 读 / 清 ====================

  Future<String> read() async {
    final buf = StringBuffer();
    if (_file != null && await _file!.exists()) {
      buf.writeln('===== 主日志 =====');
      buf.writeln(await _file!.readAsString());
    } else {
      buf.writeln('（暂无主日志）');
    }
    if (_watchdogFile != null && await _watchdogFile!.exists()) {
      final wd = await _watchdogFile!.readAsString();
      if (wd.trim().isNotEmpty) {
        buf.writeln();
        buf.writeln('===== 看门狗日志（主线程卡顿） =====');
        buf.writeln(wd);
      }
    }
    return buf.toString();
  }

  Future<void> clear() async {
    _recentOps.clear();
    try {
      if (_file != null && await _file!.exists()) {
        await _file!.writeAsString('');
      }
      if (_watchdogFile != null && await _watchdogFile!.exists()) {
        await _watchdogFile!.writeAsString('');
      }
    } catch (_) {}
  }

  String get path => _file?.path ?? '（未初始化）';
}

// ==================== 看门狗 isolate ====================

void _watchdogEntry(List<dynamic> args) async {
  final SendPort mainPort = args[0] as SendPort;
  final String filePath = args[1] as String;

  final recv = ReceivePort();
  mainPort.send(recv.sendPort);

  final file = File(filePath);
  DateTime? lastPing;
  bool alerted = false;

  recv.listen((msg) {
    if (msg == 'ping' || msg == 'paused') {
      lastPing = DateTime.now();
      alerted = false;
    }
  });

  Timer.periodic(const Duration(seconds: 1), (_) {
    if (lastPing == null) return;
    final elapsed = DateTime.now().difference(lastPing!);
    if (elapsed.inSeconds >= 3 && !alerted) {
      alerted = true;
      try {
        file.writeAsStringSync(
          '[${DateTime.now().toIso8601String()}] '
          '主线程疑似卡住 ${elapsed.inSeconds} 秒\n---\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {}
    }
  });
}
