import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../providers/file_browser_providers.dart';

// 弹窗间距常量（和 file_browser_screen.dart 里那份同名，但本地独立一份）
const EdgeInsets _inset = EdgeInsets.all(4);
const EdgeInsets _titlePad = EdgeInsets.fromLTRB(12, 8, 12, 0);
const EdgeInsets _contentPad = EdgeInsets.fromLTRB(8, 4, 8, 4);
const EdgeInsets _actionsPad = EdgeInsets.fromLTRB(4, 0, 4, 4);

/// 只显示目录的路径选择器。用于"移动到 / 复制到"。
class DirectoryPickerDialog extends ConsumerStatefulWidget {
  const DirectoryPickerDialog({
    super.key,
    required this.title,
    required this.rootPath,
    required this.initialPath,
  });

  final String title;
  final String rootPath;
  final String initialPath;

  @override
  ConsumerState<DirectoryPickerDialog> createState() =>
      _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState
    extends ConsumerState<DirectoryPickerDialog> {
  late String _path;
  late final TextEditingController _jumpCtrl;
  late final TextEditingController _filterCtrl;
  String _filterQuery = '';
  List<Directory> _dirs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _jumpCtrl = TextEditingController();
    _filterCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _jumpCtrl.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final raw = await Directory(_path).list(followLinks: false).toList();
      final dirs = raw.whereType<Directory>().where((d) {
        final name = d.path.split('/').last;
        return !name.startsWith('.');
      }).toList()
        ..sort((a, b) =>
            a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _dirs = dirs;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _dirs = const [];
        _loading = false;
      });
    }
  }

  bool get _canGoUp => _path != widget.rootPath;

  void _goUp() {
    if (!_canGoUp) return;
    final parent = Directory(_path).parent.path;
    if (parent.length < widget.rootPath.length) return;
    setState(() {
      _path = parent;
      _filterCtrl.clear();
      _filterQuery = '';
    });
    _load();
  }

  void _jumpToPath(String path) {
    if (path.isEmpty) return;
    var target = path;
    if (FileSystemEntity.typeSync(target) == FileSystemEntityType.file) {
      target = File(target).parent.path;
    }
    if (!Directory(target).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目录不存在')),
      );
      return;
    }
    if (!target.startsWith(widget.rootPath)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('只能跳到内部存储以内')),
      );
      return;
    }
    setState(() {
      _path = target;
      _filterCtrl.clear();
      _filterQuery = '';
    });
    _load();
  }

  void _selectShortcut(String path) {
    if (!Directory(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目录已不存在，已移除')),
      );
      ref.read(favoritesProvider.notifier).remove(path);
      ref.read(recentMoveTargetsProvider.notifier).remove(path);
      return;
    }
    if (path == _path) return;
    setState(() {
      _path = path;
      _filterCtrl.clear();
      _filterQuery = '';
    });
    _load();
  }

  List<Directory> get _filteredDirs {
    if (_filterQuery.isEmpty) return _dirs;
    final q = _filterQuery.toLowerCase();
    return _dirs.where((d) {
      final name = d.path.split('/').last.toLowerCase();
      return name.contains(q);
    }).toList();
  }

  String _relPath(String fullPath) {
    if (fullPath == widget.rootPath) return '/';
    if (fullPath.startsWith('${widget.rootPath}/')) {
      return fullPath.substring(widget.rootPath.length);
    }
    return fullPath;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoUp,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_canGoUp) _goUp();
      },
      child: Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.title),
            leading: IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消',
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 1, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _jumpCtrl,
                          cursorColor: AppColors.accentPurple,
                          decoration: InputDecoration(
                            hintText: '粘贴路径跳转',
                            isDense: true,
                            border: const OutlineInputBorder(),
                            focusedBorder: const OutlineInputBorder(
                              borderSide: BorderSide(
                                color: AppColors.accentPurple,
                                width: 2,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 8),
                          ),
                          onSubmitted: (v) => _jumpToPath(v.trim()),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        color: AppColors.accentPurple,
                        tooltip: '跳转',
                        onPressed: () => _jumpToPath(_jumpCtrl.text.trim()),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        color: AppColors.accentPurple,
                        onPressed: _canGoUp ? _goUp : null,
                        tooltip: '上一级',
                        visualDensity: VisualDensity.compact,
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            _relPath(_path),
                            style: Theme.of(context).textTheme.labelMedium,
                            maxLines: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(flex: 6, child: _buildLeftPane()),
                      Container(
                        width: 1,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      Expanded(flex: 4, child: _buildRightPane()),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(context, _path),
                          child: const Text('选这个目录'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLeftPane() {
    final filtered = _filteredDirs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
          child: TextField(
            controller: _filterCtrl,
            cursorColor: AppColors.accentPurple,
            cursorHeight: 14,
            decoration: InputDecoration(
              hintText: '过滤子目录',
              prefixIcon: const Icon(Icons.search, size: 14),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 28,
                minHeight: 0,
              ),
              isDense: true,
              border: const OutlineInputBorder(),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(
                  color: AppColors.accentPurple,
                  width: 2,
                ),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            ),
            onChanged: (v) => setState(() => _filterQuery = v),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _dirs.isEmpty
                  ? const Center(child: Text('（无子目录）'))
                  : filtered.isEmpty
                      ? const Center(child: Text('（无匹配）'))
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (ctx, i) {
                            final d = filtered[i];
                            final name = d.path.split('/').last;
                            return ListTile(
                              dense: true,
                              horizontalTitleGap: 2,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8),
                              leading: const Icon(Icons.folder,
                                  color: Colors.amber),
                              title: Text(
                                name,
                                softWrap: true,
                              ),
                              onTap: () {
                                setState(() {
                                  _path = d.path;
                                  _filterCtrl.clear();
                                  _filterQuery = '';
                                });
                                _load();
                              },
                            );
                          },
                        ),
        ),
      ],
    );
  }

  Widget _buildRightPane() {
    final favorites = ref.watch(favoritesProvider);
    final recents = ref.watch(recentMoveTargetsProvider);
    final isFav = favorites.contains(_path);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Text(
                '收藏 / 最近',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const Spacer(),
              IconButton(
                icon: Icon(
                  isFav ? Icons.star : Icons.star_border,
                  color: isFav ? Colors.amber : null,
                  size: 20,
                ),
                tooltip: isFav ? '取消收藏当前目录' : '收藏当前目录',
                onPressed: () {
                  ref.read(favoritesProvider.notifier).toggle(_path);
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: (favorites.isEmpty && recents.isEmpty)
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      '还没有收藏，也没有移动记录',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                )
              : ListView(
                  children: [
                    if (favorites.isNotEmpty) ...[
                      _sectionLabel('收藏'),
                      for (final p in favorites)
                        _shortcutTile(p, isFavorite: true),
                    ],
                    if (recents.isNotEmpty) ...[
                      _sectionLabel('最近'),
                      for (final p in recents)
                        _shortcutTile(p, isFavorite: false),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _shortcutTile(String path, {required bool isFavorite}) {
    final name = path.split('/').last;
    final displayName = path == widget.rootPath ? '/' : name;

    final relPath = _relPath(path);

    return ListTile(
      dense: true,
      horizontalTitleGap: 2,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(
        isFavorite ? Icons.star : Icons.history,
        size: 18,
        color: isFavorite ? Colors.amber : null,
      ),
      title: Text(
        displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        relPath,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        softWrap: true,
      ),
      onTap: () => _selectShortcut(path),

      onLongPress: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            insetPadding: _inset,
            title: Text(isFavorite ? '取消收藏？' : '从最近移除？'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayName),
                const SizedBox(height: 6),
                Text(
                  path,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(c).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;

        if (isFavorite) {
          ref.read(favoritesProvider.notifier).remove(path);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已取消收藏')),
          );
        } else {
          ref.read(recentMoveTargetsProvider.notifier).remove(path);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已从最近移除')),
          );
        }
      },
    );
  }
}
