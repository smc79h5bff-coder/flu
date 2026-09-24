import 'dart:io';

import 'package:flutter/material.dart';

/// 文件浏览器：首页。
///
/// 本轮只做：
///   - 浏览目录
///   - 点文件夹进入
///   - 返回键 / 左上角箭头回到上一级
///
/// 后续会加：搜索、多选、对比、删除/移动/重命名。
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  /// Android 上通用外部存储根路径。多品牌手机都用这个。
  static const String _rootPath = '/storage/emulated/0';

  late String _currentPath;
  List<FileSystemEntity>? _entries;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentPath = _rootPath;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dir = Directory(_currentPath);
      final list = await dir.list(followLinks: false).toList();

      // 过滤隐藏文件/文件夹（以 '.' 开头）。
      list.removeWhere((e) {
        final name = e.path.split('/').last;
        return name.startsWith('.');
      });

      // 排序：文件夹在前，然后按名字（不区分大小写）。
      list.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _enter(Directory dir) {
    setState(() => _currentPath = dir.path);
    _load();
  }

  bool get _canGoUp => _currentPath != _rootPath;

  void _goUp() {
    if (!_canGoUp) return;
    final parent = Directory(_currentPath).parent.path;
    // 不要越过根路径。
    if (parent.length < _rootPath.length) return;
    setState(() => _currentPath = parent);
    _load();
  }

  String get _title {
    if (_currentPath == _rootPath) return '内部存储';
    return _currentPath.split('/').last;
  }

  @override
  Widget build(BuildContext context) {
    // 在根目录时按返回键退出 App；否则回到上一级。
    return PopScope(
      canPop: !_canGoUp,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canGoUp) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title),
          leading: _canGoUp
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _goUp,
                )
              : null,
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: _load,
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text('无法访问目录：\n$_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _load,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final entries = _entries ?? const <FileSystemEntity>[];
    if (entries.isEmpty) {
      return const Center(child: Text('空目录'));
    }

    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (ctx, i) {
        final e = entries[i];
        final name = e.path.split('/').last;
        final isDir = e is Directory;
        return ListTile(
          dense: true,
          leading: Icon(
            isDir ? Icons.folder : Icons.insert_drive_file_outlined,
            color: isDir ? Colors.amber.shade600 : null,
          ),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: isDir ? () => _enter(e) : null,
        );
      },
    );
  }
}
