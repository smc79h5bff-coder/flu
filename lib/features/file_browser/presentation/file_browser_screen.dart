import 'dart:io';
import 'dart:typed_data';
import 'browser_settings_screen.dart';
import '../../../core/constants/app_colors.dart';
import 'line_editor_screen.dart';
import 'dart:convert';
import '../../reader/reader_repository.dart';
import 'package:file_picker/file_picker.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../reader/reader_screen.dart';
import '../../reader/reader_load_log.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'single_file_editor_screen.dart';
import '../../parser/application/document_parser.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../viewer/presentation/diff_viewer_screen.dart';
import 'comparison_settings_screen.dart';
import 'dialogs/directory_picker_dialog.dart';
import 'providers/file_browser_providers.dart';
import 'text_preview_screen.dart';
import 'config_io_service.dart';
import 'dir_loader.dart';

// ==================== 路由观察者 ====================

/// 全局 route observer。
/// 用于 FileBrowserScreen 感知"被 push 盖住 / 从子页返回"的事件，
/// 从而自动释放 TextField 焦点、收键盘。
///
/// 需要在 MaterialApp 里注册：navigatorObservers: [fileBrowserRouteObserver]。
final RouteObserver<PageRoute<dynamic>> fileBrowserRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

// ==================== 导出文件清单 ====================

