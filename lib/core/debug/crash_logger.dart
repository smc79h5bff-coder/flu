import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 崩溃/异常诊断日志。
///
/// 【开关】默认关闭。关闭时：
///   · 心跳 timer   → cancel
///   · 内存 timer   → cancel
///   · 看门狗 isolate → kill（真的杀掉，不是空转）
///   · log() / mark() → 直接 return，不写盘
///   · 异常钩子（FlutterError.onError / PlatformDispatcher.onError）
///     保持挂着，但内部检查开关后早退。系统不触发异常就没有开销。
class CrashLogger {
  CrashLogger._();
  static final CrashLogger instance = CrashLogger._();

  static const int _maxBytes = 1024 * 1024;
  static const int _keepBytes = 512 * 1024;
  static const int _recentOpsMax = 30;

  File? _file;
  File? _watchdogFile;
  bool _initialized = false;

  bool _enabled = false;
  bool get enabled => _enabled;

  final _recentOps = <String>[];

  Timer? _heartbeat;

  Isolate? _watchdogIsolate;
  ReceivePort? _watchdogRecv;
  SendPort? _watchdogPort;

  /// 是否正在 spawn 看门狗 isolate。
  /// 用来防止"spawn 没完成时用户又点了一次开"导致 spawn 出两个。
  bool _watchdogStarting = false;

  /// 看门狗的"代次号"。每次 _stopAll 都 +1。
  /// 正在 await 的 spawn 完成后，会对比自己记录的代次号和当前的，
  /// 不一致就说明这期间被 stop 过，直接 kill 掉刚 spawn 出来的。
  int _watchdogGeneration = 0;

  Timer? _memTimer;
  int _lastRss = 0;

  // ==================== 开关 ====================

  void setEnabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    if (!_initialized) {
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

  void _startAll() {
    _logStartupInfo();
    _startWatchdog();
    _startMemMonitor();
    log('CrashLogger', '开始记录');
  }

  void _stopAll() {
    // 1) 停心跳
    _heartbeat?.cancel();
    _heartbeat = null;

    // 2) 停内存监控
    _memTimer?.cancel();
    _memTimer = null;

    // 3) 让正在进行的 spawn 作废（关键一步）
    _watchdogGeneration++;
    _watchdogStarting = false;

    // 4) 杀已经跑起来的看门狗 isolate
    _watchdogIsolate?.kill(priority: Isolate.immediate);
    _watchdogIsolate = null;
    _watchdogPort = null;

    // 5) 关掉 receive port
    _watchdogRecv?.close();
    _watchdogRecv = null;
  }

  // ==================== 初始化 ====================

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

    PlatformDispatcher.instance.onError = (error, stack) {
      log(
        'Uncaught',
        error.toString(),
        stack,
        _dumpRecentOps(),
      );
      return false;
    };

    try {
      Isolate.current.addErrorListener(
        RawReceivePort((pair) {
          final list = pair as List<dynamic>;
          log('Isolate', list[0].toString(), list[1] as StackTrace?);
        }).sendPort,
      );
    } catch (_) {}

    if (_enabled) _startAll();
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

  // ==================== 记录 ====================

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

  void _writeSync(String line) {
    try {
      _file?.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  // ==================== 看门狗 ====================

  Future<void> _startWatchdog() async {
    // 已经跑起来了，只重启心跳
    if (_watchdogIsolate != null) {
      _restartHeartbeat();
      return;
    }
    // spawn 正在进行中，别重复 spawn
    if (_watchdogStarting) return;
    if (_watchdogFile == null) return;

    _watchdogStarting = true;
    final gen = ++_watchdogGeneration;
    final recv = ReceivePort();

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _watchdogEntry,
        <dynamic>[recv.sendPort, _watchdogFile!.path],
        onError: recv.sendPort,
        onExit: recv.sendPort,
        errorsAreFatal: false,
      );
    } catch (_) {
      if (gen == _watchdogGeneration) _watchdogStarting = false;
      recv.close();
      return;
    }

    // spawn 期间用户可能按了关闭（或关闭又开启）
    // 代次号变了，或者已经不在 enabled 状态 → 作废这次 spawn
    if (gen != _watchdogGeneration || !_enabled) {
      isolate.kill(priority: Isolate.immediate);
      recv.close();
      return;
    }

    _watchdogIsolate = isolate;
    _watchdogRecv = recv;
    _watchdogStarting = false;

    recv.listen((msg) {
      if (msg is SendPort) {
        _watchdogPort = msg;
        _restartHeartbeat();
      }
    });
  }

  void _restartHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _sendHeartbeat(),
    );
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
