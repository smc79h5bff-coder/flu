import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// 首次进入时检查“所有文件访问权限”。
/// 已授权：直接显示 [child]。
/// 未授权：显示引导页，用户点“去设置”跳系统设置，回来时自动重查。
///
/// Android 11+ 需要 MANAGE_EXTERNAL_STORAGE（所有文件访问）。
/// Android 10 及以下用传统 READ/WRITE_EXTERNAL_STORAGE。
/// 两个都检查，哪个通过都放行。
class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key, required this.child});

  final Widget child;

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate>
    with WidgetsBindingObserver {
  /// null = 还在检查；true = 有权限；false = 无权限。
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户从系统设置返回 App 时重新检查。
    if (state == AppLifecycleState.resumed) {
      _check();
    }
  }

  Future<void> _check() async {
    final manage = await Permission.manageExternalStorage.status;
    if (manage.isGranted) {
      if (mounted) setState(() => _granted = true);
      return;
    }
    final storage = await Permission.storage.status;
    if (mounted) setState(() => _granted = storage.isGranted);
  }

  Future<void> _request() async {
    // Android 11+ 会直接跳“所有文件访问”设置页；Android 10- 弹系统权限框。
    await Permission.manageExternalStorage.request();
    await Permission.storage.request();
    if (!mounted) return;
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    if (_granted == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_granted!) return widget.child;
    return _PermissionRequestScreen(onRequest: _request);
  }
}

class _PermissionRequestScreen extends StatelessWidget {
  const _PermissionRequestScreen({required this.onRequest});

  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('需要文件访问权限')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 20),
            Icon(Icons.folder_open, size: 72, color: s.primary),
            const SizedBox(height: 20),
            Text(
              'DocDiff 需要“所有文件访问权限”才能：',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            const _Bullet('浏览你的文件'),
            const _Bullet('搜索同名文件'),
            const _Bullet('对比两个文件'),
            const _Bullet('删除 / 移动 / 重命名'),
            const SizedBox(height: 24),
            Text(
              'Android 11 及以上：\n'
              '点击下方按钮后，选择“所有文件访问权限”，允许 DocDiff 访问。\n\n'
              'Android 10 及以下：\n'
              '点击下方按钮后，在系统弹框中点“允许”。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: onRequest,
              icon: const Icon(Icons.settings),
              label: const Text('去授权'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                await openAppSettings();
              },
              child: const Text('打开应用设置'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const Icon(Icons.check, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
