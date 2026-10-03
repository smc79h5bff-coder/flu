import 'package:flutter/material.dart';
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

      navigatorObservers: [fileBrowserRouteObserver],
      home: const PermissionGate(child: FileBrowserScreen()),
    );
  }
}
