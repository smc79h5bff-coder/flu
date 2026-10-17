import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../dir_loader.dart';
import '../providers/file_browser_providers.dart';

/// 浅蓝主色（和对比页风格一致）
const Color _kBlue = Color(0xFF4A90D9);

// 弹窗间距常量
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
    this.pickedPaths = const [],
  });

  final String title;
  final String rootPath;
  final String initialPath;
  final List<String> pickedPaths;

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
  int _loadSeq = 0;

  int _currentTab = 0;
  late final PageController _pageCtrl;

  // ========== Tab 颜色（蓝色系）==========
  static const int _kTabSelectedText = 0xFF4A90D9;
  static const int _kTabSelectedBg = 0xFFE8F1FA;
  static const int _kTabUnselectedText = 0xFF757575;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _jumpCtrl = TextEditingController();
    _filterCtrl = TextEditingController();
    _pageCtrl = PageController(initialPage: 0);
    _load();
  }

  @override
  void dispose() {
    _jumpCtrl.dispose();
    _filterCtrl.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  void _showPickedItems() {
    showDialog<void>(
      context: context,
      builder: (_) => _PickedItemsSheet(
        title: widget.title,
        paths: widget.pickedPaths,
      ),
    );
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() => _loading = true);
    try {
      final dirs = await listSubdirectoriesSafe(_path);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _dirs = dirs;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || seq != _loadSeq) return;
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
    if (!parent.startsWith(widget.rootPath)) return;
    setState(() {
      _path = parent;
      _filterCtrl.clear();
      _filterQuery = '';
    });
    _load();
  }

  void _jumpToPath(String path) {
    if (path.isEmpty) return;
    var target = _normalizePath(path.trim());
    if (FileSystemEntity.typeSync(target) == FileSystemEntityType.file) {
      target = File(target).parent.path;
    }
    if (!Directory(target).existsSync()) {
      _snack('目录不存在');
      return;
    }
    if (!target.startsWith(widget.rootPath)) {
      _snack('只能跳到内部存储以内');
      return;
    }
    setState(() {
      _path = target;
      _jumpCtrl.clear();
      _filterCtrl.clear();
      _filterQuery = '';
    });
    _load();
  }

  String _normalizePath(String path) {
    const prefixes = <String, String>{
      '/sdcard/': '/storage/emulated/0/',
      '/sdcard': '/storage/emulated/0',
      '/mnt/sdcard/': '/storage/emulated/0/',
      '/mnt/sdcard': '/storage/emulated/0',
      '/storage/self/primary/': '/storage/emulated/0/',
      '/storage/self/primary': '/storage/emulated/0',
      '/storage/emulated/legacy/': '/storage/emulated/0/',
      '/storage/emulated/legacy': '/storage/emulated/0',
    };
    for (final e in prefixes.entries) {
      if (path.startsWith(e.key)) {
        return e.value + path.substring(e.key.length);
      }
    }
    return path;
  }

  void _selectShortcut(String path) {
    if (!Directory(path).existsSync()) {
      _handleShortcutMissing(path);
      return;
    }
    if (path == _path) {
      _snack('已经在这个目录了');
      return;
    }
    setState(() {
      _path = path;
      _filterCtrl.clear();
      _filterQuery = '';
    });
    _load();
  }

  Future<void> _handleShortcutMissing(String path) async {
    final isFav = ref.read(favoritesProvider).contains(path);
    final isRecent = ref.read(recentMoveTargetsProvider).contains(path);

    final kinds = <String>[];
    if (isFav) kinds.add('收藏');
    if (isRecent) kinds.add('最近记录');
    final kindLabel = kinds.isEmpty ? '记录' : kinds.join(' / ');

    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _inset,
        title: const Text('目录打不开'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('无法访问：', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              SelectableText(
                path,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '可能原因：\n'
                '· 目录已被删除或重命名\n'
                '· 存储卡已拔出\n'
                '· 文件访问权限被收回',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 12),
              Text(
                '这条$kindLabel要保留吗？',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: _kBlue),
            onPressed: () => Navigator.pop(c),
            child: const Text('保留'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, 'remove'),
            child: const Text('移除'),
          ),
        ],
      ),
    );

    if (action != 'remove' || !mounted) return;

    if (isFav) ref.read(favoritesProvider.notifier).remove(path);
    if (isRecent) ref.read(recentMoveTargetsProvider.notifier).remove(path);
    _snack('已移除');
  }

  String? get _invalidReason {
    for (final p in widget.pickedPaths) {
      final name = p.split('/').last;
      if (_path == p) {
        return '目标就是「$name」本身，无法移动或复制。';
      }
      if (_path.startsWith('$p/')) {
        return '不能把「$name」移进它自己的子目录里。\n\n'
            '这会让文件夹被无限复制，或者直接失败。\n'
            '请换一个目标目录。';
      }
    }
    return null;
  }

  Future<bool> _checkAndWarnInvalid() async {
    final reason = _invalidReason;
    if (reason == null) return true;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _inset,
        title: const Text('不能选择此目录'),
        content: Text(reason),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kBlue),
            onPressed: () => Navigator.pop(c),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return false;
  }

  Future<void> _createNewFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _inset,
        title: const Text('新建文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          cursorColor: _kBlue,
          decoration: const InputDecoration(
            hintText: '文件夹名',
            border: OutlineInputBorder(),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: _kBlue, width: 2),
            ),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: _kBlue),
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kBlue),
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;

    final trimmed = name.trim();
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      _snack('名称不能包含斜杠');
      return;
    }
    if (trimmed == '.' || trimmed == '..') {
      _snack('名称无效');
      return;
    }

    final path = '$_path/$trimmed';
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      _snack('同名文件或文件夹已存在');
      return;
    }

    try {
      await Directory(path).create();
      if (!mounted) return;
      setState(() {
        _path = path;
        _filterCtrl.clear();
        _filterQuery = '';
      });
      _load();
      _snack('已创建并进入「$trimmed」');
    } catch (e) {
      _snack('创建失败：$e');
    }
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
      var rel = fullPath.substring(widget.rootPath.length);
      if (rel.startsWith('/emulated/')) {
        rel = rel.substring('/emulated'.length);
      } else if (rel == '/emulated') {
        rel = '/';
      }
      return rel;
    }
    return fullPath;
  }

  List<({String label, String path})> _buildCrumbs() {
    final out = <({String label, String path})>[
      (label: '/', path: widget.rootPath),
    ];
    if (!_path.startsWith('${widget.rootPath}/')) return out;

    final rel = _path.substring(widget.rootPath.length);
    final segs = rel.split('/').where((s) => s.isNotEmpty).toList();
    var acc = widget.rootPath;
    for (final seg in segs) {
      acc = '$acc/$seg';
      if (seg == 'emulated') continue;
      out.add((label: seg, path: acc));
    }
    return out;
  }

  Widget _crumb(({String label, String path}) c, {required bool isLast}) {
    return GestureDetector(
      onTap: isLast ? null : () => _selectShortcut(c.path),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text(
          c.label,
          style: TextStyle(
            fontSize: 12,
            color: isLast ? _kBlue : Colors.black87,
            fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // ==================== 顶栏（替代 AppBar）====================

  Widget _buildTopBar(BuildContext context) {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: Color(0xFFF0F5FA),
        border: Border(
          bottom: BorderSide(color: Color(0xFFDCE6F0), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            color: Colors.black87,
            tooltip: '取消',
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Text(
              widget.title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
          if (widget.pickedPaths.isNotEmpty)
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: _kBlue),
              icon: const Icon(Icons.content_paste, size: 18),
              label: Text('${widget.pickedPaths.length}'),
              onPressed: _showPickedItems,
            ),
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            color: _kBlue,
            tooltip: '新建文件夹',
            onPressed: _createNewFolder,
          ),
        ],
      ),
    );
  }

  // ==================== build ====================

  @override
  Widget build(BuildContext context) {
    final crumbs = _buildCrumbs();
    final screenH = MediaQuery.of(context).size.height;

    return PopScope(
      canPop: !_canGoUp,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_canGoUp) _goUp();
      },
      child: Dialog(
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ui.BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: SizedBox(
              height: screenH * 0.88,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.5),
                    width: 0.5,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Column(
                    children: [
                      _buildTopBar(context),

                      // 路径跳转行
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _jumpCtrl,
                                cursorColor: _kBlue,
                                decoration: const InputDecoration(
                                  hintText: '粘贴路径跳转',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                  focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(
                                      color: _kBlue,
                                      width: 2,
                                    ),
                                  ),
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 8),
                                ),
                                onSubmitted: (v) =>
                                    _jumpToPath(v.trim()),
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              icon: const Icon(Icons.arrow_forward),
                              color: _kBlue,
                              tooltip: '跳转',
                              onPressed: () =>
                                  _jumpToPath(_jumpCtrl.text.trim()),
                            ),
                          ],
                        ),
                      ),

                      // 面包屑
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_upward),
                              color: _kBlue,
                              onPressed: _canGoUp ? _goUp : null,
                              tooltip: '上一级',
                              visualDensity: VisualDensity.compact,
                            ),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (var i = 0;
                                        i < crumbs.length;
                                        i++) ...[
                                      if (i > 0)
                                        Icon(
                                          Icons.chevron_right,
                                          size: 14,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .outline,
                                        ),
                                      _crumb(
                                        crumbs[i],
                                        isLast:
                                            i == crumbs.length - 1,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),

                      // 主体：左栏 + 右栏
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(flex: 6, child: _buildLeftPane()),
                            Container(
                              width: 1,
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant,
                            ),
                            Expanded(flex: 4, child: _buildRightPane()),
                          ],
                        ),
                      ),
                      const Divider(height: 1),

                      // 底部按钮
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                style: TextButton.styleFrom(
                                    foregroundColor: _kBlue),
                                onPressed: () =>
                                    Navigator.pop(context),
                                child: const Text('取消'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                    backgroundColor: _kBlue),
                                onPressed: () async {
                                  final ok =
                                      await _checkAndWarnInvalid();
                                  if (!ok || !mounted) return;
                                  Navigator.pop(context, _path);
                                },
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
          ),
        ),
      ),
    );
  }

  // ==================== 左右栏 ====================

  Widget _buildLeftPane() {
    final filtered = _filteredDirs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
          child: TextField(
            controller: _filterCtrl,
            cursorColor: _kBlue,
            cursorHeight: 14,
            decoration: const InputDecoration(
              hintText: '过滤子目录',
              prefixIcon: Icon(Icons.search, size: 14, color: _kBlue),
              prefixIconConstraints: BoxConstraints(
                minWidth: 28,
                minHeight: 0,
              ),
              isDense: true,
              border: OutlineInputBorder(),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: _kBlue, width: 2),
              ),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 2, vertical: 2),
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
                              leading: const Icon(
                                Icons.folder,
                                color: _kBlue,
                              ),
                              title: Text(
                                name,
                                softWrap: true,
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                ),
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
          padding: const EdgeInsets.fromLTRB(12, 1, 4, 1),
          child: Row(
            children: [
              Text(
                '收藏当前',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const Spacer(),
              IconButton(
                icon: Icon(
                  isFav ? Icons.star : Icons.star_border,
                  color: isFav ? const Color(0xFFFFB800) : null,
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
        _buildTabRow(),
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
              : PageView(
                  controller: _pageCtrl,
                  onPageChanged: (i) =>
                      setState(() => _currentTab = i),
                  children: [
                    _buildAllPage(favorites, recents),
                    _buildFavoritesPage(favorites),
                    _buildRecentsPage(recents),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildTabRow() {
    const labels = ['全部', '收藏', '最近'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_currentTab == i) return;
                  _pageCtrl.animateToPage(
                    i,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                  );
                },
                child: Container(
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _currentTab == i
                        ? const Color(_kTabSelectedBg)
                        : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: _currentTab == i
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: _currentTab == i
                          ? const Color(_kTabSelectedText)
                          : const Color(_kTabUnselectedText),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAllPage(List<String> favorites, List<String> recents) {
    return Column(
      children: [
        Expanded(
          flex: 7,
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: favorites.length,
            itemBuilder: (ctx, i) => _shortcutTile(
              favorites[favorites.length - 1 - i],
              isFavorite: true,
            ),
          ),
        ),
        Expanded(
          flex: 3,
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: recents.length,
            itemBuilder: (ctx, i) =>
                _shortcutTile(recents[i], isFavorite: false),
          ),
        ),
      ],
    );
  }

  Widget _buildFavoritesPage(List<String> favorites) {
    if (favorites.isEmpty) {
      return const Center(
        child: Text(
          '还没有收藏',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: favorites.length,
      itemBuilder: (ctx, i) =>
          _shortcutTile(favorites[i], isFavorite: true),
    );
  }

  Widget _buildRecentsPage(List<String> recents) {
    if (recents.isEmpty) {
      return const Center(
        child: Text(
          '还没有移动记录',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: recents.length,
      itemBuilder: (ctx, i) =>
          _shortcutTile(recents[i], isFavorite: false),
    );
  }

  Widget _shortcutTile(String path, {required bool isFavorite}) {
    final relPath = _relPath(path);

    return ListTile(
      dense: true,
      minVerticalPadding: 1,
      horizontalTitleGap: 1,
      minLeadingWidth: 0,
      contentPadding: const EdgeInsets.symmetric(horizontal: 1),
      leading: Icon(
        isFavorite ? Icons.star : Icons.history,
        size: 14,
        color: isFavorite ? Colors.amber : null,
      ),
      title: Text(
        relPath,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
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
                Text(relPath),
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
                style: TextButton.styleFrom(foregroundColor: _kBlue),
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _kBlue),
                onPressed: () => Navigator.pop(c, true),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;

        if (isFavorite) {
          ref.read(favoritesProvider.notifier).remove(path);
          _snack('已取消收藏');
        } else {
          ref.read(recentMoveTargetsProvider.notifier).remove(path);
          _snack('已从最近移除');
        }
      },
    );
  }
}

// ==================== 要移动/复制的项目清单 ====================

typedef _ItemStat = ({int bytes, int fileCount, bool truncated});

class _PickedItemsSheet extends StatefulWidget {
  const _PickedItemsSheet({required this.title, required this.paths});
  final String title;
  final List<String> paths;

  @override
  State<_PickedItemsSheet> createState() => _PickedItemsSheetState();
}

class _PickedItemsSheetState extends State<_PickedItemsSheet> {
  static const int _limit = 2000;

  final Map<String, _ItemStat> _stats = {};
  final Map<String, bool> _isDir = {};
  bool _showPath = true;
  int _pathMode = 1;

  String get _verb {
    if (widget.title.contains('移动')) return '移动';
    if (widget.title.contains('复制')) return '复制';
    return '处理';
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    for (final p in widget.paths) {
      if (!mounted) return;
      try {
        if (!Directory(p).existsSync()) {
          _isDir[p] = false;
          final st = File(p).statSync();
          _stats[p] = (bytes: st.size, fileCount: 1, truncated: false);
        }
      } catch (_) {
        _isDir[p] = false;
        _stats[p] = (bytes: 0, fileCount: 0, truncated: true);
      }
    }
    if (mounted) setState(() {});

    for (final p in widget.paths) {
      if (!mounted) return;
      if (_stats.containsKey(p)) continue;
      try {
        if (Directory(p).existsSync()) {
          _isDir[p] = true;
          if (mounted) setState(() {});
          final r = await _scanDir(p);
          if (!mounted) return;
          _stats[p] = r;
        }
      } catch (_) {
        _stats[p] = (bytes: 0, fileCount: 0, truncated: true);
      }
      if (mounted) setState(() {});
    }
  }

  Future<_ItemStat> _scanDir(String rootPath) async {
    var fileCount = 0;
    var dirCount = 0;
    var bytes = 0;
    final stack = <String>[rootPath];
    var lastYield = DateTime.now();
    while (stack.isNotEmpty) {
      if (fileCount + dirCount > _limit) {
        return (bytes: bytes, fileCount: fileCount, truncated: true);
      }
      final p = stack.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = Directory(p).listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final e in entries) {
        if (e is File) {
          fileCount++;
          try {
            bytes += e.statSync().size;
          } catch (_) {}
        } else if (e is Directory) {
          dirCount++;
          stack.add(e.path);
        }
      }
      final now = DateTime.now();
      if (now.difference(lastYield).inMilliseconds > 30) {
        lastYield = now;
        if (mounted) setState(() {});
        await Future<void>.delayed(Duration.zero);
      }
    }
    return (bytes: bytes, fileCount: fileCount, truncated: false);
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _shortenPath(String fullPath) {
    const rootPath = '/storage/emulated/0';
    const topPath = '/storage';

    if (fullPath == rootPath) return '~/';
    if (fullPath.startsWith('$rootPath/')) {
      return '~${fullPath.substring(rootPath.length)}';
    }

    if (fullPath.startsWith('$topPath/emulated/')) {
      final rest = fullPath.substring('$topPath/emulated/'.length);
      final slash = rest.indexOf('/');
      final num = slash < 0 ? rest : rest.substring(0, slash);
      if (RegExp(r'^\d+$').hasMatch(num) && num != '0') {
        final remainder = slash < 0 ? '' : rest.substring(slash);
        return '双开($num)$remainder';
      }
    }

    if (fullPath.startsWith('$topPath/')) {
      final rest = fullPath.substring('$topPath/'.length);
      final slash = rest.indexOf('/');
      final seg = slash < 0 ? rest : rest.substring(0, slash);
      if (RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$').hasMatch(seg)) {
        final remainder = slash < 0 ? '' : rest.substring(slash);
        return '外部存储($seg)$remainder';
      }
    }

    const mntPrefix = '/mnt/media_rw/';
    if (fullPath.startsWith(mntPrefix)) {
      final rest = fullPath.substring(mntPrefix.length);
      final slash = rest.indexOf('/');
      final seg = slash < 0 ? rest : rest.substring(0, slash);
      if (RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$').hasMatch(seg)) {
        final remainder = slash < 0 ? '' : rest.substring(slash);
        return '外部存储($seg)$remainder';
      }
    }

    return fullPath;
  }

  String _applyPathMode(String path) {
    const maxLen = 40;
    if (_pathMode == 0 || path.length <= maxLen) return path;

    if (_pathMode == 1) {
      const head = 20;
      const tail = 17;
      return '${path.substring(0, head)}…${path.substring(path.length - tail)}';
    }
    return '${path.substring(0, maxLen - 1)}…';
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;

    final totalFiles =
        _stats.values.fold<int>(0, (a, e) => a + e.fileCount);
    final totalBytes = _stats.values.fold<int>(0, (a, e) => a + e.bytes);
    final anyTruncated = _stats.values.any((e) => e.truncated);
    final allDone = _stats.length == widget.paths.length;

    String totalStr;
    if (!allDone) {
      totalStr = '正在统计…';
    } else if (anyTruncated) {
      totalStr = '总计约 ${_fmt(totalBytes)}（部分未统计）';
    } else {
      totalStr = '共 $totalFiles 个文件，${_fmt(totalBytes)}';
    }

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.content_paste, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '要${_verb}的 ${widget.paths.length} 项',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  FilterChip(
                    label: const Text(
                      '显示路径',
                      style: TextStyle(fontSize: 12),
                    ),
                    selected: _showPath,
                    onSelected: (v) => setState(() => _showPath = v),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
                  if (_showPath) ...[
                    const SizedBox(width: 8),
                    ActionChip(
                      label: Text(
                        const ['完整', '中间省略', '结尾省略'][_pathMode],
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () => setState(
                        () => _pathMode = (_pathMode + 1) % 3,
                      ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: widget.paths.length,
                itemBuilder: (ctx, i) {
                  final p = widget.paths[i];
                  final name = p.split('/').last;
                  final isDir = _isDir[p] ?? false;
                  final stat = _stats[p];

                  String sizeText;
                  if (stat == null) {
                    sizeText = '计算中…';
                  } else if (stat.truncated) {
                    sizeText = '文件过多，未统计';
                  } else if (isDir) {
                    sizeText = '${stat.fileCount} 个文件，${_fmt(stat.bytes)}';
                  } else {
                    sizeText = _fmt(stat.bytes);
                  }

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              isDir
                                  ? Icons.folder
                                  : Icons.insert_drive_file_outlined,
                              size: 16,
                              color: isDir
                                  ? Colors.black87
                                  : s.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              sizeText,
                              style: TextStyle(
                                fontSize: 12,
                                color: s.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        if (_showPath)
                          Padding(
                            padding:
                                const EdgeInsets.only(left: 22, top: 2),
                            child: Text(
                              _applyPathMode(_shortenPath(p)),
                              style: TextStyle(
                                fontSize: 11,
                                color: s.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                totalStr,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
