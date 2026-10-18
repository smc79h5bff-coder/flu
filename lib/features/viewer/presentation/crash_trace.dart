import 'dart:io';

/// 落盘的闪退痕迹。
///
/// 和内存里的 CrashLogger 不同：这里的每一条 mark 都**立刻追加写入文件**，
/// 进程被系统杀掉（ANR / 原生 OOM）后文件仍然在，下次启动能查到
/// 死前最后执行的步骤，用来定位闪退点。
///
/// 文件位置：应用临时目录/docdiff-crash-trace.log
/// 超过 256KB 自动从头重写，避免无限增长。
class CrashTrace {
  CrashTrace._();

  static const int _maxBytes = 256 * 1024;

  static File? _file;
  static bool _broken = false;

  static File? _resolve() {
    if (_broken) return null;
    try {
      return _file ??= File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'docdiff-crash-trace.log');
    } catch (_) {
      _broken = true;
      return null;
    }
  }

  static void mark(String tag) {
    final f = _resolve();
    if (f == null) return;
    final line = '${DateTime.now().toIso8601String()} $tag\n';
    try {
      // 超限就重头写（丢最老的历史，保最新的）
      if (f.lengthSync() > _maxBytes) {
        f.writeAsStringSync(line);
      } else {
        f.writeAsStringSync(line, mode: FileMode.append, flush: true);
      }
    } catch (_) {
      _broken = true; // 写不进就静默放弃，绝不影响主流程
    }
  }

  static Future<String> read() async {
    try {
      final f = _resolve();
      if (f == null || !f.existsSync()) return '（还没有痕迹文件）';
      return f.readAsString();
    } catch (e) {
      return '读取失败: $e';
    }
  }

  static void clear() {
    try {
      _resolve()?.deleteSync();
    } catch (_) {}
  }
}
