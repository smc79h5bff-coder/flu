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

      // 中文本地化：系统组件（Copy/Paste/Back 等）不再显示英文。
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,

      // 钳制系统字号，防 Diff 行高/工具栏在大字号下溢出。
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.3,
            ),
          ),
          child: child!,
        );
      },

      navigatorObservers: [fileBrowserRouteObserver],
      home: const PermissionGate(child: FileBrowserScreen()),
    );
  }
}
