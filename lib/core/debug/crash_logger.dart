import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 崩溃/异常诊断日志。
///
/// 捕获：
///   1. Flutter 框架层错误（build/layout/paint）
///   2. 未捕获的异步异常
///   3. isolate 里抛出的错
///   4. 主线程卡顿（独立 isolate 看门狗，≥3 秒记录一次）
///   5. 内存占用（每 10 秒采一次）
///   6. 最近 30 条关键操作（每次 mark 立即写盘）
///   7. 启动环境信息
///
/// 写到 App 文档目录：crash_log.txt + crash_log_watchdog.txt
/// 从"诊断"页可以查看、清空。
class CrashLogger {
  CrashLogger._();
  static final CrashLogger instance = CrashLogger._();

  static const int _maxBytes = 1024 * 1024;
  static const int _keepBytes = 512 * 1024;
  static const int _recentOpsMax = 30;

  File? _file;
  File? _watchdogFile;
  bool _initialized = false;

  final _recentOps = <String>[];

  Timer? _heartbeat;
  SendPort? _watchdogPort;
  final _watchdogRecv = ReceivePort();

  Timer? _memTimer;
  int _lastRss = 0;

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

    // 4) 启动环境
    _logStartupInfo();

    // 5) 看门狗 + 心跳
    _startWatchdog();

    // 6) 内存监控
    _startMemMonitor();

    log('CrashLogger', '初始化完成');
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
    try {
      if (_watchdogFile == null) return;
      Isolate.spawn(
        _watchdogEntry,
        <dynamic>[_watchdogRecv.sendPort, _watchdogFile!.path],
        onError: _watchdogRecv.sendPort,
        onExit: _watchdogRecv.sendPort,
        errorsAreFatal: false,
      ).then((_) {}, onError: (_) {});

      _watchdogRecv.listen((msg) {
        if (msg is SendPort) {
          _watchdogPort = msg;
          _heartbeat = Timer.periodic(
            const Duration(milliseconds: 500),
            (_) {
              // 只有 App 在前台才发心跳。
              // 后台被系统冻结时，主线程本来就不该工作，不算"卡顿"。
              final st = WidgetsBinding.instance.lifecycleState;
              if (st == AppLifecycleState.resumed ||
                  st == null) {
                _watchdogPort?.send('ping');
              } else {
                _watchdogPort?.send('paused');
              }
            },
          );
        }
      });
    } catch (_) {}
  }

  // ==================== 内存监控 ====================

  void _startMemMonitor() {
    _memTimer = Timer.periodic(const Duration(seconds: 10), (_) {
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
    // ping 和 paused 都算"主线程还活着"，重置计时。
    // paused = App 在后台，不算卡顿。
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
