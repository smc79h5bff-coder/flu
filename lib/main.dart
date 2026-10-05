import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/storage/shared_preferences_provider.dart';
import 'features/reader/reader_load_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ============================================================
  // 日志系统默认关闭（ReaderLoadLog.enabled = false）。
  //
  // 需要排查问题时：
  //   1. 打开 reader_load_log.dart，把 enabled 改成 true
  //   2. 取消下面两行注释
  //   3. 重新编译运行
  //
  // 排查完记得都改回去，避免长期记录影响性能。
  // ============================================================

  // ReaderLoadLog.instance.installErrorHooks();
  // ReaderLoadLog.instance.installFrameMonitor();

  // 记录 SharedPreferences 冷启动耗时（日志关闭时是空操作）。
  final prefsSw = Stopwatch()..start();
  final prefs = await SharedPreferences.getInstance();
  ReaderLoadLog.instance.info(
    'SharedPreferences 加载 ${prefsSw.elapsedMilliseconds}ms',
  );

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const DocDiffApp(),
    ),
  );
}
