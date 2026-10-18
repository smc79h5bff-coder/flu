import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import 'crash_trace.dart';

/// 记录「上一次进程异常退出」的原因。
///
/// 背景：系统用 SIGKILL 杀进程（LMK/OOM/ANR）时，App 内任何代码都来不及
/// 执行，所以崩溃日志里是空白。Android 11+ 提供了 ApplicationExitInfo，
/// 系统替每个进程记住死因，下次启动可以查——本类就是“下次启动补记”。
///
/// 用法：在 App 启动时（CrashLogger 打 [Startup] 的地方）调用一次：
///   ExitReasonRecorder.recordLastExit();
///
/// 原生侧需要在 MainActivity.kt 注册 MethodChannel 'docdiff/exit_info'
/// 并实现 getHistoricalProcessExitReasons 查询（见 MainActivity.kt 片段）。
class ExitReasonRecorder {
  ExitReasonRecorder._();

  static const MethodChannel _channel =
      MethodChannel('docdiff/exit_info');

  /// ApplicationExitInfo 的 reason 常量 → 中文说明。
  static const Map<int, String> _reasonNames = {
    0: '正常退出',
    1: '上次崩溃（原生或 Java 异常）',
    2: '上次 ANR（主线程无响应）',
    3: '上次低内存被杀（LMK/OOM）',
    4: '用户手动停止',
    5: '系统升级/包变更被杀',
    6: '用户可见但系统资源不足被杀',
    7: '缓存进程被杀（正常回收）',
    8: '被其他应用请求杀死',
    9: '启动器（桌面）请求杀死',
    10: '应用自身请求退出',
    11: '初始化失败被杀',
    12: '权限不足被杀',
    13: '覆盖安装后旧进程被杀',
    14: '其他原因',
  };

  /// 查询上一次退出记录并写入 CrashTrace（异常退出才写）。
  /// 失败一律静默，绝不影响启动。
  static Future<void> recordLastExit() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final raw = await _channel
            .invokeMethod<Map<Object?, Object?>>('getLastExitInfo');
        if (raw == null) {
          CrashTrace.mark('[ExitInfo] 上次退出记录不存在（首次启动或被清除）');
          return;
        }
        final reason = (raw['reason'] as num?)?.toInt() ?? -1;
        final desc = raw['description'] as String? ?? '';
        final ts = (raw['timestamp'] as num?)?.toInt() ?? 0;
        final time = ts > 0
            ? DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String()
            : '未知时间';

        // 只在异常退出时写痕迹文件；正常退出/缓存回收不写，避免噪音。
        final abnormal = reason == 1 || // 崩溃
            reason == 2 || // ANR
            reason == 3 || // 低内存
            reason == 6 || // 可见但资源不足
            reason == 11 || // 初始化失败
            reason == 14;
        if (abnormal) {
          final name = _reasonNames[reason] ?? '未知原因($reason)';
          CrashTrace.mark('[ExitInfo] 上次进程异常退出: $name'
              '${desc.isEmpty ? '' : ' ($desc)'} 时间=$time');
        }
      }
    } catch (_) {
      // 原生侧没实现 / 版本不支持 / channel 未注册：静默放弃。
    }
  }
}
