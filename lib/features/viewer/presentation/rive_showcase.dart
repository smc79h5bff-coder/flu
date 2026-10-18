import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rive/rive.dart';

class RiveShowcaseItem {
  const RiveShowcaseItem({
    required this.path,
    this.artboard,
    this.stateMachine,
    this.animation,
    this.fallbackSeconds = 5,
  });

  final String path;
  final String? artboard;
  final String? stateMachine;
  final String? animation;
  final int fallbackSeconds;
}

const kRiveShowcaseItems = <RiveShowcaseItem>[
  RiveShowcaseItem(path: 'assets/rive/28432-53754-loader.riv'),
  RiveShowcaseItem(path: 'assets/rive/8834-16891-orange.riv'),
  RiveShowcaseItem(path: 'assets/rive/24645-46055-interactive-loading-screen.riv'),
  RiveShowcaseItem(path: 'assets/rive/21640-40616-loading.riv'),
  RiveShowcaseItem(path: 'assets/rive/20809-39582-loading-dachshund.riv'),
  RiveShowcaseItem(path: 'assets/rive/11884-22689-loading.riv'),
];

class RiveShowcase extends StatefulWidget {
  const RiveShowcase({
    super.key,
    required this.items,
    required this.onFinished,
  });

  final List<RiveShowcaseItem> items;
  final VoidCallback onFinished;

  @override
  State<RiveShowcase> createState() => _RiveShowcaseState();
}

class _RiveShowcaseState extends State<RiveShowcase> {
  int _index = 0;
  RiveFile? _file;
  RiveAnimationController? _controller;
  Artboard? _artboard;
  Timer? _timer;
  bool _loading = true;
  String? _error;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  @override
  void dispose() {
    _disposeCurrent();
    super.dispose();
  }

  void _disposeCurrent() {
    _timer?.cancel();
    _timer = null;
    // Rive 0.13.x 的 RiveFile 没有公开 dispose()，这里只清引用。
    _controller?.dispose();
    _controller = null;
    _file = null;
    _artboard = null;
  }

  Future<void> _loadCurrent() async {
    _disposeCurrent();
    if (_index >= widget.items.length) {
      _finish();
      return;
    }
    final item = widget.items[_index];
    final myIndex = _index;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final file = await RiveFile.asset(item.path);
      if (!mounted || _index != myIndex || _finishing) return;

      final artboard = item.artboard == null
          ? file.mainArtboard
          : (file.artboardByName(item.artboard!) ?? file.mainArtboard);

      RiveAnimationController? ctrl;
      if (item.stateMachine != null && item.stateMachine!.isNotEmpty) {
        ctrl = StateMachineController.fromArtboard(artboard, item.stateMachine!);
      } else if (item.animation != null && item.animation!.isNotEmpty) {
        ctrl = SimpleAnimation(item.animation!);
      } else if (artboard.animations.isNotEmpty) {
        ctrl = SimpleAnimation(artboard.animations.first.name);
      } else if (artboard.stateMachines.isNotEmpty) {
        ctrl = StateMachineController.fromArtboard(
          artboard,
          artboard.stateMachines.first.name,
        );
      }

      if (ctrl == null) {
        throw '这个文件里没有动画，也没有状态机';
      }

      final nonNullCtrl = ctrl;
      artboard.addController(nonNullCtrl);

      // 0.13.x 的控制器用 isActiveChanged 监听，而不是 addListener。
      nonNullCtrl.isActiveChanged.addListener(() {
        if (!mounted || _finishing) return;
        if (!identical(_controller, nonNullCtrl)) return;
        if (!nonNullCtrl.isActive) _next();
      });

      setState(() {
        _file = file;
        _controller = nonNullCtrl;
        _artboard = artboard;
        _loading = false;
      });
      _startFallback(item.fallbackSeconds);
    } catch (e) {
      if (!mounted || _index != myIndex || _finishing) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
      _startFallback(2);
    }
  }

  void _startFallback(int seconds) {
    _timer?.cancel();
    _timer = Timer(Duration(seconds: seconds), () {
      if (mounted) _next();
    });
  }

  void _next() {
    if (_finishing) return;
    if (_index + 1 >= widget.items.length) {
      _finish();
      return;
    }
    setState(() => _index++);
    _loadCurrent();
  }

  void _prev() {
    if (_finishing || _index == 0) return;
    setState(() => _index--);
    _loadCurrent();
  }

  void _finish() {
    if (_finishing) return;
    _finishing = true;
    _disposeCurrent();
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.items.length;
    final item = total == 0 ? null : widget.items[_index];

    return Scaffold(
      appBar: AppBar(
        title: Text('动画预览 ${_index + 1} / $total'),
        actions: [
          TextButton(onPressed: _finish, child: const Text('跳过全部')),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildStage()),
          _buildFooter(item),
        ],
      ),
    );
  }

  Widget _buildStage() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SelectableText(
            '加载失败：\n$_error\n\n2 秒后自动跳到下一个',
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }
    final artboard = _artboard;
    if (artboard == null) return const SizedBox.shrink();
    return Rive(artboard: artboard, fit: BoxFit.contain);
  }

  Widget _buildFooter(RiveShowcaseItem? item) {
    final total = widget.items.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item != null)
              Text(
                item.path,
                style: Theme.of(context).textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: total == 0 ? 0 : (_index + 1) / total,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _index == 0 ? null : _prev,
                  child: const Text('上一个'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _loadCurrent,
                  child: const Text('重播'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _next,
                  child: const Text('下一个'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _finish,
                  child: const Text('进入对比'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