String _fmtSizeForListing(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String _fmtTimeForListing(DateTime t) {
  String two(int n) => n < 10 ? '0$n' : '$n';
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// 在后台 isolate 里递归扫描文件夹，生成清单文本。
/// 返回 UTF-8 编码的字节，直接可写文件。
Future<Uint8List> _folderListingWorker(String rootPath) async {
  final body = StringBuffer();
  var fileCount = 0;
  var dirCount = 0;
  var emptyDirCount = 0;
  var totalBytes = 0;

  void walk(String dirPath) {
    List<FileSystemEntity> entities;
    try {
      entities = Directory(dirPath).listSync(followLinks: false);
    } catch (_) {
      // 无权限等错误，跳过此目录
      return;
    }

    final files = <File>[];
    final dirs = <Directory>[];
    for (final e in entities) {
      final name = e.path.split('/').last;
      if (name.isEmpty) continue;
      if (e is File) {
        files.add(e);
      } else if (e is Directory) {
        dirs.add(e);
      }
    }

    files.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    dirs.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    if (files.isEmpty && dirs.isEmpty) {
      body.writeln('$dirPath | (空目录) | —');
      emptyDirCount++;
      return;
    }

    for (final f in files) {
      int size = 0;
      DateTime? modified;
      try {
        final st = f.statSync();
        size = st.size;
        modified = st.modified;
      } catch (_) {}
      final sizeStr = _fmtSizeForListing(size);
      final timeStr =
          modified == null ? '—' : _fmtTimeForListing(modified);
      body.writeln('${f.path} | $sizeStr | $timeStr');
      fileCount++;
      totalBytes += size;
    }

    for (final d in dirs) {
      dirCount++;
      walk(d.path);
    }
  }

  walk(rootPath);

  final header = StringBuffer();
  header.writeln(
      '# ============================================================');
  header.writeln('# 文件夹文件清单');
  header.writeln(
      '# ============================================================');
  header.writeln('# 根目录：$rootPath');
  header.writeln('# 导出时间：${_fmtTimeForListing(DateTime.now())}');
  header.writeln('# 总文件数：$fileCount');
  header.writeln('# 总目录数：$dirCount（含空目录 $emptyDirCount）');
  header.writeln('# 总大小：${_fmtSizeForListing(totalBytes)}');
  header.writeln('#');
  header.writeln('# 格式说明：');
  header.writeln('#   每一行：完整路径 | 大小 | 修改时间');
  header.writeln('#   空目录：完整路径 | (空目录) | —');
  header.writeln('#   排序：按目录树顺序');
  header.writeln('#         （当前目录的文件在前，子目录按名称递归）');
  header.writeln(
      '# ============================================================');
  header.writeln();

  final builder = BytesBuilder();
  builder.add(utf8.encode(header.toString()));
  builder.add(utf8.encode(body.toString()));
  return builder.takeBytes();
}

class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _SearchHit {
  _SearchHit({
    required this.path,
    required this.name,
    this.size,
    this.modified,
  });
  final String path;
  final String name;
  final int? size;
  final DateTime? modified;
}

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen>
    with RouteAware {
  static const String _rootPath = '/storage/emulated/0';

  // 弹窗统一参数：几乎铺满屏，间距最小
  static const EdgeInsets _dlgInset = EdgeInsets.all(4);
  static const EdgeInsets _dlgTitlePad =
      EdgeInsets.fromLTRB(12, 8, 12, 0);
  static const EdgeInsets _dlgContentPad = EdgeInsets.fromLTRB(8, 4, 8, 4);
  static const EdgeInsets _dlgActionsPad =
      EdgeInsets.fromLTRB(4, 0, 4, 4);
  static const int _editSizeThreshold = 200 * 1024;   // 200KB

  // ==================== 扩展名 → 图标颜色 ====================

  /// 文本类扩展名（与 TextPreviewScreen 保持一致）。
  static const Set<String> _textExts = {
    '.txt', '.md', '.markdown', '.log', '.lst', '.diz', '.nfo',
    '.json', '.xml', '.yaml', '.yml', '.toml', '.ini', '.conf', '.cfg',
    '.csv', '.tsv',
    '.sh', '.bash', '.zsh', '.bat', '.cmd', '.ps1',
    '.py', '.js', '.ts', '.java', '.kt', '.dart', '.c', '.cpp', '.cc',
    '.h', '.hpp', '.cs', '.go', '.rs', '.rb', '.php', '.lua', '.smali',
    '.html', '.htm', '.css', '.scss',
    '.diff', '.patch',
  };

  /// 已知的非文本扩展名：媒体 / 图片 / 压缩包 / 文档 / 二进制等。
  static const Set<String> _binaryExts = {
    // 视频
    '.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.m4v',
    '.3gp', '.mpg', '.mpeg', '.rmvb', '.rm', '.vob',
    // 音频
    '.mp3', '.flac', '.wav', '.aac', '.ogg', '.m4a', '.wma', '.ape',
    '.opus',
    // 图片
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.ico',
    '.tif', '.tiff', '.heic', '.raw',
    // 压缩包 / 镜像 / 安装包
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso',
    '.cab', '.lz', '.lzma', '.zst', '.apk', '.apks', '.xapk', '.aab',
    // 文档
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.odt', '.ods', '.odp', '.epub', '.mobi', '.azw', '.azw3',
    // 二进制 / 数据库等
    '.exe', '.dll', '.so', '.bin', '.img', '.db', '.sqlite', '.mdb',
  };

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return '';
    return name.substring(i).toLowerCase();
  }

  /// 文本 / 已知非文本 / 未知 → 三种颜色。
  static Color _fileColor(String name) {
    final ext = _extOf(name);
    if (_textExts.contains(ext)) return Colors.blue.shade600;
    if (_binaryExts.contains(ext)) return Colors.orange.shade700;
    return Colors.grey.shade600;
  }

  late String _currentPath;
  List<EntryInfo>? _entries;
  bool _loading = false;
  String? _error;

  /// 目录加载的取消令牌。用户切目录时打断旧的加载。
  LoadCancelToken? _loadCancelToken;

  final TextEditingController _searchCtrl = TextEditingController();
  final GlobalKey _searchBtnKey = GlobalKey();

  /// 列表滚动控制器。用来从阅读器返回时滚到"当前文件"那一项。
  final ItemScrollController _itemScrollController = ItemScrollController();

  /// 滚动位置监听器。删除/移动/复制后用来还原滚动锚点。
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  /// 每个目录的滚动位置（可见的第一项索引）。切换目录时用。
  /// key = 目录路径，value = 索引。
  final Map<String, int> _dirScrollPositions = {};

  bool _selectionMode = false;
  final Set<String> _selectedPaths = <String>{};

  /// 区间选择锚点。长按某项后记住，再长按另一项时从锚点到它整段选中。
  String? _anchorPath;

  // 搜索运行时状态（不持久化）
  List<_SearchHit> _searchResults = <_SearchHit>[];
  bool _searching = false;
  bool _searchActive = false;
  int _searchTaskId = 0;
  DateTime _lastUiRefresh = DateTime.now();

  @override
  void initState() {
    super.initState();
    final saved = ref.read(lastPathProvider);
    _currentPath = _resolveInitialPath(saved);
    _load();
  }

  /// 启动时决定的初始路径：无效/空/超范围 → 回到根目录。
  String _resolveInitialPath(String saved) {
    if (saved.isEmpty) return _rootPath;
    if (!saved.startsWith(_rootPath)) return _rootPath;
    if (!Directory(saved).existsSync()) return _rootPath;
    return saved;
  }

  // ==================== 路由感知：离开本页时自动收键盘 ====================

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      fileBrowserRouteObserver.subscribe(this, route);
    }
  }

  /// 本页被另一个页面 push 盖住时触发。
  /// 释放搜索框焦点 → 键盘收起；返回本页时不会自动弹出。
  @override
  void didPushNext() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void dispose() {
    fileBrowserRouteObserver.unsubscribe(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 加载当前目录。
  ///
  /// [restoreScroll] = true 时，会先快照当前视口里的路径列表，
  /// 加载完后跳到"第一个仍存在的路径"那一项——这样删除/移动/复制/
  /// 重命名后，视觉上位置几乎不动，而不是被弹回顶部。
  ///
  /// [skipCache] = true 时，强制跳过缓存走一次全新加载（菜单刷新用）。
  Future<void> _load({
    bool restoreScroll = false,
    bool skipCache = false,
  }) async {
    // 中断上一次加载
    _loadCancelToken?.cancel();
    final token = LoadCancelToken();
    _loadCancelToken = token;

    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    // 快照滚动锚点（在 setState 之前！）
    final anchor = restoreScroll ? _snapshotVisiblePaths() : const <String>[];
    var anchorRestored = false;

    final sortField = ref.read(sortFieldProvider);
    final sortAsc = ref.read(sortAscProvider);
    final cacheKey = '$_currentPath|${sortField.name}|$sortAsc';

    log.info(
        '[Dir] _load 开始  path=$_currentPath  restoreScroll=$restoreScroll  skipCache=$skipCache');

    // ---------- 查缓存 ----------
    if (!skipCache) {
      final cached = DirCache.instance.get(cacheKey);
      if (cached != null) {
        log.info('[DirCache] 命中  $cacheKey  (${cached.length} 项)');
        setState(() {
          _entries = cached;
          _loading = false;
          _error = null;
        });
        if (anchor.isNotEmpty) {
          _restoreScrollAnchor(anchor);
        } else {
          _restoreDirScroll();
        }
        log.info(
            '[Dir] _load 缓存命中，总耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
        return;
      }
      log.info('[DirCache] 未命中  $cacheKey');
    } else {
      log.info('[DirCache] 强制跳过缓存  $cacheKey');
    }

    // ---------- 缓存未命中，走异步加载 ----------
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await loadDirectoryAsync(
        path: _currentPath,
        sortField: sortField,
        sortAsc: sortAsc,
        cancelToken: token,
        onUpdate: (list) {
          if (!mounted || token.isCancelled) return;
          if (_currentPath != _currentPathForToken(token)) return;
          setState(() {
            _entries = list;
            _loading = false;
          });
          if (anchor.isNotEmpty && !anchorRestored) {
            _restoreScrollAnchor(anchor);
            anchorRestored = true;
          } else if (anchor.isEmpty && !anchorRestored) {
            _restoreDirScroll();
            anchorRestored = true;
          }
        },
        onComplete: (list) {
          if (!mounted || token.isCancelled) return;
          setState(() {
            _entries = list;
          });
          DirCache.instance.put(cacheKey, list);
          log.info('[DirCache] 写入  $cacheKey  (${list.length} 项)');
          log.info(
              '[Dir] _load 完成，总耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
        },
      );
    } catch (e) {
      if (!mounted || token.isCancelled) return;
      log.info('[Dir] ❌ _load 失败  $e');
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 检查 token 对应的加载是不是当前目录的。
  /// 简单实现：比较 token 是否还是最新的。
  String _currentPathForToken(LoadCancelToken token) {
    if (!identical(token, _loadCancelToken)) return '__stale__';
    return _currentPath;
  }

  // ==================== 滚动锚点 ====================

  /// 快照当前视口内所有项的路径（按索引排序）。
  /// 删除/移动/复制前的锚点来源。
  List<String> _snapshotVisiblePaths() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return const <String>[];

    final allPaths = _currentDisplayedPaths;
    if (allPaths.isEmpty) return const <String>[];

    final sorted = positions.toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final out = <String>[];
    for (final p in sorted) {
      if (p.index < 0 || p.index >= allPaths.length) continue;
      out.add(allPaths[p.index]);
    }
    return out;
  }

  /// 加载完新列表后，跳到锚点里第一个仍存在的路径。
  /// 全部找不到（比如整个目录被删空）→ 退回顶部。
  void _restoreScrollAnchor(List<String> anchorPaths) {
    if (anchorPaths.isEmpty) return;
    final allPaths = _currentDisplayedPaths;
    if (allPaths.isEmpty) return;

    var targetIdx = -1;
    for (final p in anchorPaths) {
      final idx = allPaths.indexOf(p);
      if (idx >= 0) {
        targetIdx = idx;
        break;
      }
    }
    if (targetIdx < 0) targetIdx = 0;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_itemScrollController.isAttached) return;
      _itemScrollController.jumpTo(index: targetIdx);
    });
  }

  /// 记录当前目录的滚动位置。离开当前目录前调用。
  void _recordCurrentScroll() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    var minIdx = 1 << 30;
    for (final p in positions) {
      if (p.index < minIdx) minIdx = p.index;
    }
    if (minIdx < (1 << 30)) {
      _dirScrollPositions[_currentPath] = minIdx;
    }
  }

  /// 加载完成后，根据当前目录的滚动记录决定：恢复 or 跳顶。
  void _restoreDirScroll() {
    final saved = _dirScrollPositions[_currentPath];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_itemScrollController.isAttached) return;
      final target = (saved != null && saved > 0) ? saved : 0;
      _itemScrollController.jumpTo(index: target);
    });
  }

  void _navigateTo(String path) {
    if (path == _currentPath) return;

    // ★ 记录离开前的滚动位置，供以后回到这个目录时恢复。
    _recordCurrentScroll();

    _clearSelection();
    _searchCtrl.clear();
    _searchTaskId++;
    ref.read(lastPathProvider.notifier).update(path);
    setState(() {
      _currentPath = path;
      _searchResults = [];
      _searching = false;
      _searchActive = false;
    });
    _load();
  }

  bool get _canGoUp => _currentPath != _rootPath;

  void _goUp() {
    if (!_canGoUp) return;
    final parent = Directory(_currentPath).parent.path;
    if (parent.length < _rootPath.length) return;
    _navigateTo(parent);
  }

  void _clearSelection() {
    _selectionMode = false;
    _selectedPaths.clear();
    _anchorPath = null;
  }

  /// 检查搜索结果，把磁盘上已经不存在的条目剔除。
  /// 对比页删文件后返回、或外部改动后调用。
  /// **自身不调用 setState**，调用方负责在合适的时机刷新 UI。
  void _pruneSearchResults() {
    if (_searchResults.isEmpty) return;
    final still = <_SearchHit>[];
    var removed = 0;
    for (final hit in _searchResults) {
      if (FileSystemEntity.typeSync(hit.path) !=
          FileSystemEntityType.notFound) {
        still.add(hit);
      } else {
        removed++;
        _selectedPaths.remove(hit.path);
      }
    }
    if (removed == 0) return;
    _searchResults = still;
    if (_selectedPaths.isEmpty) {
      _selectionMode = false;
      _anchorPath = null;
    }
  }

  void _toggleSelection(FileSystemEntity e) {
    setState(() {
      _selectionMode = true;
      if (_selectedPaths.contains(e.path)) {
        _selectedPaths.remove(e.path);
        if (_selectedPaths.isEmpty) {
          _selectionMode = false;
          _anchorPath = null;
        }
      } else {
        _selectedPaths.add(e.path);
        _anchorPath = e.path;
      }
    });
  }

  void _toggleSelectionPath(String path) {
    setState(() {
      _selectionMode = true;
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
        if (_selectedPaths.isEmpty) {
          _selectionMode = false;
          _anchorPath = null;
        }
      } else {
        _selectedPaths.add(path);
        _anchorPath = path;
      }
    });
  }

  /// 当前屏幕上显示的路径列表（按显示顺序）。
  /// 目录模式 = 目录里的文件/文件夹；搜索模式 = 搜索结果。
  List<String> get _currentDisplayedPaths {
    if (_searchActive) {
      return _searchResults.map((h) => h.path).toList();
    }
    return (_entries ?? const <EntryInfo>[])
        .map((e) => e.entity.path)
        .toList();
  }

  /// 长按某一项。
  /// - 不在选中模式 → 进入选中模式、选中该项、记锚点。
  /// - 已在选中模式 + 有锚点 → 从锚点到该项整段选中（区间选择）。
  void _onLongPressPath(String path) {
    if (!_selectionMode) {
      setState(() {
        _selectionMode = true;
        _selectedPaths.add(path);
        _anchorPath = path;
      });
      return;
    }
    if (_anchorPath != null) {
      final all = _currentDisplayedPaths;
      final from = all.indexOf(_anchorPath!);
      final to = all.indexOf(path);
      if (from >= 0 && to >= 0) {
        final lo = from < to ? from : to;
        final hi = from < to ? to : from;
        setState(() {
          for (var i = lo; i <= hi; i++) {
            _selectedPaths.add(all[i]);
          }
          _anchorPath = path;
        });
        return;
      }
    }
    setState(() {
      _selectedPaths.add(path);
      _anchorPath = path;
    });
  }

  /// 全选 / 全不选当前屏幕上显示的项。
  void _toggleSelectAll() {
    final all = _currentDisplayedPaths;
    final allSelected =
        all.isNotEmpty && all.every((p) => _selectedPaths.contains(p));
    setState(() {
      if (allSelected) {
        _selectedPaths.clear();
        _selectionMode = false;
        _anchorPath = null;
      } else {
        _selectionMode = true;
        _selectedPaths.addAll(all);
      }
    });
  }

  /// 点击文件的统一入口。
  ///
  /// 非文本文件 → 预览页。
  /// 文本文件 → 按 [fileOpenModeProvider] 分流到 阅读器 / 旧编辑器 / 行编辑器 / 询问。
  Future<void> _openFile(String path, String name, int? size) async {
    final log = ReaderLoadLog.instance;
    log.info('[Browser] 点击文件 name=$name  size=$size');
    final tOpen = DateTime.now();

    final isText = _textExts.contains(_extOf(name));

    // 非文本文件：走预览页，不需要返回定位。
    if (!isText) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TextPreviewScreen(
            filePath: path,
            fileName: name,
          ),
        ),
      );
      return;
    }

    // 文本文件：先确定用哪种方式。
    final configured = ref.read(fileOpenModeProvider);
    FileOpenMode resolved;
    if (configured == FileOpenMode.ask) {
      final picked = await _askOpenMode(name);
      if (picked == null) return;
      resolved = picked;
    } else {
      resolved = configured;
    }

    log.info(
        '[Browser] 决定打开方式=$resolved  决策耗时=${DateTime.now().difference(tOpen).inMilliseconds}ms');

    switch (resolved) {
      case FileOpenMode.reader:
        await _openInReader(path, name);
      case FileOpenMode.editor:
        await _openInEditor(path, name);
      case FileOpenMode.lineEditor:
        await _openInLineEditor(path, name);
      case FileOpenMode.ask:
        // 不会到这里（上面已消化）
        break;
    }
  }

  /// 阅读器打开。返回后按"App 内删除名单"过滤列表，并滚到原位置。
  Future<void> _openInReader(String path, String name) async {
    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    final textPaths = _collectTextFilePaths();
    log.info(
        '[Browser→Reader] 收集文本文件列表  ${textPaths.length} 项  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');

    var index = textPaths.indexOf(path);
    if (index < 0) {
      textPaths.insert(0, path);
      index = 0;
    }
    log.info('[Browser→Reader] 目标 index=$index  文件名=$name');






      final tPush = DateTime.now();
final openedPath = path; // ← 新增
final result = await Navigator.of(context).push<String>(
  PageRouteBuilder<String>(
    pageBuilder: (_, __, ___) => ReaderScreen(
      filePaths: textPaths,
      initialIndex: index,
    ),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  ),
);




      
    log.info(
        '[Browser→Reader] 阅读器返回  用户停留=${DateTime.now().difference(tPush).inMilliseconds}ms  result=$result');

    if (!mounted) return;

    // ---------- 按阅读器上报的"已删路径"过滤列表 ----------
    // 阅读器删文件时会把路径塞进 readerDeletedPathsProvider。
    // 这里读出来，从 _entries 里移除对应项，然后清空 provider。
    // 只处理 App 内删除；外部删除不管（用户可下拉刷新 / 菜单刷新）。
    // 复杂度 O(n)，用 HashSet 查找，1 万项约 0.3ms，无系统调用。
    final deleted = ref.read(readerDeletedPathsProvider);
    final tFilter = DateTime.now();
    if (deleted.isNotEmpty) {
      // 先清空，防止下次进入时误用旧数据。
      ref.read(readerDeletedPathsProvider.notifier).state = const [];

      final deletedSet = deleted.toSet();
      final current = _entries ?? const <EntryInfo>[];
      final stillThere = <EntryInfo>[];
      var removedCount = 0;
      for (final info in current) {
        if (deletedSet.contains(info.entity.path)) {
          removedCount++;
        } else {
          stillThere.add(info);
        }
      }
      log.info(
          '[Browser→Reader] 返回时按已删名单移除 $removedCount 项  耗时=${DateTime.now().difference(tFilter).inMilliseconds}ms');
      if (removedCount > 0) {
        setState(() => _entries = stillThere);
        // ★ 新增：同步到缓存（所有排序方式）
        DirCache.instance.applyToAll(
          _currentPath,
          (list) => list.where((e) => !deletedSet.contains(e.path)).toList(),
        );
      }
    } else {
      log.info(
          '[Browser→Reader] 返回时无已删记录  耗时=${DateTime.now().difference(tFilter).inMilliseconds}ms');
    }




      
     // 只在用户换了文件时才滚动。
  // 如果返回的就是打开时那个文件，说明用户只是看了看，
  // 保持列表原样，不要跳动。
  if (result != null && result != openedPath) {
    _scrollToPath(result);
    // ★ 让 _dirScrollPositions 记住这个新位置，下次从别的目录回来能恢复。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recordCurrentScroll();
    });
  }
  log.info(
      '[Browser→Reader] 全流程耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
}


    

  /// 旧编辑器打开。返回后刷新列表（文件可能被改过）。
  Future<void> _openInEditor(String path, String name) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SingleFileEditorScreen(
          filePath: path,
          fileName: name,
        ),
      ),
    );
    if (!mounted) return;
    DirCache.instance.invalidate(_currentPath);
    _load();
  }

  /// 行编辑器打开。返回后刷新列表。
  Future<void> _openInLineEditor(String path, String name) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LineEditorScreen(
          filePath: path,
          fileName: name,
        ),
      ),
    );
    if (!mounted) return;
    DirCache.instance.invalidate(_currentPath);
    _load();
  }

  /// "每次询问"模式：弹底部 sheet 让用户选，可以勾"记住"。
  Future<FileOpenMode?> _askOpenMode(String fileName) async {
    final remember = ValueNotifier<bool>(false);
    final picked = await showModalBottomSheet<FileOpenMode>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) => SafeArea(
        child: StatefulBuilder(
          builder: (c, setS) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.open_in_new, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '用哪种方式打开「$fileName」？',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.menu_book),
                title: const Text('阅读器'),
                subtitle: const Text('分页翻页，看小说用'),
                onTap: () => Navigator.pop(c, FileOpenMode.reader),
              ),
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('旧编辑器'),
                subtitle: const Text('功能全，大文件卡'),
                onTap: () => Navigator.pop(c, FileOpenMode.editor),
              ),
              ListTile(
                leading: const Icon(Icons.view_list),
                title: const Text('行编辑器'),
                subtitle: const Text('虚拟化，大文件流畅'),
                onTap: () => Navigator.pop(c, FileOpenMode.lineEditor),
              ),
              const Divider(height: 1),
              CheckboxListTile(
                value: remember.value,
                onChanged: (v) => setS(() => remember.value = v ?? false),
                title: const Text('记住我的选择'),
                subtitle: const Text(
                  '下次不再询问，直接按选中的方式打开。\n'
                  '想改回询问：右上角设置 → 打开方式 → 每次询问',
                  style: TextStyle(fontSize: 11),
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );

    if (picked != null && remember.value) {
      ref.read(fileOpenModeProvider.notifier).update(picked);
    }
    return picked;
  }

  /// 把列表滚到指定路径那一项。
  /// 路径不在当前列表里就什么都不做（比如搜索词改了、目录变了）。
  void _scrollToPath(String path) {
    int index = -1;
    if (_searchActive) {
      index = _searchResults.indexWhere((h) => h.path == path);
    } else {
      index = (_entries ?? const <EntryInfo>[])
          .indexWhere((e) => e.entity.path == path);
    }
    if (index < 0) return;

    // 延后一帧再跳，确保列表已经完成布局（从其他页面刚返回时，
    // 本页可能还在重建中，直接 jumpTo 会落在错位置）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_itemScrollController.isAttached) return;
      _itemScrollController.jumpTo(index: index);
    });
  }

  /// 收集"当前视图里所有文本文件的路径"。
  ///
  /// - 普通浏览模式：用当前目录的所有文件（已按排序排好）
  /// - 搜索模式：用搜索结果里所有文本文件
  List<String> _collectTextFilePaths() {
    if (_searchActive) {
      return [
        for (final hit in _searchResults)
          if (_textExts.contains(_extOf(hit.name))) hit.path,
      ];
    }
    final entries = _entries ?? const <EntryInfo>[];
    return [
      for (final info in entries)
        if (!info.isDir && _textExts.contains(_extOf(info.name)))
          info.entity.path,
    ];
  }

  void _openPreview(EntryInfo info) {
    _openFile(info.entity.path, info.name, info.size);
  }

  Widget _leading({
    required bool selectionMode,
    required bool selected,
    required bool isDir,
    required String name,
    required VoidCallback onToggle,
  }) {
    final icon = isDir ? Icons.folder : Icons.insert_drive_file_outlined;
    final color = isDir ? Colors.amber.shade600 : _fileColor(name);

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Icon(icon, color: color),
    );
  }

  // ==================== 搜索 ====================

  void _onSearchChanged(String v) {
    setState(() {});
  }

  void _doSearch() {
    final q = _searchCtrl.text;
    if (q.isEmpty) return;

    ref.read(browserSearchHistoryProvider.notifier).add(q);

    setState(() => _searchActive = true);
    _startSearch(q);
  }

  void _clearSearch() {
    _searchTaskId++;
    _searchCtrl.clear();
    _selectionMode = false;
    _selectedPaths.clear();
    _anchorPath = null;
    setState(() {
      _searchResults = [];
      _searching = false;
      _searchActive = false;
    });
  }

  void _cancelSearch() {
    _searchTaskId++;
    setState(() => _searching = false);
  }

  Future<void> _showSearchHistory() async {
    await showDialog<void>(
      context: context,
      builder: (c) => Consumer(
        builder: (c, ref, _) {
          final history = ref.watch(browserSearchHistoryProvider);
          return AlertDialog(
            insetPadding: _dlgInset,
            titlePadding: _dlgTitlePad,
            contentPadding: _dlgContentPad,
            actionsPadding: _dlgActionsPad,
            title: const Text('搜索历史'),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(c).size.height * 0.7,
              child: history.isEmpty
                  ? const Center(child: Text('还没有搜索记录'))
                  : ListView.builder(
                      itemCount: history.length,
                      itemBuilder: (ctx, i) {
                        final q = history[i];
                        return ListTile(
                          dense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          leading: const Icon(Icons.history, size: 20),
                          title: Text(
                            q,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: '删除',
                            onPressed: () {
                              ref
                                  .read(browserSearchHistoryProvider.notifier)
                                  .remove(q);
                            },
                          ),
                          onTap: () {
                            _searchCtrl.text = q;
                            setState(() {});
                            Navigator.pop(c);
                          },
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showScopeMenu() async {
    final ctx = _searchBtnKey.currentContext;
    if (ctx == null) return;
    final RenderBox box = ctx.findRenderObject() as RenderBox;
    final Offset pos = box.localToGlobal(Offset.zero);
    final size = box.size;

    final scope = ref.read(searchScopeProvider);
    final customFolders = ref.read(customSearchFoldersProvider);

    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy + size.height, 0, 0),
      items: [
        CheckedPopupMenuItem<String>(
          value: 'current',
          checked: scope == SearchScope.currentRecursive,
          child: const Text('当前目录及子目录'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'custom',
          checked: scope == SearchScope.custom,
          child: Text('自定义的搜索范围（${customFolders.length}）'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'manage',
          enabled: scope == SearchScope.custom,
          child: const Text('管理自定义的搜索范围'),
        ),
      ],
    );

    if (!mounted || value == null) return;

    if (value == 'current') {
      ref
          .read(searchScopeProvider.notifier)
          .update(SearchScope.currentRecursive);
      if (_searchActive && _searchCtrl.text.isNotEmpty) {
        _startSearch(_searchCtrl.text);
      }
    } else if (value == 'custom') {
      ref.read(searchScopeProvider.notifier).update(SearchScope.custom);
      if (_searchActive && _searchCtrl.text.isNotEmpty) {
        _startSearch(_searchCtrl.text);
      }
    } else if (value == 'manage') {
      _showSearchFolderPicker();
    }
  }

  List<String> _dedupFolders(List<String> folders) {
    final sorted = List<String>.from(folders)..sort();
    final out = <String>[];
    for (final f in sorted) {
      final covered = out.any((p) => f == p || f.startsWith('$p/'));
      if (!covered) out.add(f);
    }
    return out;
  }

  Future<void> _startSearch(String query) async {
    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    final taskId = ++_searchTaskId;
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _searching = false;
      });
      return;
    }

    setState(() {
      _searching = true;
      _searchResults = [];
    });
    _lastUiRefresh = DateTime.now();

    final scope = ref.read(searchScopeProvider);
    final customFolders = ref.read(customSearchFoldersProvider);

    final roots = <String>[];
    if (scope == SearchScope.currentRecursive) {
      roots.add(_currentPath);
    } else {
      if (customFolders.isEmpty) {
        _toast('请先长按搜索按钮 → 管理已勾选文件夹');
        if (mounted) setState(() => _searching = false);
        return;
      }
      roots.addAll(_dedupFolders(customFolders));
    }

    log.info('[Search] 开始  query="$query"  roots=${roots.length}');

    final lowerQuery = query.toLowerCase();
    final results = <_SearchHit>[];

    for (final root in roots) {
      if (taskId != _searchTaskId) return;
      await _scanDir(root, lowerQuery, results, taskId);
    }

    if (taskId != _searchTaskId) return;
    if (!mounted) return;

    final sortField = ref.read(sortFieldProvider);
    final sortAsc = ref.read(sortAscProvider);

    final tSort = DateTime.now();
    results.sort((a, b) {
      int cmp;
      switch (sortField) {
        case SortField.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case SortField.modified:
          final at = a.modified?.millisecondsSinceEpoch ?? 0;
          final bt = b.modified?.millisecondsSinceEpoch ?? 0;
          cmp = at.compareTo(bt);
        case SortField.size:
          final as = a.size ?? 0;
          final bs = b.size ?? 0;
          cmp = as.compareTo(bs);
      }
      return sortAsc ? cmp : -cmp;
    });

    setState(() {
      _searching = false;
      _searchResults = List.from(results);
    });

    final totalMs = DateTime.now().difference(t0).inMilliseconds;
    log.info(
        '[Search] 结束  结果=${results.length}  排序=${DateTime.now().difference(tSort).inMilliseconds}ms  总耗时=${totalMs}ms');
  }

  Future<void> _scanDir(
    String dirPath,
    String lowerQuery,
    List<_SearchHit> results,
    int taskId,
  ) async {
    if (results.length >= 500) return;
    try {
      await for (final e in Directory(dirPath).list(followLinks: false)) {
        if (taskId != _searchTaskId) return;
        if (results.length >= 500) return;

        if (e is Directory) {
          final name = e.path.split('/').last;
          if (name.startsWith('.')) continue;
          final lower = e.path.toLowerCase();
          if (lower.contains('/android/data') ||
              lower.contains('/android/obb')) {
            continue;
          }
          await _scanDir(e.path, lowerQuery, results, taskId);
        } else if (e is File) {
          final name = e.path.split('/').last;
          if (name.toLowerCase().contains(lowerQuery)) {
            int? size;
            DateTime? modified;
            try {
              final st = await e.stat();
              size = st.size;
              modified = st.modified;
            } catch (_) {}
            results.add(_SearchHit(
              path: e.path,
              name: name,
              size: size,
              modified: modified,
            ));
            final now = DateTime.now();
            if (mounted &&
                now.difference(_lastUiRefresh).inMilliseconds > 100) {
              _lastUiRefresh = now;
              setState(() => _searchResults = List.from(results));
            }
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _showSearchFolderPicker() async {
    final current = ref.read(customSearchFoldersProvider);
    final result = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SearchFolderPickerDialog(
        rootPath: _rootPath,
        initialPath: _currentPath,
        initialSelected: current,
      ),
    );
    if (result != null && mounted) {
      ref.read(customSearchFoldersProvider.notifier).setAll(result);
      if (_searchActive && _searchCtrl.text.isNotEmpty) {
        _startSearch(_searchCtrl.text);
      }
    }
  }

  // ==================== 对比 / MD5 / 属性 / 复制路径 ====================

  Future<void> _startCompare() async {
    if (_selectedPaths.length != 2) return;
    final paths = _selectedPaths.toList();

    for (final p in paths) {
      if (Directory(p).existsSync()) {
        _toast('对比只支持文件，请勿选中文件夹');
        return;
      }
    }

    final result = (
      original: File(paths[0]),
      modified: File(paths[1]),
    );

    try {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      final originalBytes = await result.original.readAsBytes();
      final modifiedBytes = await result.modified.readAsBytes();

      final origParsed = await _parseInWorker((
        fileName: result.original.path.split('/').last,
        bytes: originalBytes,
      ));
      final modParsed = await _parseInWorker((
        fileName: result.modified.path.split('/').last,
        bytes: modifiedBytes,
      ));

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      ref.read(originalRawTextProvider.notifier).state = origParsed.plainText;
      ref.read(modifiedRawTextProvider.notifier).state = modParsed.plainText;
      ref.read(originalFileNameProvider.notifier).state = origParsed.fileName;
      ref.read(modifiedFileNameProvider.notifier).state = modParsed.fileName;
      ref.read(originalEncodingProvider.notifier).state =
          origParsed.encodingLabel;
      ref.read(modifiedEncodingProvider.notifier).state =
          modParsed.encodingLabel;
      ref.read(originalFilePathProvider.notifier).state = result.original.path;
      ref.read(modifiedFilePathProvider.notifier).state = result.modified.path;
      ref.read(importRevisionProvider.notifier).state++;
      // 清掉上次编辑留下的内存改动，保证这次从磁盘原文开始。
      ref.read(editedOriginalProvider.notifier).state = null;
      ref.read(editedModifiedProvider.notifier).state = null;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const DiffViewerScreen(),
        ),
      );
      if (!mounted) return;
      // 对比页可能删过文件；返回后清掉选中，并把已经不存在的
      // 搜索结果从列表里剔除。目录列表不需要动。
      setState(() {
        _pruneSearchResults();
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _toast('读取文件失败：$e');
    }
  }

  static Future<ParsedDocumentResult> _parseInWorker(
    ({String fileName, Uint8List bytes}) input,
  ) async {
    final parsed = DocumentParser.parse(
      fileName: input.fileName,
      bytes: input.bytes,
    );
    return ParsedDocumentResult(
      fileName: parsed.fileName,
      plainText: parsed.plainText,
      encodingLabel: parsed.encoding.label,
    );
  }

  static String _md5Worker(Uint8List bytes) {
    return md5.convert(bytes).toString();
  }

  Future<void> _md5Compare() async {
    if (_selectedPaths.length != 2) return;
    final paths = _selectedPaths.toList();

    for (final p in paths) {
      if (Directory(p).existsSync()) {
        _toast('MD5 对比只支持文件，请勿选中文件夹');
        return;
      }
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final b1 = await File(paths[0]).readAsBytes();
      final b2 = await File(paths[1]).readAsBytes();
      final h1 = await compute(_md5Worker, b1);
      final h2 = await compute(_md5Worker, b2);

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      final same = h1 == h2;
      final name1 = paths[0].split('/').last;
      final name2 = paths[1].split('/').last;

      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          insetPadding: _dlgInset,
          titlePadding: _dlgTitlePad,
          contentPadding: _dlgContentPad,
          actionsPadding: _dlgActionsPad,
          title: const Text('MD5 对比'),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.7,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name1,
                      style:
                          const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText(
                    h1,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  Text(name2,
                      style:
                          const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText(
                    h2,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    same ? '相同' : '不同',
                    style: TextStyle(
                      color: same ? Colors.red : Colors.green,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _toast('计算 MD5 失败：$e');
    }
  }

  Future<void> _exportFolderListing() async {
    if (_selectedPaths.length != 1) {
      _toast('导出清单一次只能选一个文件夹');
      return;
    }
    final path = _selectedPaths.first;
    if (!Directory(path).existsSync()) {
      _toast('导出清单只能用于文件夹');
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    Uint8List bytes;
    try {
      bytes = await compute(_folderListingWorker, path);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _toast('扫描失败：$e');
      return;
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    final name = path.split('/').last;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final out = await FilePicker.saveFile(
      fileName: '$name-list-$ts.txt',
      bytes: bytes,
      mimeType: 'text/plain',
      dialogTitle: '保存文件夹清单',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (out != null && mounted) {
      _toast('清单已导出');
    }
  }

  Future<void> _showProperties() async {
    if (_selectedPaths.length != 1) return;
    final path = _selectedPaths.first;
    final name = path.split('/').last;

    int? size;
    DateTime? modified;
    DateTime? accessed;
    bool isDir = false;
    try {
      final st = await FileStat.stat(path);
      modified = st.modified;
      accessed = st.accessed;
      size = st.size;
      isDir = st.type == FileSystemEntityType.directory;
    } catch (_) {}

    if (!mounted) return;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 2),
              SelectableText(value),
            ],
          ),
        );

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _dlgInset,
        titlePadding: _dlgTitlePad,
        contentPadding: _dlgContentPad,
        actionsPadding: _dlgActionsPad,
        title: const Text('属性'),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(context).size.height * 0.7,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row('名称', name),
                row('路径', path),
                row('类型', isDir ? '文件夹' : '文件'),
                row('大小',
                    isDir ? '—' : (size == null ? '—' : _formatSize(size))),
                if (modified != null)
                  row('修改时间', _formatTimeFull(modified)),
                if (accessed != null)
                  row('访问时间', _formatTimeFull(accessed)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _copyPath() async {
    if (_selectedPaths.length != 1) return;
    final path = _selectedPaths.first;
    await Clipboard.setData(ClipboardData(text: path));
    if (mounted) _toast('路径已复制');
  }

  static String _formatTimeFull(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // ==================== 排序 / 收藏 ====================

  String _sortLabel(SortField f) {
    switch (f) {
      case SortField.name:
        return '名称';
      case SortField.modified:
        return '修改时间';
      case SortField.size:
        return '大小';
    }
  }

  Future<void> _showSortDialog() async {
    var tmpField = ref.read(sortFieldProvider);
    var tmpAsc = ref.read(sortAscProvider);
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          insetPadding: _dlgInset,
          titlePadding: _dlgTitlePad,
          contentPadding: _dlgContentPad,
          actionsPadding: _dlgActionsPad,
          title: const Text('排序方式'),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.7,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final f in SortField.values)
                    RadioListTile<SortField>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(_sortLabel(f)),
                      value: f,
                      groupValue: tmpField,
                      onChanged: (v) =>
                          setState(() => tmpField = v ?? tmpField),
                    ),
                  const Divider(),
                  RadioListTile<bool>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('升序'),
                    value: true,
                    groupValue: tmpAsc,
                    onChanged: (_) => setState(() => tmpAsc = true),
                  ),
                  RadioListTile<bool>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('降序'),
                    value: false,
                    groupValue: tmpAsc,
                    onChanged: (_) => setState(() => tmpAsc = false),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (result == true && mounted) {
      ref.read(sortFieldProvider.notifier).update(tmpField);
      ref.read(sortAscProvider.notifier).update(tmpAsc);
      _load();
    }
  }

  void _toggleFavorite() {
    final favs = ref.read(favoritesProvider);
    final wasFav = favs.contains(_currentPath);
    ref.read(favoritesProvider.notifier).toggle(_currentPath);
    _toast(wasFav ? '已取消收藏' : '已收藏当前目录');
  }

  Future<void> _exportConfig() async {
    try {
      final ok = await ConfigIoService.instance.export();
      if (!mounted) return;
      if (ok) _toast('配置已导出');
      // 用户取消：静默返回
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
    }
  }

  Future<void> _importConfig() async {
    final result = await ConfigIoService.instance.import();
    if (!mounted) return;

    // 用户取消
    if (!result.ok && result.message == null) return;

    // 失败
    if (!result.ok) {
      _toast(result.message ?? '导入失败');
      return;
    }

    // 成功：提示重启
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('导入成功'),
        content: const Text(
          '配置已导入。请手动退出 App 再重新打开，配置才会生效。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _showFavorites() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setInnerState) {
          final favorites = ref.watch(favoritesProvider);
          final isFav = favorites.contains(_currentPath);

          return AlertDialog(
            insetPadding: _dlgInset,
            titlePadding: _dlgTitlePad,
            contentPadding: _dlgContentPad,
            actionsPadding: _dlgActionsPad,
            title: const Text('已收藏目录'),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(context).size.height * 0.7,
              child: Column(
                children: [
                  // 顶部：收藏/取消收藏当前目录
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      isFav ? Icons.star : Icons.star_border,
                      color: isFav ? Colors.amber : null,
                    ),
                    title: Text(
                      isFav ? '取消收藏当前目录' : '收藏当前目录',
                    ),
                    subtitle: Text(
                      _currentPath,
                      style: const TextStyle(fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      ref
                          .read(favoritesProvider.notifier)
                          .toggle(_currentPath);
                      setInnerState(() {});
                    },
                  ),
                  const Divider(height: 1),
                  // 收藏列表
                  Expanded(
                    child: favorites.isEmpty
                        ? const Center(child: Text('还没有收藏任何目录'))
                        : ListView.builder(
                            itemCount: favorites.length,
                            itemBuilder: (ctx, i) {
                              final p = favorites[i];
                              return ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.folder,
                                    color: Colors.amber),
                                title: Text(p.split('/').last),
                                subtitle: Text(
                                  p,
                                  style: const TextStyle(fontSize: 11),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => Navigator.pop(c, p),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 20),
                                  tooltip: '移除收藏',
                                  onPressed: () {
                                    ref
                                        .read(favoritesProvider.notifier)
                                        .remove(p);
                                    setInnerState(() {});
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    if (picked != null && mounted) {
      if (Directory(picked).existsSync()) {
        _navigateTo(picked);
      } else {
        _toast('该目录已不存在');
        ref.read(favoritesProvider.notifier).remove(picked);
      }
    }
  }

  // ==================== 文件操作 ====================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  Future<bool> _confirm(String title, String message) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _dlgInset,
        titlePadding: _dlgTitlePad,
        contentPadding: _dlgContentPad,
        actionsPadding: _dlgActionsPad,
        title: Text(title),
        content: Text(message),
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
    return ok == true;
  }

  Future<void> _rename() async {
    if (_selectedPaths.length != 1) {
      _toast('重命名一次只能操作一个');
      return;
    }
    final oldPath = _selectedPaths.first;
    final oldName = oldPath.split('/').last;

    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _TextInputDialog(
        title: '重命名',
        initialValue: oldName,
      ),
    );
    if (newName == null) return;

    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == oldName) return;
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      _toast('名称不能包含斜杠');
      return;
    }
    if (trimmed == '.' || trimmed == '..') {
      _toast('名称无效');
      return;
    }

    final parent = File(oldPath).parent.path;
    final newPath = '$parent/$trimmed';

    if (FileSystemEntity.typeSync(newPath) !=
        FileSystemEntityType.notFound) {
      _toast('目标已存在：$trimmed');
      return;
    }

    try {
      if (Directory(oldPath).existsSync()) {
        await Directory(oldPath).rename(newPath);
      } else {
        await File(oldPath).rename(newPath);
      }
      DirCache.instance.invalidate(_currentPath);
      _clearSelection();
      _load(restoreScroll: true);
      _toast('已重命名为 $trimmed');
    } catch (e) {
      _toast('重命名失败：$e');
    }
  }

  Future<void> _move() async {
    if (_selectedPaths.isEmpty) return;
    final target = await _pickDirectory('移动到哪？');
    if (target == null) return;

    var ok = 0;
    var fail = 0;
    for (final src in _selectedPaths.toList()) {
      final name = src.split('/').last;
      final dst = '$target/$name';
      if (src == dst) continue;
      try {
        if (Directory(src).existsSync()) {
          await Directory(src).rename(dst);
        } else {
          await File(src).rename(dst);
        }
        ok++;
      } catch (_) {
        fail++;
      }
    }

    if (ok > 0) {
      ref.read(recentMoveTargetsProvider.notifier).add(target);
    }

    if (ok > 0) {
      DirCache.instance.invalidate(_currentPath);
      DirCache.instance.invalidate(target);
    }
    _clearSelection();
    _load(restoreScroll: true);
    _toast('已移动 $ok 项${fail > 0 ? "，$fail 项失败" : ""}');
  }

  Future<void> _copy() async {
    if (_selectedPaths.isEmpty) return;
    final target = await _pickDirectory('复制到哪？');
    if (target == null) return;

    var ok = 0;
    var fail = 0;
    for (final src in _selectedPaths.toList()) {
      final name = src.split('/').last;
      final dst = '$target/$name';
      if (src == dst) continue;
      try {
        if (Directory(src).existsSync()) {
          await _copyDir(Directory(src), Directory(dst));
        } else {
          await File(src).copy(dst);
        }
        ok++;
      } catch (_) {
        fail++;
      }
    }

    if (ok > 0) {
      ref.read(recentMoveTargetsProvider.notifier).add(target);
    }
    if (ok > 0) {
      DirCache.instance.invalidate(target);
    }
    _clearSelection();
    _load(restoreScroll: true);
    _toast('已复制 $ok 项${fail > 0 ? "，$fail 项失败" : ""}');
  }

  Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      final name = e.path.split('/').last;
      final target = '${dst.path}/$name';
      if (e is Directory) {
        await _copyDir(e, Directory(target));
      } else if (e is File) {
        await e.copy(target);
      }
    }
  }

  Future<void> _delete() async {
    if (_selectedPaths.isEmpty) return;
    final n = _selectedPaths.length;
    final ok = await _confirm(
      '删除 $n 项？',
      '选中的 $n 项将从磁盘删除，无法恢复。',
    );
    if (!ok) return;

    final deletedPaths = <String>{};
    var fail = 0;
    for (final p in _selectedPaths.toList()) {
      try {
        if (Directory(p).existsSync()) {
          await Directory(p).delete(recursive: true);
        } else {
          await File(p).delete();
        }
        deletedPaths.add(p);
      } catch (_) {
        fail++;
      }
    }

    final deleted = deletedPaths.length;
    _clearSelection();

    if (_searchActive) {
      // 搜索结果模式：把删掉的条目从列表里剔除。
      // 目录被删时，目录里的所有文件也算删掉，一并移除。
      // 加锚点，删完后保持滚动位置。
      final anchor = _snapshotVisiblePaths();
      setState(() {
        _searchResults = _searchResults.where((h) {
          if (deletedPaths.contains(h.path)) return false;
          for (final dp in deletedPaths) {
            if (h.path.startsWith('$dp/')) return false;
          }
          return true;
        }).toList();
      });
      if (anchor.isNotEmpty) _restoreScrollAnchor(anchor);
    } else {
      DirCache.instance.invalidate(_currentPath);
      _load(restoreScroll: true);
    }

    _toast('已删除 $deleted 项${fail > 0 ? "，$fail 项失败" : ""}');
  }

  Future<void> _newFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _TextInputDialog(
        title: '新建文件夹',
        initialValue: '新建文件夹',
      ),
    );
    if (name == null) return;

    final trimmed = name.trim();
    // 校验：非空、不含 /、不是 . 或 ..
    if (trimmed.isEmpty) {
      _toast('名称不能为空');
      return;
    }
    if (trimmed.contains('/') || trimmed.contains('\\')) {
      _toast('名称不能包含斜杠');
      return;
    }
    if (trimmed == '.' || trimmed == '..') {
      _toast('名称无效');
      return;
    }

    final path = '$_currentPath/$trimmed';
    if (FileSystemEntity.typeSync(path) !=
        FileSystemEntityType.notFound) {
      _toast('同名文件或文件夹已存在');
      return;
    }
    try {
      await Directory(path).create();
      DirCache.instance.invalidate(_currentPath);
      _load();
      _toast('已新建 $trimmed');
    } catch (e) {
      _toast('新建失败：$e');
    }
  }

  Future<void> _showJumpToPathDialog() async {
    final ctrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _dlgInset,
        titlePadding: _dlgTitlePad,
        contentPadding: _dlgContentPad,
        actionsPadding: _dlgActionsPad,
        title: const Text('跳转到目录'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('输入或粘贴完整路径：',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '/storage/emulated/0/xxx',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (v) => Navigator.pop(c, v),
              ),
              const SizedBox(height: 8),
              Text(
                '若粘贴的是文件路径，会跳到该文件所在目录',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    ctrl.dispose();

    if (!mounted || path == null || path.isEmpty) return;

    var target = path;
    if (FileSystemEntity.typeSync(target) == FileSystemEntityType.file) {
      target = File(target).parent.path;
    }

    if (!Directory(target).existsSync()) {
      _toast('目录不存在：$target');
      return;
    }
    if (!target.startsWith(_rootPath)) {
      _toast('只能跳到内部存储（$_rootPath）以内');
      return;
    }
    _navigateTo(target);
  }

  Future<String?> _pickDirectory(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => DirectoryPickerDialog(
        title: title,
        rootPath: _rootPath,
        initialPath: _currentPath,
      ),
    );
  }

  // ==================== 面包屑 ====================

  List<({String label, String path})> get _crumbs {
    final relative = _currentPath.substring(_rootPath.length);
    final segments = relative.split('/').where((s) => s.isNotEmpty).toList();

    final out = <({String label, String path})>[
      (label: '内部存储', path: _rootPath),
    ];
    var acc = _rootPath;
    for (final seg in segments) {
      acc = '$acc/$seg';
      out.add((label: seg, path: acc));
    }
    return out;
  }

  Widget _buildBreadcrumbs() {
    final crumbs = _crumbs;
    final s = Theme.of(context).colorScheme;
    final widgets = <Widget>[];
    for (var i = 0; i < crumbs.length; i++) {
      final c = crumbs[i];
      final isLast = i == crumbs.length - 1;
      if (i > 0) {
        widgets.add(Icon(Icons.chevron_right, size: 16, color: s.outline));
      }
      widgets.add(
        GestureDetector(
          onTap: isLast ? null : () => _navigateTo(c.path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              c.label,
              style: TextStyle(
                fontSize: 12,
                color: isLast ? Colors.black : Colors.black54,
                fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFFAFF),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(children: widgets),
      ),
    );
  }

  static String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _formatTime(DateTime? t) {
    if (t == null) return '';
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  String get _title {
    if (_currentPath == _rootPath) return '内部存储';
    return _currentPath.split('/').last;
  }

  String _relPath(String fullPath) {
    if (fullPath == _rootPath) return '~/';
    if (fullPath.startsWith(_rootPath)) {
      return '~${fullPath.substring(_rootPath.length)}';
    }
    return fullPath;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoUp && !_selectionMode && !_searchActive,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 返回键优先级：先取消选中 → 再退搜索 → 最后上一级。
        if (_selectionMode) {
          setState(_clearSelection);
        } else if (_searchActive) {
          _clearSearch();
        } else if (_canGoUp) {
          _goUp();
        }
      },
      child: Scaffold(
        appBar:
            _selectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
        body: Column(
          children: [
            if (!_selectionMode) _buildBreadcrumbs(),
            IgnorePointer(
              ignoring: _selectionMode,
              child: _buildSearchBar(),
            ),
            if (_searchActive) _buildSearchStatusBar(),
            Expanded(child: _buildBody()),
          ],
        ),
        bottomNavigationBar: _selectionMode ? _buildBottomBar() : null,
        floatingActionButton: null,
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar() {
    final favorites = ref.watch(favoritesProvider);
    final isFav = favorites.contains(_currentPath);
    return AppBar(
      title: GestureDetector(
        onLongPress: _showJumpToPathDialog,
        child: Text(
          (_searchActive &&
                  ref.watch(searchScopeProvider) == SearchScope.custom)
              ? '自定义的搜索范围'
              : _title,
          style: const TextStyle(fontSize: 14),
        ),
      ),
      leading: _searchActive
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _clearSearch,
            )
          : (_canGoUp
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _goUp,
                )
              : null),
      actions: [
        // 收藏/取消收藏
        IconButton(
          icon: Icon(
            isFav ? Icons.star : Icons.star_border,
            color: isFav ? Colors.amber : null,
          ),
          tooltip: isFav ? '取消收藏此目录' : '收藏此目录',
          onPressed: _toggleFavorite,
        ),
        // 比较设置
        IconButton(
          icon: const Icon(Icons.tune),
          tooltip: '比较设置',
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ComparisonSettingsScreen(),
              ),
            );
          },
        ),

        // 更多菜单（刷新 + 排序 + 已收藏目录）
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: '更多',

          onSelected: (v) {
            switch (v) {
              case 'browserSettings':
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BrowserSettingsScreen(),
                  ),
                );
              case 'exportConfig':
                _exportConfig();
              case 'importConfig':
                _importConfig();
              case 'refresh':
                DirCache.instance.invalidate(_currentPath);
                _load(skipCache: true);
              case 'sort':
                _showSortDialog();
              case 'favorites':
                _showFavorites();
              case 'newFolder':
                _newFolder();
            }
          },

          itemBuilder: (context) => [
            const PopupMenuItem<String>(
              value: 'browserSettings',
              child: Row(
                children: [
                  Icon(Icons.settings),
                  SizedBox(width: 10),
                  Text('浏览器设置'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'exportConfig',
              child: Row(
                children: [
                  Icon(Icons.upload_file),
                  SizedBox(width: 10),
                  Text('导出配置'),
                ],
              ),
            ),
            const PopupMenuItem<String>(
              value: 'importConfig',
              child: Row(
                children: [
                  Icon(Icons.download),
                  SizedBox(width: 10),
                  Text('导入配置'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'refresh',
              child: Row(
                children: [
                  Icon(Icons.refresh),
                  SizedBox(width: 10),
                  Text('刷新'),
                ],
              ),
            ),
            const PopupMenuItem<String>(
              value: 'sort',
              child: Row(
                children: [
                  Icon(Icons.sort),
                  SizedBox(width: 10),
                  Text('排序方式'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'favorites',
              child: Row(
                children: [
                  const Icon(Icons.bookmarks_outlined),
                  const SizedBox(width: 10),
                  Text('已收藏目录 (${favorites.length})'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'newFolder',
              child: Row(
                children: [
                  Icon(Icons.create_new_folder),
                  SizedBox(width: 10),
                  Text('新建文件夹'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    final all = _currentDisplayedPaths;
    final allSelected =
        all.isNotEmpty && all.every((p) => _selectedPaths.contains(p));
    return AppBar(
      toolbarHeight: kToolbarHeight + 28,
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => setState(_clearSelection),
      ),
      title: Text('已选 ${_selectedPaths.length} 个'),
      actions: [
        IconButton(
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          tooltip: allSelected ? '全不选' : '全选',
          onPressed: _toggleSelectAll,
        ),
      ],
    );
  }

  // ==================== 搜索栏 UI ====================

  Widget _buildSearchBar() {
    final isCustom = ref.watch(searchScopeProvider) == SearchScope.custom;
    final customFolders = ref.watch(customSearchFoldersProvider);
    final hasText = _searchCtrl.text.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: Row(
        children: [
          InkWell(
            key: _searchBtnKey,
            onTap: hasText ? _doSearch : null,
            onLongPress: _showScopeMenu,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: isCustom
                    ? Theme.of(context)
                        .colorScheme
                        .primary
                        .withOpacity(0.12)
                    : null,
              ),
              child: Icon(
                Icons.search,
                color: _selectionMode
                    ? Colors.grey
                    : (hasText
                        ? AppColors.accentPurple
                        : Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              enabled: !_selectionMode,
              cursorColor: AppColors.accentPurple,
              decoration: InputDecoration(
                hintText: _selectionMode
                    ? '选择模式下禁止点击'
                    : (isCustom && customFolders.isEmpty
                        ? '长按左侧设置搜索范围'
                        : '输入关键词'),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: AppColors.accentPurple,
                    width: 2,
                  ),
                ),
              ),
              onChanged: _onSearchChanged,
              onSubmitted: (_) => _doSearch(),
            ),
          ),
          if (hasText)
            IconButton(
              icon: Icon(
                Icons.clear,
                color: _selectionMode ? Colors.grey : AppColors.accentPurple,
              ),
              tooltip: '清空',
              onPressed: _clearSearch,
            )
          else
            IconButton(
              icon: Icon(
                Icons.history,
                color: _selectionMode ? Colors.grey : AppColors.accentPurple,
              ),
              tooltip: '搜索历史',
              onPressed: _showSearchHistory,
            ),
        ],
      ),
    );
  }

  Widget _buildSearchStatusBar() {
    if (_searching) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '扫描中... 已找到 ${_searchResults.length} 个',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _cancelSearch,
              child: const Text('取消'),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _searchResults.length >= 500
                  ? '已达上限，只显示前 500 个'
                  : '共找到 ${_searchResults.length} 个',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 底部栏 ====================

  Widget _buildBottomBar() {
    final n = _selectedPaths.length;
    final canCompare = n == 2;
    final canMd5 = n == 2;
    final canProps = n == 1;
    final canRename = n == 1;
    final canOps = n >= 1;

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.compare_arrows, size: 16),
                    label: const Text('对比'),
                    onPressed: canCompare ? _startCompare : null,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  flex: 1,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      backgroundColor: Colors.transparent,
                      foregroundColor: Colors.black,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    onPressed: canProps ? _showProperties : null,
                    child: const Text(
                      '属性',
                      style: TextStyle(fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                Expanded(
                  flex: 1,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      backgroundColor: Colors.transparent,
                      foregroundColor: Colors.black,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    onPressed: canProps ? _copyPath : null,
                    child: const Text(
                      '复制路径',
                      style: TextStyle(fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                Expanded(
                  flex: 1,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      backgroundColor: Colors.transparent,
                      foregroundColor: Colors.black,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    onPressed: canProps ? _exportFolderListing : null,
                    child: const Text(
                      '导出清单',
                      style: TextStyle(fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: _wideAction(
                    icon: Icons.fingerprint,
                    label: 'MD5',
                    onPressed: canMd5 ? _md5Compare : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.drive_file_rename_outline,
                    label: '重命名',
                    onPressed: canRename ? _rename : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.drive_file_move_outline,
                    label: '移动',
                    onPressed: canOps ? _move : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.copy_all_outlined,
                    label: '复制',
                    onPressed: canOps ? _copy : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.delete_outline,
                    label: '删除',
                    color: Colors.red,
                    onPressed: canOps ? _delete : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _wideAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    final disabled = onPressed == null;
    final c = disabled
        ? Theme.of(context).disabledColor
        : (color ?? Theme.of(context).colorScheme.onSurface);
    return InkWell(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: c),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: c)),
          ],
        ),
      ),
    );
  }

  // ==================== 主体 ====================

  Widget _buildBody() {
    // 搜索模式
    if (_searchActive) {
      if (_searchResults.isEmpty) {
        return Center(
          child: Text(_searching ? '正在扫描...' : '未找到匹配'),
        );
      }
      return ScrollablePositionedList.builder(
        itemScrollController: _itemScrollController,
        itemPositionsListener: _positionsListener,
        itemCount: _searchResults.length,
        itemBuilder: (ctx, i) {
          final hit = _searchResults[i];
          final selected = _selectedPaths.contains(hit.path);
          final metaLine = [
            _formatSize(hit.size),
            _formatTime(hit.modified),
          ].where((s) => s.isNotEmpty).join(' · ');

          return Container(
            foregroundDecoration: selected
                ? BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  )
                : null,
            child: ListTile(
              dense: true,
              isThreeLine: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              selected: selected,
              selectedTileColor: const Color(0xFFFFF3FB),
              leading: _leading(
                selectionMode: _selectionMode,
                selected: selected,
                isDir: false,
                name: hit.name,
                onToggle: () => _toggleSelectionPath(hit.path),
              ),
              title: Text(
                hit.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (metaLine.isNotEmpty)
                    Text(
                      metaLine,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  Text(
                    hit.path,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                    softWrap: true,
                  ),
                ],
              ),
              onTap: () {
                if (_selectionMode) {
                  _toggleSelectionPath(hit.path);
                  return;
                }
                _openFile(hit.path, hit.name, hit.size);
              },
              onLongPress: () => _onLongPressPath(hit.path),
            ),
          );
        },
      );
    }

    // 普通目录模式
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
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final entries = _entries ?? const <EntryInfo>[];
    if (entries.isEmpty) {
      return const Center(child: Text('空目录'));
    }

    return ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: entries.length,
      itemBuilder: (ctx, i) {
        final info = entries[i];
        final e = info.entity;
        final selected = _selectedPaths.contains(e.path);

        final String metaLine;
        if (info.isDir) {
          metaLine = _formatTime(info.modified);
        } else {
          final size = _formatSize(info.size);
          final time = _formatTime(info.modified);
          metaLine = [size, time].where((s) => s.isNotEmpty).join(' · ');
        }

        return Container(
          foregroundDecoration: selected
              ? BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                )
              : null,
          child: ListTile(
            dense: true,
            isThreeLine: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            selected: selected,
            selectedTileColor: const Color(0xFFFFF3FB),
            leading: _leading(
              selectionMode: _selectionMode,
              selected: selected,
              isDir: info.isDir,
              name: info.name,
              onToggle: () => _toggleSelection(e),
            ),
            title: Text(
              info.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (metaLine.isNotEmpty)
                  Text(
                    metaLine,
                    style: Theme.of(context).textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            onTap: () {
              if (_selectionMode) {
                _toggleSelection(e);
                return;
              }
              if (info.isDir) {
                _navigateTo(e.path);
              } else {
                _openPreview(info);
              }
            },
            onLongPress: () => _onLongPressPath(e.path),
          ),
        );
      },
    );
  }
}

// ==================== 辅助 Widget ====================

const EdgeInsets _dlgInsetG = EdgeInsets.all(4);
const EdgeInsets _dlgTitlePadG = EdgeInsets.fromLTRB(12, 8, 12, 0);
const EdgeInsets _dlgContentPadG = EdgeInsets.fromLTRB(8, 4, 8, 4);
const EdgeInsets _dlgActionsPadG = EdgeInsets.fromLTRB(4, 0, 4, 4);

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.initialValue,
  });

  final String title;
  final String initialValue;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: _dlgInsetG,
      titlePadding: _dlgTitlePadG,
      contentPadding: _dlgContentPadG,
      actionsPadding: _dlgActionsPadG,
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 自定义搜索文件夹的勾选器。
class _SearchFolderPickerDialog extends StatefulWidget {
  const _SearchFolderPickerDialog({
    required this.rootPath,
    required this.initialPath,
    required this.initialSelected,
  });

  final String rootPath;
  final String initialPath;
  final List<String> initialSelected;

  @override
  State<_SearchFolderPickerDialog> createState() =>
      _SearchFolderPickerDialogState();
}

class _SearchFolderPickerDialogState extends State<_SearchFolderPickerDialog> {
  late String _path;
  late List<String> _selected;
  List<Directory> _dirs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _selected = List<String>.from(widget.initialSelected);
    _load();
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
    setState(() => _path = parent);
    _load();
  }

  void _toggle(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  Future<void> _showSelected() async {
    await showDialog<void>(
      context: context,
      builder: (outerContext) => StatefulBuilder(
        builder: (innerContext, setInnerState) => AlertDialog(
          insetPadding: _dlgInsetG,
          titlePadding: _dlgTitlePadG,
          contentPadding: _dlgContentPadG,
          actionsPadding: _dlgActionsPadG,
          title: const Text('已勾选文件夹'),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(innerContext).size.height * 0.85,
            child: _selected.isEmpty
                ? const Text('还没有勾选任何文件夹')
                : ListView.builder(
                    itemCount: _selected.length,
                    itemBuilder: (ctx, i) {
                      final p = _selected[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(p.split('/').last),
                        subtitle: Text(
                          p,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: '移除',
                          onPressed: () {
                            setInnerState(() => _selected.removeAt(i));
                            setState(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(innerContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final relPath = _path == widget.rootPath
        ? '~/'
        : '~${_path.substring(widget.rootPath.length)}';

    return AlertDialog(
      insetPadding: _dlgInsetG,
      titlePadding: _dlgTitlePadG,
      contentPadding: EdgeInsets.zero,
      actionsPadding: _dlgActionsPadG,
      title: const Text('勾选要搜索的文件夹'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _canGoUp ? _goUp : null,
                    tooltip: '上一级',
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        relPath,
                        style: Theme.of(context).textTheme.labelSmall,
                        maxLines: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _dirs.isEmpty
                      ? const Center(child: Text('（无子目录）'))
                      : ListView.builder(
                          itemCount: _dirs.length,
                          itemBuilder: (ctx, i) {
                            final d = _dirs[i];
                            final name = d.path.split('/').last;
                            final selected = _selected.contains(d.path);
                            return ListTile(
                              dense: true,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              leading: SizedBox(
                                width: 68,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InkWell(
                                      onTap: () => _toggle(d.path),
                                      child: Padding(
                                        padding: const EdgeInsets.all(4),
                                        child: Icon(
                                          selected
                                              ? Icons.check_box
                                              : Icons
                                                  .check_box_outline_blank,
                                          color: selected
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                              : null,
                                        ),
                                      ),
                                    ),
                                    InkWell(
                                      onTap: () => _toggle(d.path),
                                      child: const Padding(
                                        padding: EdgeInsets.all(4),
                                        child: Icon(Icons.folder,
                                            color: Colors.amber),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              title: Text(name),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                setState(() => _path = d.path);
                                _load();
                              },
                            );
                          },
                        ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
              child: Row(
                children: [
                  Text(
                    '已勾选 ${_selected.length} 个',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _selected.isEmpty ? null : _showSelected,
                    child: const Text('查看'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class ParsedDocumentResult {
  const ParsedDocumentResult({
    required this.fileName,
    required this.plainText,
    required this.encodingLabel,
  });

  final String fileName;
  final String plainText;
  final String encodingLabel;
}
