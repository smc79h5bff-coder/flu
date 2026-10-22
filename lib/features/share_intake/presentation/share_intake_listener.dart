import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';
import '../../viewer/presentation/diff_viewer_screen.dart';
import '../application/share_intake_service.dart';

/// 挂在 MaterialApp 的 home 外层、权限门之前。
///
/// 从其他 App 分享两个文本文件过来时，直接填好 providers 并进入对比页 ——
/// 分享的文件在 App 缓存里，不需要"所有文件访问权限"，所以不能被 PermissionGate 挡住。
class ShareIntakeListener extends ConsumerStatefulWidget {
  const ShareIntakeListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ShareIntakeListener> createState() =>
      _ShareIntakeListenerState();
}

class _ShareIntakeListenerState extends ConsumerState<ShareIntakeListener> {
  @override
  void initState() {
    super.initState();
    // 等第一帧结束，Navigator 就绪后再接管分享。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ShareIntakeCoordinator.instance.start(
        onReady: _openCompare,
        onRejected: _showRejected,
      );
    });
  }

  Future<void> _openCompare(ShareIntakePayload payload) async {
    if (!mounted) return;

    final rev = ref.read(importRevisionProvider.notifier);
    ref.read(originalRawTextProvider.notifier).state = payload.leftText;
    ref.read(modifiedRawTextProvider.notifier).state = payload.rightText;
    ref.read(originalFileNameProvider.notifier).state = payload.leftName;
    ref.read(modifiedFileNameProvider.notifier).state = payload.rightName;
    ref.read(originalEncodingProvider.notifier).state = payload.leftEncoding;
    ref.read(modifiedEncodingProvider.notifier).state = payload.rightEncoding;

    // 关键：路径保持 null —— 对比页据此禁用"删除文件"。
    ref.read(originalFilePathProvider.notifier).state = null;
    ref.read(modifiedFilePathProvider.notifier).state = null;
    // 仅用于信息弹窗展示大小/时间和"来自分享"标记。
    ref.read(originalSharedTempPathProvider.notifier).state =
        payload.leftTempPath;
    ref.read(modifiedSharedTempPathProvider.notifier).state =
        payload.rightTempPath;

    ref.read(editedOriginalProvider.notifier).state = null;
    ref.read(editedModifiedProvider.notifier).state = null;
    rev.state++;

    final navigator = Navigator.of(context, rootNavigator: true);
    // 不能 await 这个 push：协调器要立刻恢复空闲，否则用户在看对比页的整段时间里
    // 都无法再接收新的分享。清理逻辑放到 then 里。
    unawaited(
      navigator
          .push(
            MaterialPageRoute<void>(builder: (_) => const DiffViewerScreen()),
          )
          .then((_) => _afterCompareClosed(payload.sessionDir)),
    );
  }

  Future<void> _afterCompareClosed(String sessionDir) async {
    // 对比页关闭后删掉本次分享的临时文件。
    await ShareIntakeCoordinator.cleanupSession(sessionDir);
    if (!mounted) return;
    ref.read(originalSharedTempPathProvider.notifier).state = null;
    ref.read(modifiedSharedTempPathProvider.notifier).state = null;
  }

  bool _rejectDialogOpen = false;

  Future<void> _showRejected(String message) async {
    if (!mounted || _rejectDialogOpen) return;
    _rejectDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('无法开始对比'),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } finally {
      _rejectDialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
