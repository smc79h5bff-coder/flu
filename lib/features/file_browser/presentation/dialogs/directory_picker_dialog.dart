import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../dir_loader.dart';
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

  // ===== 右栏 Tab 状态 =====
  int _currentTab = 0; // 0=全部, 1=收藏, 2=最近
  late final PageController _pageCtrl;

  // ========== Tab 颜色（改颜色改这里）==========
  static const int _kTabSelectedText = 0xFF6F00C7;   // 亮紫字
  static const int _kTabSelectedBg = 0xFFEDECFF;     // 浅紫底
  static const int _kTabUnselectedText = 0xFF757575; // 未选中灰字

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
    setState(() => _loading = true);
    try {
      final dirs = await listSubdirectoriesSafe(_path);
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
      var rel = fullPath.substring(widget.rootPath.length);
      // 隐藏 emulated 前缀
      if (rel.startsWith('/emulated/')) {
        rel = rel.substring('/emulated'.length);
      } else if (rel == '/emulated') {
        rel = '/';
      }
      return rel;
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
            actions: [
              if (widget.pickedPaths.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: TextButton.icon(
                    icon: const Icon(Icons.content_paste, size: 18),
                    label: Text('${widget.pickedPaths.length}'),
                    onPressed: _showPickedItems,
                  ),
                ),
            ],
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
                              leading: Icon(Icons.folder,
                                  color: Colors.amber.shade200),
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
        // ===== 标题栏（原样不动）=====
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
                  color: isFav ? const Color(0xFFACF500) : null,
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

        // ===== Tab 行 =====
        _buildTabRow(),

        // ===== 内容区 =====
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
                  onPageChanged: (i) => setState(() => _currentTab = i),
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

  // ========== Tab 行 ==========
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

  // ========== 全部页：上 70% 收藏 + 下 30% 最近，无标题无分界 ==========
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

  // ========== 收藏页：全高 ==========
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

  // ========== 最近页：全高 ==========
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
      
  minVerticalPadding: 1,        // ← 加这行
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
  int _pathMode = 1; // 0=完整 1=中间省略 2=结尾省略

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
    // 第一遍：所有文件（瞬间完成）
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

    // 第二遍：文件夹异步扫
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

    final totalFiles = _stats.values.fold<int>(0, (a, e) => a + e.fileCount);
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
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                              color: isDir ? Colors.black87 : s.onSurfaceVariant,
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
                            padding: const EdgeInsets.only(left: 22, top: 2),
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
