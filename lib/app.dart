import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'features/file_browser/presentation/file_browser_screen.dart';
import 'features/file_browser/presentation/permission_gate.dart';

class DocDiffApp extends ConsumerWidget {
  const DocDiffApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'DocDiff',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,

      // ★ 新增：中文本地化
      // 强制中文。想跟随系统就把 locale 这行删掉。
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('zh', 'TW'),
        Locale('zh', 'HK'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      // 禁用整个 App 的 Hero 机制。
      // 我们没用 Hero，但它在无动画 PageRouteBuilder 下会报 null 错。
      // 包一层 HeroControllerScope.none 让 Hero 控制器直接跳过。
      builder: (context, child) {
        return HeroControllerScope.none(child: child!);
      },

      navigatorObservers: [fileBrowserRouteObserver],
      home: const PermissionGate(child: FileBrowserScreen()),
    );
  }
}
