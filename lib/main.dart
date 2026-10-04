import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/storage/shared_preferences_provider.dart';
import 'features/reader/reader_load_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 尽早装异常钩子，后面所有未捕获异常都会被记进日志。
  ReaderLoadLog.instance.installErrorHooks();

  // 装帧监控。App 一启动就开始累积慢帧统计。
  ReaderLoadLog.instance.installFrameMonitor();

  // 记录 SharedPreferences 冷启动耗时（冷启动时可能几百毫秒）。
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
