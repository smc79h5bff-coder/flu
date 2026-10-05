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
  static const String _topPath = '/storage';

  // 弹窗统一参数
  static const EdgeInsets _dlgInset = EdgeInsets.all(4);
  static const EdgeInsets _dlgTitlePad =
      EdgeInsets.fromLTRB(12, 8, 12, 0);
  static const EdgeInsets _dlgContentPad = EdgeInsets.fromLTRB(8, 4, 8, 4);
  static const EdgeInsets _dlgActionsPad =
      EdgeInsets.fromLTRB(4, 0, 4, 4);

  // ==================== 网格布局常量（可调） ====================
  //
  // 网格单元格内边距 —— 想调留白改这里。
  static const double _gridCellPadH = 8.0;
  static const double _gridCellPadV = 6.0;

  /// 网格分隔线粗细。
  static const double _gridDividerThickness = 0.5;

  /// 网格分隔线颜色。
  static const Color _gridDividerColor = Color(0xFFE0E0E0);

  /// 网格选中背景色。
  static const Color _gridSelectedBg = Color(0xFFFFF3FB);

  // ==================== 扩展名 → 图标颜色 ====================

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

  static const Set<String> _binaryExts = {
    '.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.m4v',
    '.3gp', '.mpg', '.mpeg', '.rmvb', '.rm', '.vob',
    '.mp3', '.flac', '.wav', '.aac', '.ogg', '.m4a', '.wma', '.ape',
    '.opus',
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.ico',
    '.tif', '.tiff', '.heic', '.raw',
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso',
    '.cab', '.lz', '.lzma', '.zst', '.apk', '.apks', '.xapk', '.aab',
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.odt', '.ods', '.odp', '.epub', '.mobi', '.azw', '.azw3',
    '.exe', '.dll', '.so', '.bin', '.img', '.db', '.sqlite', '.mdb',
  };

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return '';
    return name.substring(i).toLowerCase();
  }

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

  LoadCancelToken? _loadCancelToken;

  final TextEditingController _searchCtrl = TextEditingController();
  final GlobalKey _searchBtnKey = GlobalKey();

  final ItemScrollController _itemScrollController = ItemScrollController();

  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  final Map<String, int> _dirScrollPositions = {};

  bool _selectionMode = false;
  final Set<String> _selectedPaths = <String>{};

  String? _anchorPath;

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

  String _resolveInitialPath(String saved) {
    if (saved.isEmpty) return _rootPath;
    if (!saved.startsWith(_topPath)) return _rootPath;
    if (!Directory(saved).existsSync()) return _rootPath;
    return saved;
  }

  // ==================== 路由感知 ====================

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      fileBrowserRouteObserver.subscribe(this, route);
    }
  }

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

  Future<void> _load({
    bool restoreScroll = false,
    bool skipCache = false,
  }) async {
    _loadCancelToken?.cancel();
    final token = LoadCancelToken();
    _loadCancelToken = token;

    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    final anchor = restoreScroll ? _snapshotVisiblePaths() : const <String>[];
    var anchorRestored = false;

    final sortField = ref.read(sortFieldProvider);
    final sortAsc = ref.read(sortAscProvider);
    final cacheKey = '$_currentPath|${sortField.name}|$sortAsc';

    log.info(
        '[Dir] _load 开始  path=$_currentPath  restoreScroll=$restoreScroll  skipCache=$skipCache');

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

    // 特殊路径：/storage 顶层。Android 11+ 禁止 list，走手动构造。
    // 必须在 setState(_loading=true) 和 loadDirectoryAsync 之前拦截，
    // 否则会走正常流程直接报错。
    if (_currentPath == _topPath) {
      List<EntryInfo> entries;
      try {
        entries = _listStorageRoot();
      } catch (e) {
        log.info('[Storage] _listStorageRoot 异常：$e');
        entries = <EntryInfo>[];
      }
      if (!mounted || token.isCancelled) return;
      setState(() {
        _entries = entries;
        _loading = false;
        _error = null;
      });
      DirCache.instance.put(cacheKey, entries);
      if (anchor.isNotEmpty) _restoreScrollAnchor(anchor);
      log.info('[Dir] /storage 手动构造完成，${entries.length} 项');
      return;
    }

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

  String _currentPathForToken(LoadCancelToken token) {
    if (!identical(token, _loadCancelToken)) return '__stale__';
    return _currentPath;
  }

  // ==================== 滚动锚点 ====================
  //
  // 列表模式：item 索引 = 文件索引。
  // 网格模式：item 索引 = 行号；文件索引 = 行号 * 2（或 *2+1）。
  // 存储的锚点统一是文件索引，跳转时按当前模式转换成行号。

  bool get _isGridMode =>
      !_searchActive && ref.read(browserGridModeProvider);

  List<String> _snapshotVisiblePaths() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return const <String>[];

    final allPaths = _currentDisplayedPaths;
    if (allPaths.isEmpty) return const <String>[];

    final sorted = positions.toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final grid = _isGridMode;
    final out = <String>[];
    for (final p in sorted) {
      if (grid) {
        final i1 = p.index * 2;
        final i2 = i1 + 1;
        if (i1 >= 0 && i1 < allPaths.length) out.add(allPaths[i1]);
        if (i2 >= 0 && i2 < allPaths.length) out.add(allPaths[i2]);
      } else {
        if (p.index < 0 || p.index >= allPaths.length) continue;
        out.add(allPaths[p.index]);
      }
    }
    return out;
  }

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

    final grid = _isGridMode;
    final jumpIdx = grid ? targetIdx ~/ 2 : targetIdx;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_itemScrollController.isAttached) return;
      _itemScrollController.jumpTo(index: jumpIdx);
    });
  }

  void _recordCurrentScroll() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    var minIdx = 1 << 30;
    for (final p in positions) {
      if (p.index < minIdx) minIdx = p.index;
    }
    if (minIdx < (1 << 30)) {
      final grid = _isGridMode;
      final fileIdx = grid ? minIdx * 2 : minIdx;
      _dirScrollPositions[_currentPath] = fileIdx;
    }
  }

  void _restoreDirScroll() {
    final saved = _dirScrollPositions[_currentPath];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_itemScrollController.isAttached) return;
      final fileIdx = (saved != null && saved > 0) ? saved : 0;
      final grid = _isGridMode;
      final jumpIdx = grid ? fileIdx ~/ 2 : fileIdx;
      _itemScrollController.jumpTo(index: jumpIdx);
    });
  }

  void _navigateTo(String path) {
    // 规范化：去掉末尾多余的斜杠（避免 /storage/ 和 /storage 不一致，
    // 导致降级判断失效）
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path == _currentPath) return;

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

  bool get _canGoUp => _currentPath != _topPath;

  void _goUp() {
    if (!_canGoUp) return;
    final parent = Directory(_currentPath).parent.path;
    if (!parent.startsWith(_topPath)) return;

    // 跳过 /storage/emulated 这一层：Android 11+ 禁止 list 它。
    // 从 /storage/emulated/0（或 999 等）上一级，直接退到 /storage。
    if (parent == '/storage/emulated') {
      _navigateTo(_topPath);
      return;
    }

    _navigateTo(parent);
  }

  List<EntryInfo> _listStorageRoot() {
    final log = ReaderLoadLog.instance;
    log.info('[Storage] 手动构造 /storage 条目');

    final out = <EntryInfo>[];
    final seen = <String>{};

    void addDir(String path, String name) {
      if (seen.contains(path)) return;
      final dir = Directory(path);
      if (!dir.existsSync()) return;
      seen.add(path);
      out.add(EntryInfo(entity: dir, name: name, isDir: true));
    }

    addDir('/storage/emulated/0', '内部存储');

    try {
      final raw =
          Directory('/storage/emulated').listSync(followLinks: false);
      for (final e in raw) {
        if (e is! Directory) continue;
        final name = e.path.split('/').last;
        if (name == '0' || name == 'self') continue;
        if (!RegExp(r'^\d+$').hasMatch(name)) continue;
        addDir(e.path, '双开($name)');
      }
    } catch (_) {}

    final uuidPattern = RegExp(r'([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4})');
    const sources = <String>[
      '/proc/mounts',
      '/proc/self/mountinfo',
      '/proc/self/mounts',
      '/etc/mtab',
    ];

    final uuids = <String>{};
    for (final src in sources) {
      try {
        final content = File(src).readAsStringSync();
        for (final m in uuidPattern.allMatches(content)) {
          uuids.add(m.group(1)!);
        }
        if (uuids.isNotEmpty) {
          log.info('[Storage] 从 $src 找到 ${uuids.length} 个 UUID');
          break;
        }
      } catch (e) {
        log.info('[Storage] 读 $src 失败：$e');
      }
    }

    for (final uuid in uuids) {
      if (Directory('/storage/$uuid').existsSync()) {
        addDir('/storage/$uuid', '外部存储($uuid)');
      } else if (Directory('/mnt/media_rw/$uuid').existsSync()) {
        addDir('/mnt/media_rw/$uuid', '外部存储($uuid)');
      }
    }

    log.info(
        '[Storage] 共找到 ${out.length} 个条目：${out.map((e) => e.name).join(", ")}');
    return out;
  }

  void _clearSelection() {
    _selectionMode = false;
    _selectedPaths.clear();
    _anchorPath = null;
  }

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

  List<String> get _currentDisplayedPaths {
    if (_searchActive) {
      return _searchResults.map((h) => h.path).toList();
    }
    return (_entries ?? const <EntryInfo>[])
        .map((e) => e.entity.path)
        .toList();
  }

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

  Future<void> _openFile(String path, String name, int? size) async {
    final log = ReaderLoadLog.instance;
    log.info('[Browser] 点击文件 name=$name  size=$size');
    final tOpen = DateTime.now();

    final isText = _textExts.contains(_extOf(name));

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
        break;
    }
  }

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

    final tPush = DateTime.now();
    final openedPath = path;
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

    final deleted = ref.read(readerDeletedPathsProvider);
    final tFilter = DateTime.now();
    if (deleted.isNotEmpty) {
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
        DirCache.instance.applyToAll(
          _currentPath,
          (list) => list.where((e) => !deletedSet.contains(e.path)).toList(),
        );
      }
    }

    if (result != null && result != openedPath) {
      _scrollToPath(result);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recordCurrentScroll();
      });
    }
    log.info(
        '[Browser→Reader] 全流程耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
  }

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

  void _scrollToPath(String path) {
    int index = -1;
    if (_searchActive) {
      index = _searchResults.indexWhere((h) => h.path == path);
    } else {
      index = (_entries ?? const <EntryInfo>[])
          .indexWhere((e) => e.entity.path == path);
    }
    if (index < 0) return;

    final grid = _isGridMode;
    final jumpIdx = grid ? index ~/ 2 : index;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_itemScrollController.isAttached) return;
      _itemScrollController.jumpTo(index: jumpIdx);
    });
  }

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
        rootPath: _topPath,
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
      ref.read(editedOriginalProvider.notifier).state = null;
      ref.read(editedModifiedProvider.notifier).state = null;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const DiffViewerScreen(),
        ),
      );
      if (!mounted) return;
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

  // ==================== 视图弹窗（替代原来的排序弹窗） ====================

  Future<void> _showViewDialog() async {
    await showDialog<void>(
      context: context,
      builder: (c) => Consumer(
        builder: (c, ref, _) {
          final gridMode = ref.watch(browserGridModeProvider);
          final gridShowSize = ref.watch(browserGridShowSizeProvider);
          final gridShowTime = ref.watch(browserGridShowTimeProvider);
          final fontListName = ref.watch(browserFontListNameProvider);
          final fontListMeta = ref.watch(browserFontListMetaProvider);
          final fontGridName = ref.watch(browserFontGridNameProvider);
          final fontGridMeta = ref.watch(browserFontGridMetaProvider);
          final sortField = ref.watch(sortFieldProvider);
          final sortAsc = ref.watch(sortAscProvider);

          return AlertDialog(
            insetPadding: _dlgInset,
            titlePadding: _dlgTitlePad,
            contentPadding: _dlgContentPad,
            actionsPadding: _dlgActionsPad,
            title: const Text('视图'),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(c).size.height * 0.75,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ---------- 显示方式 ----------
                    _viewSectionTitle('显示方式'),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('列表'),
                          selected: !gridMode,
                          onSelected: (_) {
                            ref
                                .read(browserGridModeProvider.notifier)
                                .update(false);
                          },
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('网格'),
                          selected: gridMode,
                          onSelected: (_) {
                            ref
                                .read(browserGridModeProvider.notifier)
                                .update(true);
                          },
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 8),

                    // ---------- 网格显示内容（仅网格） ----------
                    if (gridMode) ...[
                      _viewSectionTitle('网格显示内容'),
                      Row(
                        children: [
                          const Text('显示大小',
                              style: TextStyle(fontSize: 13)),
                          const SizedBox(width: 8),
                          Switch(
                            value: gridShowSize,
                            onChanged: (v) => ref
                                .read(browserGridShowSizeProvider.notifier)
                                .update(v),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const Text('显示时间',
                              style: TextStyle(fontSize: 13)),
                          const SizedBox(width: 8),
                          Switch(
                            value: gridShowTime,
                            onChanged: (v) => ref
                                .read(browserGridShowTimeProvider.notifier)
                                .update(v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                    ],

                    // ---------- 字号（按当前模式显示对应两项） ----------
                    _viewSectionTitle('字号'),
                    const SizedBox(height: 4),
                    if (!gridMode) ...[
                      _FontSizeRow(
                        key: const ValueKey('fontListName'),
                        label: '文件名',
                        value: fontListName,
                        onChanged: (v) => ref
                            .read(browserFontListNameProvider.notifier)
                            .set(v),
                      ),
                      _FontSizeRow(
                        key: const ValueKey('fontListMeta'),
                        label: '大小 / 时间',
                        value: fontListMeta,
                        onChanged: (v) => ref
                            .read(browserFontListMetaProvider.notifier)
                            .set(v),
                      ),
                    ] else ...[
                      _FontSizeRow(
                        key: const ValueKey('fontGridName'),
                        label: '文件名',
                        value: fontGridName,
                        onChanged: (v) => ref
                            .read(browserFontGridNameProvider.notifier)
                            .set(v),
                      ),
                      _FontSizeRow(
                        key: const ValueKey('fontGridMeta'),
                        label: '大小 / 时间',
                        value: fontGridMeta,
                        onChanged: (v) => ref
                            .read(browserFontGridMetaProvider.notifier)
                            .set(v),
                      ),
                    ],

                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 8),

                    // ---------- 排序方式 ----------
                    _viewSectionTitle('排序方式'),
                    for (final f in SortField.values)
                      RadioListTile<SortField>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(_sortLabel(f)),
                        value: f,
                        groupValue: sortField,
                        onChanged: (v) {
                          if (v == null) return;
                          ref.read(sortFieldProvider.notifier).update(v);
                          _load();
                        },
                      ),
                    const Divider(),
                    RadioListTile<bool>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('升序'),
                      value: true,
                      groupValue: sortAsc,
                      onChanged: (_) {
                        ref.read(sortAscProvider.notifier).update(true);
                        _load();
                      },
                    ),
                    RadioListTile<bool>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('降序'),
                      value: false,
                      groupValue: sortAsc,
                      onChanged: (_) {
                        ref.read(sortAscProvider.notifier).update(false);
                        _load();
                      },
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
          );
        },
      ),
    );
  }

  Widget _viewSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
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
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
    }
  }

  Future<void> _importConfig() async {
    final result = await ConfigIoService.instance.import();
    if (!mounted) return;

    if (!result.ok && result.message == null) return;

    if (!result.ok) {
      _toast(result.message ?? '导入失败');
      return;
    }

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
    if (!target.startsWith('/storage/')) {
      _toast('只能跳到 /storage 以内的路径');
      return;
    }
    _navigateTo(target);
  }

  Future<String?> _pickDirectory(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => DirectoryPickerDialog(
        title: title,
        rootPath: _topPath,
        initialPath: _currentPath,
      ),
    );
  }

  // ==================== 面包屑 ====================

  List<({String label, String path})> get _crumbs {
    if (_currentPath == _topPath) {
      return [(label: '存储', path: _topPath)];
    }

    if (_currentPath == _rootPath ||
        _currentPath.startsWith('$_rootPath/')) {
      final out = <({String label, String path})>[
        (label: '内部存储', path: _rootPath),
      ];
      final relative = _currentPath.substring(_rootPath.length);
      final segments =
          relative.split('/').where((s) => s.isNotEmpty).toList();
      var acc = _rootPath;
      for (final seg in segments) {
        acc = '$acc/$seg';
        out.add((label: seg, path: acc));
      }
      return out;
    }

    // 其它 /storage 下的路径（SD 卡、U 盘、双开等）
    final out = <({String label, String path})>[
      (label: '存储', path: _topPath),
    ];
    if (!_currentPath.startsWith('$_topPath/')) return out;
    final relative = _currentPath.substring(_topPath.length);
    final segments =
        relative.split('/').where((s) => s.isNotEmpty).toList();

    // 跳过 "emulated" 这一级：它是中间目录，用户不需要看到。
    var acc = _topPath;
    for (final seg in segments) {
      acc = '$acc/$seg';
      if (seg == 'emulated') continue;
      out.add((label: _crumbLabelFor(acc, seg), path: acc));
    }
    return out;
  }

  String _crumbLabelFor(String fullPath, String segment) {
    if (segment == 'emulated') return 'emulated';
    if (segment == 'self') return 'self';
    if (fullPath == _rootPath) return '内部存储';
    if (fullPath.startsWith('$_topPath/emulated/')) {
      return '双开($segment)';
    }
    if (RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$').hasMatch(segment)) {
      return '外部存储($segment)';
    }
    return segment;
  }

  Widget _buildBreadcrumbs() {
    final crumbs = _crumbs;
    final s = Theme.of(context).colorScheme;
    final widgets = <Widget>[];
    for (var i = 0; i < crumbs.length; i++) {
      final c = crumbs[i];
      final isLast = i == crumbs.length - 1;
      if (i > 0) {
        widgets.add(Icon(
          Icons.chevron_right,
          size: 16,
          color: _selectionMode ? Colors.grey.shade300 : s.outline,
        ));
      }
      widgets.add(
        GestureDetector(
          onTap: (_selectionMode || isLast)
              ? null
              : () => _navigateTo(c.path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              c.label,
              style: TextStyle(
                fontSize: 12,
                color: _selectionMode
                    ? Colors.grey.shade400
                    : (isLast ? Colors.black : Colors.black54),
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

  /// 网格模式用的短时间格式：`MM-DD HH:mm`。
  static String _formatGridTime(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  String get _title {
    if (_currentPath == _topPath) return '存储';
    if (_currentPath == _rootPath) return '内部存储';
    return _currentPath.split('/').last;
  }

  String _relPath(String fullPath) {
    if (fullPath == _rootPath) return '~/';
    if (fullPath.startsWith('$_rootPath/')) {
      return '~${fullPath.substring(_rootPath.length)}';
    }
    return fullPath;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoUp &&
          _currentPath != _topPath &&
          !_selectionMode &&
          !_searchActive,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 返回键优先级：先取消选中 → 再退搜索 → 再回内部存储 → 最后上一级。
        if (_selectionMode) {
          setState(_clearSelection);
        } else if (_searchActive) {
          _clearSearch();
        } else if (_currentPath == _topPath) {
          // 在 /storage 顶层按返回 → 回内部存储
          _navigateTo(_rootPath);
        } else if (_canGoUp) {
          _goUp();
        }
      },
      child: Scaffold(
        appBar:
            _selectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
        body: Column(
          children: [
            _buildBreadcrumbs(),
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
          : (_currentPath == _topPath
              ? _smallBackButton(
                  onPressed: () => _navigateTo(_rootPath),
                )
              : (_canGoUp
                  ? _smallBackButton(onPressed: _goUp)
                  : null)),
      actions: [
        IconButton(
          icon: Icon(
            isFav ? Icons.star : Icons.star_border,
            color: isFav ? Colors.amber : null,
          ),
          tooltip: isFav ? '取消收藏此目录' : '收藏此目录',
          onPressed: _toggleFavorite,
        ),
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
              case 'view':
                _showViewDialog();
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
              value: 'view',
              child: Row(
                children: [
                  Icon(Icons.grid_view),
                  SizedBox(width: 10),
                  Text('视图'),
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

  /// 小号返回按钮：图标保持常规大小，但**点击热区缩到很小**。
  /// 用于 /storage 和它的下级——避免误触跳走。
  Widget _smallBackButton({required VoidCallback onPressed}) {
    return Center(
      child: SizedBox(
        width: 36,
        height: 36,
        child: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 36,
            maxWidth: 36,
            maxHeight: 36,
          ),
          tooltip: null,
        ),
      ),
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    final all = _currentDisplayedPaths;
    final allSelected =
        all.isNotEmpty && all.every((p) => _selectedPaths.contains(p));
    return AppBar(
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
                    label: const Text(
                      '对比',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
                    onPressed: canMd5 ? _md5Compare : null,
                    child: const Text(
                      'MD5',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
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
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
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
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
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
                    icon: Icons.info_outline,
                    label: '属性',
                    onPressed: canProps ? _showProperties : null,
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
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: c,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 主体 ====================

  Widget _buildBody() {
    if (_searchActive) {
      return _buildSearchResultsList();
    }
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

    return ref.watch(browserGridModeProvider)
        ? _buildGridBody(entries)
        : _buildListBody(entries);
  }

  // ==================== 列表模式 ====================

  Widget _buildListBody(List<EntryInfo> entries) {
    final fontName = ref.watch(browserFontListNameProvider);
    final fontMeta = ref.watch(browserFontListMetaProvider);

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

        final tile = ListTile(
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
            style: TextStyle(
              fontSize: fontName,
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (metaLine.isNotEmpty)
                Text(
                  metaLine,
                  style: TextStyle(
                    fontSize: fontMeta,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant,
                  ),
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
        );

        return RepaintBoundary(
          key: ValueKey('rb_list_${e.path}'),
          child: selected
              ? Container(
                  foregroundDecoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  child: tile,
                )
              : tile,
        );
      },
    );
  }

  // ==================== 网格模式 ====================

  Widget _buildGridBody(List<EntryInfo> entries) {
    final showSize = ref.watch(browserGridShowSizeProvider);
    final showTime = ref.watch(browserGridShowTimeProvider);
    final fontName = ref.watch(browserFontGridNameProvider);
    final fontMeta = ref.watch(browserFontGridMetaProvider);

    // 行数 = ceil(文件数 / 2)
    final rowCount = (entries.length + 1) ~/ 2;

    return ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: rowCount,
      itemBuilder: (ctx, rowIdx) {
        final leftIdx = rowIdx * 2;
        final rightIdx = leftIdx + 1;

        final leftInfo = entries[leftIdx];
        final rightInfo =
            rightIdx < entries.length ? entries[rightIdx] : null;

        final leftWidget = _buildGridCell(
          info: leftInfo,
          showSize: showSize,
          showTime: showTime,
          fontName: fontName,
          fontMeta: fontMeta,
          isFirstCol: true,
        );

        final rightWidget = rightInfo == null
            ? const SizedBox.shrink()
            : _buildGridCell(
                info: rightInfo,
                showSize: showSize,
                showTime: showTime,
                fontName: fontName,
                fontMeta: fontMeta,
                isFirstCol: false,
              );

        // 行分隔线：整行底部画一条。
        // 竖分隔线：两列之间画一条，贯穿整行高度。
        // 用 IntrinsicHeight 让左右等高于较高者，矮的一侧下方留白。
        return RepaintBoundary(
          key: ValueKey('rb_grid_$rowIdx'),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: leftWidget),
                // 竖分隔线
                Container(
                  width: _gridDividerThickness,
                  color: _gridDividerColor,
                ),
                Expanded(child: rightWidget),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGridCell({
    required EntryInfo info,
    required bool showSize,
    required bool showTime,
    required double fontName,
    required double fontMeta,
    required bool isFirstCol,
  }) {
    final e = info.entity;
    final selected = _selectedPaths.contains(e.path);

    // 元信息行：大小 + 时间，按开关决定。
    final metaParts = <String>[];
    if (showSize && !info.isDir && info.size != null) {
      metaParts.add(_formatSize(info.size));
    }
    if (showTime && info.modified != null) {
      metaParts.add(_formatGridTime(info.modified!));
    }
    final metaLine = metaParts.join(' · ');

    return GestureDetector(
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
   
        
        
        
        
        
        

        

child: Container(
  decoration: BoxDecoration(
    color: selected
        ? _gridSelectedBg
        : (info.isDir
            ? null
            : (_textExts.contains(_extOf(info.name))
                ? null
                // 打不开的文件：浅一点的灰背景（比白色深一档）
                : const Color(0xFFF0F0F0))),
    border: selected
        ? Border.all(
            color: Theme.of(context).colorScheme.primary,
            width: 2,
          )
        : Border(
            bottom: BorderSide(
              color: _gridDividerColor,
              width: _gridDividerThickness,
            ),
          ),
  ),




            
        padding: EdgeInsets.symmetric(
          horizontal: _gridCellPadH,
          vertical: _gridCellPadV,
        ),
        // 用 IntrinsicHeight（外层）已经保证了左右等高，
        // 这里用 Column + mainAxisSize.min，内容顶对齐，矮的下面留白。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildGridName(info, fontName),
            if (metaLine.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                metaLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontMeta,
                  color:
                      Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 网格模式的文件名。
  ///
  /// 规则：
  ///   · 文件夹：黑色加粗，前后加 `/`
  ///   · 大文本（能打开 且 >3MB）：主体黑加粗，后缀灰 + 正常字重
  ///   · 其它：黑色加粗
  Widget _buildGridName(EntryInfo info, double fontSize) {
    // 文件夹：前后加斜杠
    if (info.isDir) {
      return Text(
        '/${info.name}/',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      );
    }

    final name = info.name;

    // 是否"大文本"：能打开的文本 + > 3 MiB
    final isText = _textExts.contains(_extOf(name));
    final isLarge = isText &&
        info.size != null &&
        info.size! > 3 * 1024 * 1024;

    // 找后缀位置（含点）
    final dotIdx = name.lastIndexOf('.');
    final hasExt = dotIdx > 0 && dotIdx < name.length - 1;

    // 非大文件，或没有后缀：整体黑加粗
    if (!isLarge || !hasExt) {
      return Text(
        name,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      );
    }

    // 大文本：主体黑加粗，后缀灰不加粗
    final base = name.substring(0, dotIdx);
    final ext = name.substring(dotIdx);

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: base,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(
            text: ext,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.normal,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  // ==================== 搜索模式列表 ====================

  Widget _buildSearchResultsList() {
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

/// 一行字号设置：标签 + [- 数字 +]。
///
/// 值范围 1~38。数字用 TextEditingController 保持同步，用户随时
/// 可以改数字或按加减。
class _FontSizeRow extends StatefulWidget {
  const _FontSizeRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_FontSizeRow> createState() => _FontSizeRowState();
}

class _FontSizeRowState extends State<_FontSizeRow> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value.round().toString());
  }

  @override
  void didUpdateWidget(covariant _FontSizeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部值变了（比如 +/- 按钮触发），刷新输入框。
    final cur = widget.value.round().toString();
    if (_ctrl.text != cur) {
      _ctrl.text = cur;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _step(int delta) {
    final next = (widget.value.round() + delta).clamp(1, 38).toDouble();
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(widget.label, style: const TextStyle(fontSize: 13)),
          ),
          IconButton(
            icon: const Icon(Icons.remove),
            visualDensity: VisualDensity.compact,
            onPressed: () => _step(-1),
          ),
          SizedBox(
            width: 56,
            child: TextFormField(
              controller: _ctrl,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              ),
              onFieldSubmitted: (v) {
                final n = int.tryParse(v.trim());
                if (n == null) {
                  _ctrl.text = widget.value.round().toString();
                  return;
                }
                final clamped = n.clamp(1, 38).toDouble();
                widget.onChanged(clamped);
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            visualDensity: VisualDensity.compact,
            onPressed: () => _step(1),
          ),
        ],
      ),
    );
  }
}

/// 自定义搜索文件夹的勾选器。
///
/// 顶部有路径跳转输入框（抄自 DirectoryPickerDialog，高度略矮）。
/// 底部工具条有"全选"chip 和"区间"chip。
///
/// 区间模式：
///   - 点"区间"chip 进入。标题栏替换为提示文字，字号 16→14，颜色转蓝。
///   - 点第一行 → 记起点（行加浅蓝背景）。标题变成"再点一行设为终点"。
///   - 点第二行 → 两端之间（含两端）全部勾上；自动退出区间模式。
///   - 期间点右侧 `>` 箭头仍可进子目录，并退出区间模式。
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
  /// 内部存储根路径（用于相对路径显示）。
  static const String _internalRoot = '/storage/emulated/0';

  /// 区间色（蓝）。
  static const Color _rangeBlue = Color(0xFF3D7CFF);

  /// 起点高亮背景（同蓝色 20% 透明）。
  static const Color _rangeHighlight = Color(0x333D7CFF);

  late String _path;
  late List<String> _selected;
  late final TextEditingController _jumpCtrl;
  List<Directory> _dirs = const [];
  bool _loading = true;

  // ========== 区间选择 ==========
  bool _rangeMode = false;
  String? _rangeAnchorPath;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _selected = List<String>.from(widget.initialSelected);
    _jumpCtrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _jumpCtrl.dispose();
    super.dispose();
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
      _rangeAnchorPath = null;
    });
    _load();
  }

  /// 相对路径显示：
  /// - 就在 rootPath（/storage）：显示 "~/"
  /// - 在内部存储（/storage/emulated/0）下：显示 "~" + 相对内部存储的路径
  /// - 其他情况：显示完整路径
  String get _relPath {
    if (_path == widget.rootPath) return '~/';
    if (_path == _internalRoot || _path.startsWith('$_internalRoot/')) {
      final sub = _path.substring(_internalRoot.length);
      return sub.isEmpty ? '~' : '~$sub';
    }
    return _path;
  }

  // ==================== 路径跳转 ====================

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
      _rangeAnchorPath = null;
    });
    _load();
  }

  // ==================== 勾选 ====================

  void _toggle(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  // ==================== 全选 ====================

  /// 当前视图是否"全部已勾选"。空视图返回 false。
  bool get _allVisibleSelected {
    if (_dirs.isEmpty) return false;
    for (final d in _dirs) {
      if (!_selected.contains(d.path)) return false;
    }
    return true;
  }

  void _toggleSelectAll() {
    setState(() {
      if (_allVisibleSelected) {
        for (final d in _dirs) {
          _selected.remove(d.path);
        }
      } else {
        for (final d in _dirs) {
          if (!_selected.contains(d.path)) _selected.add(d.path);
        }
      }
    });
  }

  // ==================== 区间选择 ====================

  void _toggleRangeMode() {
    setState(() {
      _rangeMode = !_rangeMode;
      _rangeAnchorPath = null;
    });
  }

  /// 区间模式下点某一行：第一次设锚点，第二次把区间内全勾上，自动退出。
  void _handleRangeTap(String path) {
    final anchor = _rangeAnchorPath;
    if (anchor == null) {
      setState(() => _rangeAnchorPath = path);
      return;
    }

    final visible = _dirs.map((d) => d.path).toList();
    final from = visible.indexOf(anchor);
    final to = visible.indexOf(path);
    if (from < 0 || to < 0) {
      // 锚点被换目录冲掉了 → 重设
      setState(() => _rangeAnchorPath = path);
      return;
    }
    final lo = from < to ? from : to;
    final hi = from < to ? to : from;

    setState(() {
      for (var i = lo; i <= hi; i++) {
        _selected.add(visible[i]);
      }
      // 自动退出区间模式
      _rangeMode = false;
      _rangeAnchorPath = null;
    });
  }

  // ==================== 已勾选查看 ====================

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

  // ==================== 标题 ====================

  String get _titleText {
    if (_rangeMode) {
      return _rangeAnchorPath == null ? '点一行内容为起点' : '再点一行内容为终点';
    }
    return '点击左侧方框勾选对应文件夹';
  }

  double get _titleSize => _rangeMode ? 14.0 : 16.0;

  Color? get _titleColor => _rangeMode ? _rangeBlue : null;

  // ==================== build ====================

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: _dlgInsetG,
      titlePadding: _dlgTitlePadG,
      contentPadding: EdgeInsets.zero,
      actionsPadding: _dlgActionsPadG,
      title: Text(
        _titleText,
        style: TextStyle(
          fontSize: _titleSize,
          fontWeight: FontWeight.bold,
          color: _titleColor,
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- 路径跳转 ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _jumpCtrl,
                      cursorColor: AppColors.accentPurple,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        hintText: '粘贴路径跳转',
                        isDense: true,
                        border: OutlineInputBorder(),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(
                            color: AppColors.accentPurple,
                            width: 2,
                          ),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                      ),
                      onSubmitted: (v) => _jumpToPath(v.trim()),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    color: AppColors.accentPurple,
                    tooltip: '跳转',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _jumpToPath(_jumpCtrl.text.trim()),
                  ),
                ],
              ),
            ),

            // ---------- 上一级 + 当前路径 ----------
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
                        _relPath,
                        style: Theme.of(context).textTheme.labelSmall,
                        maxLines: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // ---------- 列表 ----------
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
                            final isAnchor = d.path == _rangeAnchorPath;

                            return Container(
                              color: isAnchor ? _rangeHighlight : null,
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 4),
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
                                            color: _rangeMode
                                                ? Colors.grey.shade300
                                                : (selected
                                                    ? Theme.of(context)
                                                        .colorScheme
                                                        .primary
                                                    : null),
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
                                trailing: InkWell(
                                  onTap: () {
                                    // 进子目录：同时退出区间模式
                                    setState(() {
                                      _path = d.path;
                                      _rangeMode = false;
                                      _rangeAnchorPath = null;
                                    });
                                    _load();
                                  },
                                  child: const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Icon(Icons.chevron_right),
                                  ),
                                ),
                                onTap: () {
                                  if (_rangeMode) {
                                    _handleRangeTap(d.path);
                                    return;
                                  }
                                  setState(() {
                                    _path = d.path;
                                    _rangeAnchorPath = null;
                                  });
                                  _load();
                                },
                              ),
                            );
                          },
                        ),
            ),

            const Divider(height: 1),

            // ---------- 工具条 ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
              child: Row(
                children: [
                  // 全选 chip（白底黑字）
                  FilterChip(
                    label: const Text('全选'),
                    selected: _allVisibleSelected,
                    onSelected: (_) => _toggleSelectAll(),
                    backgroundColor: Colors.white,
                    selectedColor: Colors.white,
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    checkmarkColor: AppColors.accentPurple,
                    labelStyle: const TextStyle(
                      fontSize: 12,
                      color: Colors.black,
                      fontWeight: FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: _allVisibleSelected
                          ? AppColors.accentPurple
                          : Colors.grey.shade400,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),

                  const SizedBox(width: 24),

                  // 区间 chip（白底黑字）
                  FilterChip(
                    label: const Text('区间'),
                    selected: _rangeMode,
                    onSelected: (_) => _toggleRangeMode(),
                    backgroundColor: Colors.white,
                
                      selectedColor: _rangeBlue.withOpacity(0.12),
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    checkmarkColor: _rangeBlue,
                    labelStyle: const TextStyle(
                      fontSize: 12,
                      color: Colors.black,
                      fontWeight: FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: _rangeMode
                          ? _rangeBlue
                          : Colors.grey.shade400,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),

                  const Spacer(),

                  // 已勾选计数 + 查看
                  Text(
                    '已勾选 ${_selected.length} 个',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(width: 4),
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
