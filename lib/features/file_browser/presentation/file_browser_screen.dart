import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:charset/charset.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../../core/constants/app_colors.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../parser/application/document_parser.dart';
import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../../reader/reader_load_log.dart';
import '../../reader/reader_repository.dart';
import '../../reader/reader_screen.dart';
import '../../viewer/presentation/diff_viewer_screen.dart';
import 'browser_settings_screen.dart';
import 'comparison_settings_screen.dart';
import 'config_io_service.dart';
import 'dialogs/directory_picker_dialog.dart';
import 'dir_loader.dart';
import 'file_open_helper.dart';
import 'line_editor_screen.dart';
import 'providers/file_browser_providers.dart';
import 'single_file_editor_screen.dart';

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

// ==================== 统一列表项 ====================

/// 列表里的一个条目。可能是磁盘文件、磁盘目录、zip、zip 内文件、zip 内目录。
///
/// [key] 是唯一标识：
///   · 磁盘文件/目录：就是完整路径
///   · zip 内文件/目录：'zip://<zip 完整路径>§<zip 内路径>'
///
/// [ownerZipKey] 非空表示此项属于某个展开的 zip（用于粘性头部和缩进）。
class _DisplayItem {
  const _DisplayItem({
    required this.key,
    required this.displayName,
    required this.depth,
    this.isDir = false,
    this.isZip = false,
    this.isZipInner = false,
    this.size,
    this.modified,
    this.diskEntry,
    this.searchHit,
    this.ownerZipKey,
    this.innerPath,
    this.innerPathForDisplay,
    this.innerArchive,
  });

  final String key;
  final String displayName;
  final int depth;

  final bool isDir;
  final bool isZip;
  final bool isZipInner;

  final int? size;
  final DateTime? modified;

  final EntryInfo? diskEntry;
  final _SearchHit? searchHit;

  /// 若非空，此项属于该 zip（zip 的 key = 磁盘路径）。
  final String? ownerZipKey;

  /// zip 内路径（相对于 ownerZipKey 对应 zip 的根）。
  /// 若此项来自嵌套 zip，用 'inner.zip>readme.txt' 这种形式。
  final String? innerPath;

  /// 显示用的完整嵌套路径（可能带 '>' 前缀）。
  /// 跟 [innerPath] 的区别：
  ///   · innerPath          = 当前层 archive 内的实际路径，用于 findFile
  ///   · innerPathForDisplay = 带嵌套前缀的完整路径，用于显示
  final String? innerPathForDisplay;

  /// 此项所在层的 archive。用于读取内容。只有 zip 内项才有。
  final Archive? innerArchive;

  /// 是否为磁盘上的真实文件（用于判断能不能操作）。
  bool get isDiskItem => diskEntry != null || searchHit != null;

  /// 是不是可以展开的（zip 文件）。
  bool get canExpand => isZip;

  /// 提取磁盘路径（仅磁盘项有）。
  String? get diskPath => diskEntry?.path ?? searchHit?.path;

  /// 加 prefix 得到显示路径（面包屑样）。
  String get fullDisplayPath {
    if (ownerZipKey == null) return displayName;
    final zipName = ownerZipKey!.split('/').last;
    final inner = innerPathForDisplay ?? displayName;
    return '$zipName > $inner';
  }
}

// ==================== 虚拟 key 工具 ====================

/// zip 内项的 key 前缀。
const String _zipInnerPrefix = 'zip://';

/// 分隔符：zip 磁盘路径 + '§' + zip 内路径。
const String _zipInnerSep = '§';

bool _isZipInnerKey(String key) => key.startsWith(_zipInnerPrefix);

String _makeZipInnerKey(String zipPath, String innerPath) =>
    '$_zipInnerPrefix$zipPath$_zipInnerSep$innerPath';

String _zipPathFromInnerKey(String key) {
  final body = key.substring(_zipInnerPrefix.length);
  final idx = body.indexOf(_zipInnerSep);
  return idx < 0 ? body : body.substring(0, idx);
}

String _innerPathFromInnerKey(String key) {
  final body = key.substring(_zipInnerPrefix.length);
  final idx = body.indexOf(_zipInnerSep);
  return idx < 0 ? '' : body.substring(idx + _zipInnerSep.length);
}

// ==================== 判断 zip / tar 文件名 ====================

bool _isExpandableArchiveName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz');
}

// ==================== 从 archive 里读直接子节点 ====================

class _ZipNode {
  const _ZipNode({
    required this.name,
    required this.fullPath,
    required this.isDir,
    required this.isZip,
    required this.size,
  });

  final String name;
  final String fullPath;
  final bool isDir;
  final bool isZip;
  final int size;
}

List<_ZipNode> _directZipChildren(Archive archive, String at) {
  final prefix = at.isEmpty ? '' : '$at/';
  final dirNames = <String>{};
  final fileMap = <String, ArchiveFile>{};

  for (final f in archive.files) {
    final name = f.name;
    if (name.isEmpty) continue;
    if (name.startsWith('__MACOSX/')) continue;
    if (!name.startsWith(prefix)) continue;
    final rest = name.substring(prefix.length);
    if (rest.isEmpty) continue;

    final slash = rest.indexOf('/');
    if (slash < 0) {
      if (f.isFile) {
        fileMap[rest] = f;
      } else {
        dirNames.add(rest);
      }
    } else {
      dirNames.add(rest.substring(0, slash));
    }
  }

  final out = <_ZipNode>[];
  for (final name in dirNames) {
    out.add(_ZipNode(
      name: name,
      fullPath: '$prefix$name',
      isDir: true,
      isZip: false,
      size: 0,
    ));
  }
  for (final e in fileMap.entries) {
    final name = e.key;
    out.add(_ZipNode(
      name: name,
      fullPath: '$prefix$name',
      isDir: false,
      isZip: _isExpandableArchiveName(name),
      size: e.value.size,
    ));
  }

  out.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

// ==================== 主状态类（开始） ====================

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

  // 网格常量
  static const double _gridCellPadH = 8.0;
  static const double _gridCellPadV = 6.0;
  static const double _gridDividerThickness = 0.5;
  static const Color _gridDividerColor = Color(0xFFE0E0E0);
  static const Color _gridSelectedBg = Color(0xFFFFF3FB);

  // 扩展名集合
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
    if (_isExpandableArchiveName(name)) return Colors.blue.shade600;
    if (_binaryExts.contains(ext)) return Colors.orange.shade700;
    return Colors.grey.shade600;
  }

  // ==================== 状态字段 ====================

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

  // ==================== zip 展开状态 ====================

  /// 已展开的 zip 的 key（磁盘路径）。
  final Set<String> _expandedZipKeys = <String>{};

  /// 已加载的 zip 内容。key = zip 磁盘路径。
  final Map<String, Archive> _zipArchives = <String, Archive>{};

  /// 正在加载的 zip。key = zip 磁盘路径。
  final Set<String> _loadingZipKeys = <String>{};

  /// zip 展开失败原因。key = zip 磁盘路径。
  final Map<String, String> _zipErrors = <String, String>{};

  /// 当前固定显示的粘性头部对应的 zip key。null = 不显示。
  /// ★ 粘性头部已停用，此字段保留但始终为 null。
  String? _stickyZipKey;

  /// 缓存：每次 build 后重新计算的 display 列表。
  List<_DisplayItem>? _cachedDisplayItems;

  /// 缓存：每个 index 对应的 ownerZipKey（用于粘性头部判定）。
  List<String?>? _cachedOwnerZipPerIndex;

  /// 单次打开压缩包的大小上限。zip / tar / tar.gz / tgz 一视同仁。
  static const int _maxZipBytes = 50 * 1024 * 1024;

  /// 点击后直接弹系统 App 选择器的后缀。
  /// 不弹"打开方式 / 分享"两选一，直接出系统列表。
  static const Set<String> _forceSystemPickerExts = {
    '.7z', '.rar', '.dzip', '.iso', '.tz', '.gz',
    '.epub', '.pdf', '.doc', '.docx',
  };

  // ==================== 生命周期 ====================

  @override
  void initState() {
    super.initState();
    final saved = ref.read(lastPathProvider);
    _currentPath = _resolveInitialPath(saved);
    _positionsListener.itemPositions.addListener(_onPositionsChanged);
    _load();
  }

  String _resolveInitialPath(String saved) {
    if (saved.isEmpty) return _rootPath;
    if (!saved.startsWith(_topPath)) return _rootPath;
    if (!Directory(saved).existsSync()) return _rootPath;
    return saved;
  }

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
    _positionsListener.itemPositions.removeListener(_onPositionsChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  Route<T> _noAnimRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    );
  }

  // ==================== 滚动 → 粘性头部（已停用） ====================

  void _onPositionsChanged() {
    _recordCurrentScroll();
    // ★ 粘性头部已停用：改用图标区分展开/折叠，不再调用
    //   _updateStickyZip()。之前它会在 _stickyZipKey 变化时
    //   setState 导致 build 里 Stack 结构切换，ScrollablePositionedList
    //   被销毁重建，滚动位置丢失（表现为"往上滑突然跳回顶端"）。
  }

  /// 根据当前可见列表项，更新粘性 zip 头部。
  /// ★ 已停用，保留方法备查。
  // ignore: unused_element
  void _updateStickyZip() {
    final items = _cachedDisplayItems;
    if (items == null || items.isEmpty) {
      if (_stickyZipKey != null) {
        setState(() => _stickyZipKey = null);
      }
      return;
    }

    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) {
      if (_stickyZipKey != null) {
        setState(() => _stickyZipKey = null);
      }
      return;
    }

    int topIdx = 1 << 30;
    for (final p in positions) {
      if (p.itemLeadingEdge <= 0.0 && p.index < topIdx) {
        topIdx = p.index;
      }
    }
    if (topIdx == 1 << 30) {
      if (_stickyZipKey != null) {
        setState(() => _stickyZipKey = null);
      }
      return;
    }

    final sticky = _computeStickyZipForIndex(topIdx, items);
    if (_stickyZipKey != sticky) {
      setState(() => _stickyZipKey = sticky);
    }
  }

  /// 判断在 topIdx 这个滚动位置，哪个 zip 应该变粘性。
  /// ★ 已停用，保留方法备查。
  // ignore: unused_element
  String? _computeStickyZipForIndex(int topIdx, List<_DisplayItem> items) {
    if (topIdx < 0 || topIdx >= items.length) return null;
    final item = items[topIdx];
    if (item.isZip && item.ownerZipKey == null) return null;
    final owner = item.ownerZipKey;
    if (owner == null) return null;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it.isZip && it.key == owner && it.ownerZipKey == null) {
        if (i < topIdx) return owner;
        return null;
      }
    }
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it.isZip && it.key == owner) {
        if (i < topIdx) return owner;
        return null;
      }
    }
    return null;
  }

  // ==================== 显示列表构建 ====================

  /// 把磁盘条目 + zip 展开内容合并成一个扁平列表，供列表 UI 渲染。
  List<_DisplayItem> _buildDisplayItems() {
    final out = <_DisplayItem>[];

    if (_searchActive) {
      for (final hit in _searchResults) {
        final isZip = _isExpandableArchiveName(hit.name);
        final key = hit.path;
        out.add(_DisplayItem(
          key: key,
          displayName: hit.name,
          depth: 0,
          isZip: isZip,
          size: hit.size,
          modified: hit.modified,
          searchHit: hit,
        ));
        if (isZip && _expandedZipKeys.contains(key)) {
          _appendZipChildren(
            out: out,
            zipDiskPath: key,
            zipArchive: _zipArchives[key],
            at: '',
            innerPrefix: '',
            parentOwnerKey: null,
            depth: 1,
            error: _zipErrors[key],
            loading: _loadingZipKeys.contains(key),
          );
        }
      }
      return out;
    }

    // 普通浏览模式
    final entries = _entries ?? const <EntryInfo>[];
    for (final info in entries) {
      final isZip = !info.isDir && _isExpandableArchiveName(info.name);
      final key = info.entity.path;
      out.add(_DisplayItem(
        key: key,
        displayName: info.name,
        depth: 0,
        isDir: info.isDir,
        isZip: isZip,
        size: info.size,
        modified: info.modified,
        diskEntry: info,
      ));
      if (isZip && _expandedZipKeys.contains(key)) {
        _appendZipChildren(
          out: out,
          zipDiskPath: key,
          zipArchive: _zipArchives[key],
          at: '',
          innerPrefix: '',
          parentOwnerKey: null,
          depth: 1,
          error: _zipErrors[key],
          loading: _loadingZipKeys.contains(key),
        );
      }
    }
    return out;
  }

  /// 把某个 zip 内 `at` 路径下的子节点（递归）加到 out 里。
  ///
  /// [zipDiskPath] 是最外层 zip 的磁盘路径（用于拼 key）。
  /// [innerPrefix] 是"已经走过的 zip 内路径"，顶层 zip 直接子节点传 ''。
  /// [parentOwnerKey] 是此项归属的 zip key（粘性头部用）。
  void _appendZipChildren({
    required List<_DisplayItem> out,
    required String zipDiskPath,
    required Archive? zipArchive,
    required String at,
    required String innerPrefix,
    required String? parentOwnerKey,
    required int depth,
    String? error,
    bool loading = false,
  }) {
    if (depth == 1) {
      if (loading) {
        out.add(_DisplayItem(
          key: '__loading__$zipDiskPath',
          displayName: '正在加载…',
          depth: depth,
          ownerZipKey: zipDiskPath,
          isZipInner: true,
        ));
        return;
      }
      if (error != null) {
        out.add(_DisplayItem(
          key: '__error__$zipDiskPath',
          displayName: '加载失败：$error',
          depth: depth,
          ownerZipKey: zipDiskPath,
          isZipInner: true,
        ));
        return;
      }
    }
    if (zipArchive == null) return;

    final children = _directZipChildren(zipArchive, at);
    for (final c in children) {
      // 显示用的完整路径（带嵌套前缀）
      final innerFullForDisplay = innerPrefix.isEmpty
          ? c.fullPath
          : '$innerPrefix>${c.fullPath}';

      final nodeKey = _makeZipInnerKey(zipDiskPath, innerFullForDisplay);
      final ownerKey = parentOwnerKey ?? zipDiskPath;

      out.add(_DisplayItem(
        key: nodeKey,
        displayName: c.name,
        depth: depth,
        isDir: c.isDir,
        isZip: c.isZip,
        isZipInner: true,
        size: c.size,
        ownerZipKey: ownerKey,
        innerPath: c.fullPath,
        innerPathForDisplay: innerFullForDisplay,
        innerArchive: zipArchive,
      ));

      if (c.isDir) {
        _appendZipChildren(
          out: out,
          zipDiskPath: zipDiskPath,
          zipArchive: zipArchive,
          at: c.fullPath,
          innerPrefix: innerPrefix,
          parentOwnerKey: ownerKey,
          depth: depth + 1,
        );
      } else if (c.isZip) {
        final nestedKey =
            _makeZipInnerKey(zipDiskPath, innerFullForDisplay);
        final nestedArchive = _zipArchives[nestedKey];
        if (nestedArchive != null) {
          _appendZipChildren(
            out: out,
            zipDiskPath: zipDiskPath,
            zipArchive: nestedArchive,
            at: '',
            innerPrefix: innerFullForDisplay,
            parentOwnerKey: nestedKey,
            depth: depth + 1,
          );
        }
      }
    }
  }

// ===== 第 1/3 条结束，接第 2/3 条 =====

  // ==================== 加载目录 ====================

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

    // 换目录时收起所有 zip
    if (_expandedZipKeys.isNotEmpty) {
      _expandedZipKeys.clear();
      _stickyZipKey = null;
    }

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
        return;
      }
    }

    if (_currentPath == _topPath) {
      List<EntryInfo> entries;
      try {
        entries = _listStorageRoot();
      } catch (_) {
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
        },
      );
    } catch (e) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ==================== 滚动锚点 ====================

  bool get _isGridMode =>
      !_searchActive && ref.read(browserGridModeProvider);

  List<String> _snapshotVisiblePaths() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return const <String>[];
    final allItems = _cachedDisplayItems;
    if (allItems == null || allItems.isEmpty) return const <String>[];

    final sorted = positions.toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final grid = _isGridMode;
    final out = <String>[];
    for (final p in sorted) {
      if (grid) {
        final i1 = p.index * 2;
        final i2 = i1 + 1;
        if (i1 >= 0 && i1 < allItems.length) out.add(allItems[i1].key);
        if (i2 >= 0 && i2 < allItems.length) out.add(allItems[i2].key);
      } else {
        if (p.index < 0 || p.index >= allItems.length) continue;
        out.add(allItems[p.index].key);
      }
    }
    return out;
  }

  void _restoreScrollAnchor(List<String> anchorKeys) {
    if (anchorKeys.isEmpty) return;
    final allItems = _cachedDisplayItems;
    if (allItems == null || allItems.isEmpty) return;

    var targetIdx = -1;
    for (final k in anchorKeys) {
      final idx = allItems.indexWhere((it) => it.key == k);
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
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path == _currentPath) return;
    _recordCurrentScroll();
    _clearSelection();
    _searchCtrl.clear();
    _searchTaskId++;
    _expandedZipKeys.clear();
    _stickyZipKey = null;
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
    if (parent == '/storage/emulated') {
      _navigateTo(_topPath);
      return;
    }
    _navigateTo(parent);
  }

  List<EntryInfo> _listStorageRoot() {
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
      '/proc/mounts', '/proc/self/mountinfo', '/proc/self/mounts',
      '/etc/mtab',
    ];
    final uuids = <String>{};
    for (final src in sources) {
      try {
        final content = File(src).readAsStringSync();
        for (final m in uuidPattern.allMatches(content)) {
          uuids.add(m.group(1)!);
        }
        if (uuids.isNotEmpty) break;
      } catch (_) {}
    }
    for (final uuid in uuids) {
      if (Directory('/storage/$uuid').existsSync()) {
        addDir('/storage/$uuid', '外部存储($uuid)');
      } else if (Directory('/mnt/media_rw/$uuid').existsSync()) {
        addDir('/mnt/media_rw/$uuid', '外部存储($uuid)');
      }
    }

    return out;
  }

  // ==================== 选中 ====================

  void _clearSelection() {
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
      _anchorPath = null;
    });
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

  void _toggleSelectionByKey(String key) {
    setState(() {
      _selectionMode = true;
      if (_selectedPaths.contains(key)) {
        _selectedPaths.remove(key);
        if (_selectedPaths.isEmpty) {
          _selectionMode = false;
          _anchorPath = null;
        }
      } else {
        _selectedPaths.add(key);
        _anchorPath = key;
      }
    });
  }

  void _onLongPressItem(_DisplayItem item) {
    if (!_selectionMode) {
      setState(() {
        _selectionMode = true;
        _selectedPaths.add(item.key);
        _anchorPath = item.key;
      });
      return;
    }
    if (_anchorPath != null) {
      final all = _cachedDisplayItems ?? const <_DisplayItem>[];
      final from = all.indexWhere((it) => it.key == _anchorPath);
      final to = all.indexWhere((it) => it.key == item.key);
      if (from >= 0 && to >= 0) {
        final lo = from < to ? from : to;
        final hi = from < to ? to : from;
        setState(() {
          for (var i = lo; i <= hi; i++) {
            _selectedPaths.add(all[i].key);
          }
          _anchorPath = item.key;
        });
        return;
      }
    }
    setState(() {
      _selectedPaths.add(item.key);
      _anchorPath = item.key;
    });
  }

  void _toggleSelectAll() {
    final all = _cachedDisplayItems ?? const <_DisplayItem>[];
    // 全选时只选"实际可选择"的（非目录、非 loading/error 提示）
    final selectable = all
        .where((it) => !it.isDir && !it.key.startsWith('__loading__') &&
            !it.key.startsWith('__error__'))
        .map((it) => it.key)
        .toList();
    final allSelected = selectable.isNotEmpty &&
        selectable.every((k) => _selectedPaths.contains(k));
    setState(() {
      if (allSelected) {
        _selectedPaths.clear();
        _selectionMode = false;
        _anchorPath = null;
      } else {
        _selectionMode = true;
        _selectedPaths.addAll(selectable);
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

  // ==================== zip 展开 / 收起 ====================


/// 修复 zip 里的乱码文件名。
///
/// 老 Windows / WinRAR 打的 zip，文件名是 GBK 字节，但没设 UTF-8 标记位。
/// archive 包遇到没标记位的 zip，一律按 latin1 解，就成乱码了。
///
/// 判断逻辑：
///   · 文件名字符里有 > 0xFF 的字符 → 说明已经正确解码（UTF-8/中文），不动
///   · 全是 ASCII → 不动
///   · 有 0x80~0xFF 的字符 → 按 latin1 反推回字节，再试 UTF-8、GBK
Archive _fixZipNames(Archive archive) {
  var anyChanged = false;
  final newArchive = Archive();
  for (final f in archive.files) {
    final fixed = _fixZipName(f.name);
    if (fixed != f.name) anyChanged = true;
    newArchive.addFile(ArchiveFile(fixed, f.size, f.content));
  }
  return anyChanged ? newArchive : archive;
}

String _fixZipName(String name) {
  if (name.isEmpty) return name;

  var hasHigh = false;
  for (final r in name.runes) {
    if (r > 0xFF) return name; // 有非 latin1 字符，说明已正确解码
    if (r >= 0x80) hasHigh = true;
  }
  if (!hasHigh) return name; // 纯 ASCII

  // 有 0x80~0xFF 的字符，可能是 latin1 解出的 GBK/UTF-8 字节
  final bytes = Uint8List.fromList(name.codeUnits);

  // 先试 UTF-8
  try {
    final utf8Name = utf8.decode(bytes);
    if (utf8Name != name) return utf8Name;
  } catch (_) {}

  // 再试 GBK
  try {
    final gbkName = gbk.decode(bytes);
    if (gbkName != name) return gbkName;
  } catch (_) {}

  return name;
}

  /// 快速判断 zip 是否加密：读文件头前 8 字节，看通用用途标志位。
  /// 不完整解压，几毫秒返回。
  Future<bool> _isEncryptedZip(String path) async {
    try {
      final raf = await File(path).open();
      try {
        final header = await raf.read(8);
        if (header.length < 8) return false;
        // 本地文件头签名：50 4B 03 04 = 'PK\x03\x04'
        if (header[0] != 0x50 ||
            header[1] != 0x4B ||
            header[2] != 0x03 ||
            header[3] != 0x04) {
          return false;
        }
        // 通用用途位标志的第 0 位 = 加密
        return (header[6] & 0x01) != 0;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// 按文件名后缀选解码器。zip / tar / tar.gz / tgz 都支持。
  
/// 按文件名后缀选解码器。zip / tar / tar.gz / tgz 都支持。
Archive _decodeArchiveBytes(String name, Uint8List bytes) {
  final lower = name.toLowerCase();
 if (lower.endsWith('.zip')) {
  final archive = ZipDecoder().decodeBytes(bytes);
  return _fixZipNames(archive);
}
  if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
  final gunzipped = GZipDecoder().decodeBytes(bytes);
  return _parseTarWithGbk(Uint8List.fromList(gunzipped));
}
  if (lower.endsWith('.tar')) {
    return _parseTarWithGbk(bytes);
  }
  throw Exception('不支持的压缩格式：$name');
}

/// 自己解析 tar。相比 archive 包的 TarDecoder，多了文件名编码回退：
/// 先严格 UTF-8 解，失败再 GBK 解，最后 latin1 兜底。
/// 支持 ustar prefix 和 GNU LongName（typeflag 'L'）。
Archive _parseTarWithGbk(Uint8List bytes) {
  final archive = Archive();
  var offset = 0;
  Uint8List? pendingLongNameBytes;

  // 去掉尾部 \0，然后依次尝试 UTF-8 / GBK / latin1
  String decodeName(List<int> raw) {
    var end = raw.length;
    while (end > 0 && raw[end - 1] == 0) {
      end--;
    }
    if (end <= 0) return '';
    final slice = raw.sublist(0, end);
    try {
      return utf8.decode(slice);
    } catch (_) {}
    try {
      return gbk.decode(slice);
    } catch (_) {}
    return String.fromCharCodes(slice);
  }

  // 读八进制数字（tar header 里 size 是这个格式）
  int readOctal(Uint8List buf, int start, int len) {
    var result = 0;
    for (var i = start; i < start + len; i++) {
      final b = buf[i];
      if (b == 0 || b == 0x20) break;
      if (b < 0x30 || b > 0x37) break;
      result = result * 8 + (b - 0x30);
    }
    return result;
  }

  int alignTo512(int n) => ((n + 511) ~/ 512) * 512;

  while (offset + 512 <= bytes.length) {
    final header = Uint8List.sublistView(bytes, offset, offset + 512);

    // 全零 header = 结束标记
    var allZero = true;
    for (var i = 0; i < 512; i++) {
      if (header[i] != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) break;

    var name = decodeName(header.sublist(0, 100));
    final size = readOctal(header, 124, 12);
    final type = header[156];
    // ustar 长路径的 prefix（老格式，路径 > 100 字节时分两段存）
    final prefix = decodeName(header.sublist(345, 500));
    if (prefix.isNotEmpty) {
      name = '$prefix/$name';
    }

    offset += 512;
    if (offset + size > bytes.length) break;

    // typeflag 0x4C = 'L'，GNU LongName：下一段内容是真正的文件名
    if (type == 0x4C) {
      pendingLongNameBytes =
          Uint8List.fromList(bytes.sublist(offset, offset + size));
      offset += alignTo512(size);
      continue;
    }

    // typeflag 0x78 = 'x'（pax 扩展头）/ 0x67 = 'g'（全局扩展头）：跳过
    if (type == 0x78 || type == 0x67) {
      offset += alignTo512(size);
      continue;
    }

    // typeflag '\0'（0x00）/ '0'（0x30）= 普通文件，'5'（0x35）= 目录
    if (type == 0x00 || type == 0x30 || type == 0x35) {
      if (pendingLongNameBytes != null) {
        name = decodeName(pendingLongNameBytes);
        pendingLongNameBytes = null;
      }

      final isDir = type == 0x35;
      final content = isDir
          ? Uint8List(0)
          : Uint8List.fromList(bytes.sublist(offset, offset + size));

      // 目录名末尾的 '/' 去掉，与 zip 内目录处理保持一致
      final cleanName = isDir && name.endsWith('/')
          ? name.substring(0, name.length - 1)
          : name;

      if (cleanName.isNotEmpty) {
        archive.addFile(ArchiveFile(cleanName, content.length, content));
      }
      offset += alignTo512(size);
    } else {
      // 其它类型（链接等）：跳过内容
      offset += alignTo512(size);
    }
  }

  return archive;
}
  

  /// 展开一个 zip。已加载则直接展开；未加载则读盘 + 解码。
 

Future<void> _expandZip(String zipDiskPath) async {
  if (_expandedZipKeys.contains(zipDiskPath)) return;
  if (_loadingZipKeys.contains(zipDiskPath)) return;

  // ① 先看大小。超过上限 → 直接弹系统选择器，不尝试解码。
  try {
    final length = await File(zipDiskPath).length();
    if (length > _maxZipBytes) {
      if (!mounted) return;
      await openFileWithSystemPicker(zipDiskPath, context);
      if (mounted) {
        _toast('压缩包过大（${_formatSize(length)}），已交给其他 App 打开');
      }
      return;
    }
  } catch (_) {}

  setState(() {
    _loadingZipKeys.add(zipDiskPath);
    _zipErrors.remove(zipDiskPath);
    _expandedZipKeys.add(zipDiskPath);
  });

  try {
    final bytes = await File(zipDiskPath).readAsBytes();
    final archive = _decodeArchiveBytes(zipDiskPath, bytes);

    if (!mounted) return;

    _zipArchives[zipDiskPath] = archive;
    _collectNestedZips(zipDiskPath, archive, '', '');

    if (!mounted) return;
    setState(() {
      _loadingZipKeys.remove(zipDiskPath);
    });
  } catch (e) {
    if (!mounted) return;

    // ② 解码崩了 → 大概率加密或损坏 → 弹系统选择器。
    setState(() {
      _loadingZipKeys.remove(zipDiskPath);
      _expandedZipKeys.remove(zipDiskPath);
    });

    await openFileWithSystemPicker(zipDiskPath, context);
    if (mounted) {
      _toast('此压缩包无法解压（可能已加密），已交给其他 App 打开');
    }
  }
}


    

  /// 递归扫描 archive 里所有嵌套 zip，解码并缓存。
  /// 顶层 zip 的 key = zipDiskPath；嵌套 zip 的 key = _makeZipInnerKey(...)。
  /// [innerPrefix] 是"已经走过的嵌套路径"（顶层传空字符串）。
  void _collectNestedZips(
    String ownerZipDiskPath,
    Archive archive,
    String at,
    String innerPrefix,
  ) {
    final children = _directZipChildren(archive, at);
    for (final c in children) {
      if (c.isDir) {
        _collectNestedZips(ownerZipDiskPath, archive, c.fullPath, innerPrefix);
      } else if (c.isZip) {
        try {
          final f = archive.findFile(c.fullPath);
          if (f == null) continue;
          final content = f.content;
          final Uint8List bytes;
          if (content is Uint8List) {
            bytes = content;
          } else if (content is List<int>) {
            bytes = Uint8List.fromList(content);
          } else {
            continue;
          }
          final inner = _decodeArchiveBytes(c.name, bytes);
          final innerFull = innerPrefix.isEmpty
              ? c.fullPath
              : '$innerPrefix>${c.fullPath}';
          final nestedKey = _makeZipInnerKey(ownerZipDiskPath, innerFull);
          _zipArchives[nestedKey] = inner;
          _expandedZipKeys.add(nestedKey);
          _collectNestedZips(ownerZipDiskPath, inner, '', innerFull);
        } catch (_) {
          // 打不开的嵌套 zip 忽略
        }
      }
    }
  }

  /// 收起一个 zip（顶层）。只清顶层 key，嵌套的顺带清掉。
  void _collapseZip(String zipDiskPath) {
    setState(() {
      _expandedZipKeys.remove(zipDiskPath);
      _expandedZipKeys.removeWhere((k) => _isZipInnerKey(k) &&
          _zipPathFromInnerKey(k) == zipDiskPath);
      _zipArchives.remove(zipDiskPath);
      _zipArchives.removeWhere((k, _) => _isZipInnerKey(k) &&
          _zipPathFromInnerKey(k) == zipDiskPath);
      _zipErrors.remove(zipDiskPath);
      if (_stickyZipKey == zipDiskPath) {
        _stickyZipKey = null;
      }
    });
  }

  /// 点 zip 头：展开或收起。
  Future<void> _toggleZipExpand(_DisplayItem zipItem) async {
    if (zipItem.isZipInner) {
      // 嵌套 zip：找它的 key 递归收起
      setState(() {
        _expandedZipKeys.remove(zipItem.key);
        _expandedZipKeys.removeWhere((k) => k.startsWith(zipItem.key));
      });
      return;
    }
    if (_expandedZipKeys.contains(zipItem.key)) {
      _collapseZip(zipItem.key);
    } else {
      await _expandZip(zipItem.key);
    }
  }

  /// zip 顶部粘性头点击 = 收起。
  /// ★ 已停用，保留方法备查。
  // ignore: unused_element
  void _onStickyZipTap(String zipDiskPath) {
    _collapseZip(zipDiskPath);
  }

  // ==================== 打开 / 查看 ====================

  /// 点击一个列表项。可能是磁盘文件、目录、zip、zip 内文件、zip 内目录。
  Future<void> _handleTapItem(_DisplayItem item) async {
    // 加载/错误提示行：忽略
    if (item.key.startsWith('__loading__') ||
        item.key.startsWith('__error__')) {
      return;
    }

    // zip 头：展开/收起
    if (item.isZip) {
      await _toggleZipExpand(item);
      return;
    }

    // zip 内目录：点 = 什么都不做（默认展开到最深）
    if (item.isZipInner && item.isDir) {
      return;
    }

    // zip 内文件：点击 = 打开
    if (item.isZipInner) {
      await _openZipInnerFile(item);
      return;
    }

    // 磁盘目录
    if (item.isDir) {
      final p = item.diskPath;
      if (p != null) _navigateTo(p);
      return;
    }

    // 磁盘文件
    final p = item.diskPath;
    if (p != null) {
      await _openFile(p, item.displayName, item.size);
    }
  }

  /// 打开 zip 内文件。
  Future<void> _openZipInnerFile(_DisplayItem item) async {
    final ext = _extOf(item.displayName);
    final isText = _textExts.contains(ext);

    final bytes = _readZipInnerBytes(item);
    if (bytes == null) {
      _toast('读取失败');
      return;
    }

    if (isText) {
      // 文本：写到临时文件，走正常文件打开流程
      final tmp = await _writeTempFile(bytes, item.displayName);
      if (tmp == null) {
        _toast('无法创建临时文件');
        return;
      }
      final mode = ref.read(fileOpenModeProvider);
      switch (mode) {
        case FileOpenMode.reader:
          await _openInReader(tmp, item.displayName);
        case FileOpenMode.editor:
          await _openInEditor(tmp, item.displayName);
        case FileOpenMode.lineEditor:
          await _openInLineEditor(tmp, item.displayName);
        case FileOpenMode.ask:
          final picked = await _askOpenMode(item.displayName);
          if (picked == null) return;
          switch (picked) {
            case FileOpenMode.reader:
              await _openInReader(tmp, item.displayName);
            case FileOpenMode.editor:
              await _openInEditor(tmp, item.displayName);
            case FileOpenMode.lineEditor:
              await _openInLineEditor(tmp, item.displayName);
            case FileOpenMode.ask:
              break;
          }
      }
    } else {
      // 非文本：临时写到缓存目录，然后弹打开方式/分享
      final tmp = await _writeTempFile(bytes, item.displayName);
      if (tmp == null) {
        _toast('无法创建临时文件');
        return;
      }
      if (!mounted) return;
      await showOpenOrShareSheet(context, tmp, item.displayName);
    }
  }

  /// 从 zip 内项读原始字节。
  Uint8List? _readZipInnerBytes(_DisplayItem item) {
    final archive = item.innerArchive;
    final path = item.innerPath;
    if (archive == null || path == null) return null;
    try {
      final f = archive.findFile(path);
      if (f == null) return null;
      final content = f.content;
      if (content is Uint8List) return content;
      if (content is List<int>) return Uint8List.fromList(content);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 把字节写到临时目录，返回路径。
  Future<String?> _writeTempFile(Uint8List bytes, String fileName) async {
    try {
      final dir = Directory.systemTemp;
      final safe = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final ts = DateTime.now().microsecondsSinceEpoch;
      final path = '${dir.path}/zzz_$ts\_$safe';
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }

  // ==================== 打开磁盘文件 ====================

Future<void> _openFile(
  String path,
  String name,
  int? size, {
  bool allowExpand = true,
}) async {
  final isText = _textExts.contains(_extOf(name));

  if (!isText) {
    final lowerName = name.toLowerCase();

    // 可展开压缩包（zip / tar / tar.gz / tgz）
    if (_isExpandableArchiveName(name)) {
      // 加密 zip → 直接弹系统选择器
      if (lowerName.endsWith('.zip') && await _isEncryptedZip(path)) {
        if (!mounted) return;
        await openFileWithSystemPicker(path, context);
        return;
      }
      // 网格模式不支持展开 → 弹系统选择器
      // 网格模式：直接弹系统选择器
if (!allowExpand) {
  if (!mounted) return;
  await openFileWithSystemPicker(path, context);
  return;
}
        
      // 列表模式 / 搜索结果页：直接展开
      await _expandZip(path);
      return;
    }

    // 强制系统选择器的后缀（7z/rar/dzip/iso/tz/gz
    // /epub/pdf/doc/docx）：直接弹系统选择器
    if (_forceSystemPickerExts.any((ext) => lowerName.endsWith(ext))) {
      if (!mounted) return;
      await openFileWithSystemPicker(path, context);
      return;
    }

    // 其它非文本：弹"打开方式 / 分享"两选一
    await showOpenOrShareSheet(context, path, name);
    return;
  }

  // 文本文件
  final configured = ref.read(fileOpenModeProvider);
  FileOpenMode resolved;
  if (configured == FileOpenMode.ask) {
    final picked = await _askOpenMode(name);
    if (picked == null) return;
    resolved = picked;
  } else {
    resolved = configured;
  }

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
    final textPaths = _collectTextFilePaths();
    var index = textPaths.indexOf(path);
    if (index < 0) {
      textPaths.insert(0, path);
      index = 0;
    }

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

    if (!mounted) return;

    final deleted = ref.read(readerDeletedPathsProvider);
    if (deleted.isNotEmpty) {
      ref.read(readerDeletedPathsProvider.notifier).state = const [];
      final deletedSet = deleted.toSet();
      final current = _entries ?? const <EntryInfo>[];
      final stillThere = <EntryInfo>[];
      for (final info in current) {
        if (!deletedSet.contains(info.entity.path)) {
          stillThere.add(info);
        }
      }
      if (stillThere.length != current.length) {
        setState(() => _entries = stillThere);
        DirCache.instance.applyToAll(
          _currentPath,
          (list) => list.where((e) => !deletedSet.contains(e.path)).toList(),
        );
      }
    }

    if (result != null && result != openedPath) {
      _scrollToPath(result);
    }
  }

  Future<void> _openInEditor(String path, String name) async {
    await Navigator.of(context).push(_noAnimRoute(SingleFileEditorScreen(
      filePath: path,
      fileName: name,
    )));
    if (!mounted) return;
    DirCache.instance.invalidate(_currentPath);
    _load();
  }

  Future<void> _openInLineEditor(String path, String name) async {
    await Navigator.of(context).push(_noAnimRoute(LineEditorScreen(
      filePath: path,
      fileName: name,
    )));
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
    final allItems = _cachedDisplayItems ?? const <_DisplayItem>[];
    final index = allItems.indexWhere((it) => it.key == path);
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
    _expandedZipKeys.clear();
    _stickyZipKey = null;
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

  /// 从 _selectedPaths 集合里取所有"可参与对比的项"：
  /// 每一项可能是磁盘路径，也可能是 zip 内文件的 key。
  List<_DisplayItem> _resolveSelectedItems() {
    final items = _cachedDisplayItems ?? const <_DisplayItem>[];
    final out = <_DisplayItem>[];
    for (final key in _selectedPaths) {
      final it = items.firstWhere(
        (x) => x.key == key,
        orElse: () => _DisplayItem(
          key: key,
          displayName: key.split('/').last,
          depth: 0,
        ),
      );
      out.add(it);
    }
    return out;
  }

  Future<void> _startCompare() async {
    if (_selectedPaths.length != 2) return;

    final items = _resolveSelectedItems();
    if (items.length != 2) return;

    for (final it in items) {
      if (it.isDir) {
        _toast('对比只支持文件，请勿选中文件夹');
        return;
      }
      if (it.isZip && !it.isZipInner) {
        _toast('对比不支持直接对比压缩包本身，请展开后选里面的文件');
        return;
      }
    }

    String? leftText;
    String? rightText;
    String? leftName;
    String? rightName;
    String? leftPath;
    String? rightPath;

    try {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      // 左
      final leftBytes = await _readBytesOfItem(items[0]);
      if (leftBytes == null) throw Exception('读取左侧文件失败');
      final leftParsed = await compute(
        _parseInWorker,
        (fileName: items[0].displayName, bytes: leftBytes),
      );
      leftText = leftParsed.plainText;
      leftName = leftParsed.fileName;
      leftPath = items[0].isDiskItem ? items[0].diskPath : null;

      // 右
      final rightBytes = await _readBytesOfItem(items[1]);
      if (rightBytes == null) throw Exception('读取右侧文件失败');
      final rightParsed = await compute(
        _parseInWorker,
        (fileName: items[1].displayName, bytes: rightBytes),
      );
      rightText = rightParsed.plainText;
      rightName = rightParsed.fileName;
      rightPath = items[1].isDiskItem ? items[1].diskPath : null;

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      ref.read(originalRawTextProvider.notifier).state = leftText;
      ref.read(modifiedRawTextProvider.notifier).state = rightText;
      ref.read(originalFileNameProvider.notifier).state = leftName;
      ref.read(modifiedFileNameProvider.notifier).state = rightName;
      ref.read(originalEncodingProvider.notifier).state = 'UTF-8';
      ref.read(modifiedEncodingProvider.notifier).state = 'UTF-8';
      ref.read(originalFilePathProvider.notifier).state = leftPath;
      ref.read(modifiedFilePathProvider.notifier).state = rightPath;
      ref.read(importRevisionProvider.notifier).state++;
      ref.read(editedOriginalProvider.notifier).state = null;
      ref.read(editedModifiedProvider.notifier).state = null;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const DiffViewerScreen(),
        ),
      );
      if (!mounted) return;
      setState(() => _pruneSearchResults());
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _toast('读取文件失败：$e');
    }
  }

  /// 从一个 DisplayItem 读原始字节。
  Future<Uint8List?> _readBytesOfItem(_DisplayItem item) async {
    if (item.isZipInner) {
      return _readZipInnerBytes(item);
    }
    final p = item.diskPath;
    if (p == null) return null;
    try {
      return await File(p).readAsBytes();
    } catch (_) {
      return null;
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
    final items = _resolveSelectedItems();
    if (items.length != 2) return;

    for (final it in items) {
      if (it.isDir) {
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
      final b1 = await _readBytesOfItem(items[0]);
      final b2 = await _readBytesOfItem(items[1]);
      if (b1 == null || b2 == null) throw Exception('读取文件失败');
      final h1 = await compute(_md5Worker, b1);
      final h2 = await compute(_md5Worker, b2);

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      final same = h1 == h2;
      final name1 = items[0].displayName;
      final name2 = items[1].displayName;

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
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText(h1,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                  const SizedBox(height: 14),
                  Text(name2,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText(h2,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
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
    final items = _resolveSelectedItems();
    if (items.isEmpty || !items[0].isDir) {
      _toast('导出清单只能用于文件夹');
      return;
    }
    final path = items[0].diskPath;
    if (path == null) {
      _toast('此文件夹不在磁盘上');
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
    final items = _resolveSelectedItems();
    if (items.isEmpty) return;
    final it = items[0];

    // zip 内文件：不能 stat，只能显示内存里的信息
    if (it.isZipInner) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          insetPadding: _dlgInset,
          titlePadding: _dlgTitlePad,
          contentPadding: _dlgContentPad,
          actionsPadding: _dlgActionsPad,
          title: const Text('属性'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _propRow(context, '名称', it.displayName),
                _propRow(context, '来源', it.fullDisplayPath),
                _propRow(context, '类型', it.isDir ? '文件夹' : '文件'),
                _propRow(
                  context,
                  '大小',
                  it.size == null ? '—' : _formatSize(it.size),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }

    // 磁盘项：原来的逻辑
    final path = it.diskPath;
    if (path == null) return;
    final name = it.displayName;

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
    await showDialog<void>(
      context: context,
      builder: (_) => _PropertiesDialog(
        name: name,
        path: path,
        isDir: isDir,
        size: size,
        modified: modified,
        accessed: accessed,
      ),
    );
  }

  Widget _propRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          SelectableText(value),
        ],
      ),
    );
  }

  /// 底栏「打开方式」。
  Future<void> _openWithApp() async {
    if (_selectedPaths.length != 1) return;
    final items = _resolveSelectedItems();
    if (items.isEmpty) return;
    final it = items[0];
    if (it.isDir) {
      _toast('文件夹不能"打开方式"');
      return;
    }
    if (it.isZipInner) {
      final bytes = _readZipInnerBytes(it);
      if (bytes == null) {
        _toast('读取失败');
        return;
      }
      final tmp = await _writeTempFile(bytes, it.displayName);
      if (tmp == null) {
        _toast('无法创建临时文件');
        return;
      }
      if (!mounted) return;
      await openFileWithSystemPicker(tmp, context);
      return;
    }
    final p = it.diskPath;
    if (p == null) return;
    await openFileWithSystemPicker(p, context);
  }

  /// 底栏「分享」。
  Future<void> _shareSelected() async {
    if (_selectedPaths.isEmpty) return;
    final items = _resolveSelectedItems();

    final diskPaths = <String>[];
    final tempPaths = <String>[];
    for (final it in items) {
      if (it.isZipInner) {
        final bytes = _readZipInnerBytes(it);
        if (bytes == null) continue;
        final tmp = await _writeTempFile(bytes, it.displayName);
        if (tmp != null) tempPaths.add(tmp);
      } else {
        final p = it.diskPath;
        if (p != null) diskPaths.add(p);
      }
    }

    final all = <String>[...diskPaths, ...tempPaths];
    if (all.isEmpty) {
      _toast('没有可分享的文件');
      return;
    }
    if (!mounted) return;
    await shareMany(all, context);
  }

  Future<void> _copyPath() async {
    if (_selectedPaths.length != 1) return;
    final items = _resolveSelectedItems();
    if (items.isEmpty) return;
    final it = items[0];
    final path = it.isZipInner ? it.fullDisplayPath : (it.diskPath ?? '');
    if (path.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (mounted) _toast('路径已复制');
  }

  static String _formatTimeFull(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // ==================== 视图弹窗 ====================

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

  // ==================== 收藏 / 配置 ====================

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

  /// 从选中的 key 里提取所有磁盘路径（zip 内项返回 null）。
  List<String> _selectedDiskPaths() {
    final out = <String>[];
    for (final p in _selectedPaths) {
      if (_isZipInnerKey(p)) continue;
      out.add(p);
    }
    return out;
  }

  Future<void> _rename() async {
    if (_selectedPaths.length != 1) {
      _toast('重命名一次只能操作一个');
      return;
    }
    final key = _selectedPaths.first;
    if (_isZipInnerKey(key)) {
      _toast('压缩包内的文件不支持重命名');
      return;
    }
    final oldPath = key;
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
    final paths = _selectedDiskPaths();
    if (paths.isEmpty) {
      _toast('压缩包内的文件不支持移动');
      return;
    }
    final target = await _pickDirectory('移动到哪？');
    if (target == null) return;

    var ok = 0;
    var fail = 0;
    for (final src in paths) {
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
      DirCache.instance.invalidate(_currentPath);
      DirCache.instance.invalidate(target);
    }
    _clearSelection();
    _load(restoreScroll: true);
    _toast('已移动 $ok 项${fail > 0 ? "，$fail 项失败" : ""}');
  }

  Future<void> _copy() async {
    final paths = _selectedDiskPaths();
    if (paths.isEmpty) {
      _toast('压缩包内的文件不支持复制');
      return;
    }
    final target = await _pickDirectory('复制到哪？');
    if (target == null) return;

    var ok = 0;
    var fail = 0;
    for (final src in paths) {
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
    final paths = _selectedDiskPaths();
    if (paths.isEmpty) {
      _toast('压缩包内的文件不支持删除');
      return;
    }
    final n = paths.length;
    final ok = await _confirm(
      '删除 $n 项？',
      '选中的 $n 项将从磁盘删除，无法恢复。',
    );
    if (!ok) return;

    final deletedPaths = <String>{};
    var fail = 0;
    for (final p in paths) {
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

  List<({String label, String path})>? _crumbsCache;
  String? _crumbsCacheForPath;

  List<({String label, String path})> get _crumbs {
    if (_crumbsCacheForPath == _currentPath && _crumbsCache != null) {
      return _crumbsCache!;
    }
    final out = _computeCrumbs();
    _crumbsCacheForPath = _currentPath;
    _crumbsCache = out;
    return out;
  }

  List<({String label, String path})> _computeCrumbs() {
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

    final out = <({String label, String path})>[
      (label: '存储', path: _topPath),
    ];
    if (!_currentPath.startsWith('$_topPath/')) return out;
    final relative = _currentPath.substring(_topPath.length);
    final segments =
        relative.split('/').where((s) => s.isNotEmpty).toList();

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

// ===== 第 2/3 条结束，接第 3/3 条 =====
  // ==================== build ====================

  @override
  Widget build(BuildContext context) {
    _cachedDisplayItems = _buildDisplayItems();

    return PopScope(
      canPop: !_canGoUp &&
          _currentPath != _topPath &&
          !_selectionMode &&
          !_searchActive,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectionMode) {
          setState(_clearSelection);
        } else if (_searchActive) {
          _clearSearch();
        } else if (_expandedZipKeys.isNotEmpty) {
          setState(() {
            _expandedZipKeys.clear();
            _stickyZipKey = null;
          });
        } else if (_currentPath == _topPath) {
          _navigateTo(_rootPath);
        } else if (_canGoUp) {
          _goUp();
        }
      },
      child: Scaffold(
        appBar:
            _selectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
       body: SafeArea(
  top: false,
  child: Column(
    children: [
      _buildBreadcrumbs(),
            IgnorePointer(
              ignoring: _selectionMode,
              child: _buildSearchBar(),
            ),
        if (_searchActive) _buildSearchStatusBar(),
if (!_searchActive &&
    !_selectionMode &&
    _expandedZipKeys.isNotEmpty)
  _buildExpandedZipBar(),
      Expanded(child: _buildBody()),
    ],
  ),
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
            Navigator.of(context).push(_noAnimRoute(
              const ComparisonSettingsScreen(),
            ));
          },
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: '更多',
          onSelected: (v) {
            switch (v) {
              case 'browserSettings':
                Navigator.of(context).push(_noAnimRoute(
                  const BrowserSettingsScreen(),
                ));
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
    final all = _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectable = all
        .where((it) => !it.isDir && !it.key.startsWith('__loading__') &&
            !it.key.startsWith('__error__'))
        .map((it) => it.key)
        .toList();
    final allSelected = selectable.isNotEmpty &&
        selectable.every((k) => _selectedPaths.contains(k));
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

/// 有压缩包展开时，在搜索栏下方固定显示一条提示条。
/// 无论列表滚到多深都能看到，"全部收起"一键折叠所有展开的压缩包。
Widget _buildExpandedZipBar() {
  // 只数顶层（磁盘上的）压缩包，嵌套 zip 的 key 会带前缀，不算。
  final topLevelCount =
      _expandedZipKeys.where((k) => !_isZipInnerKey(k)).length;
  if (topLevelCount == 0) return const SizedBox.shrink();

  return Container(
    width: double.infinity,
    color: Colors.blue.shade50,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: Row(
      children: [
       
    Icon(Icons.folder_zip_outlined, size: 16, color: Colors.blue.shade700),
              const SizedBox(width: 8),
        Expanded(
          child: Text(
            '已展开 $topLevelCount 个压缩包',
            style: TextStyle(
              fontSize: 12,
              color: Colors.blue.shade900,
            ),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: Colors.blue.shade800,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: () {
            setState(() {
              _expandedZipKeys.clear();
              _zipArchives.clear();
              _zipErrors.clear();
              _loadingZipKeys.clear();
              _stickyZipKey = null;
            });
          },
          child: const Text('全部收起'),
        ),
      ],
    ),
  );
}


  Widget _buildSearchStatusBar() {
    final textTheme = Theme.of(context).textTheme;
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
                style: textTheme.labelSmall,
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
              style: textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 底部栏 ====================

  /// 判断当前选中项里是否只包含"磁盘项"。用于禁用不支持的按钮。
  bool get _selectionAllDisk {
    if (_selectedPaths.isEmpty) return false;
    for (final k in _selectedPaths) {
      if (_isZipInnerKey(k)) return false;
    }
    return true;
  }

  bool get _selectionHasZipInner {
    for (final k in _selectedPaths) {
      if (_isZipInnerKey(k)) return true;
    }
    return false;
  }

  Widget _buildBottomBar() {
    final n = _selectedPaths.length;
    final canCompare = n == 2;
    final canMd5 = n == 2;
    final canProps = n == 1;
    final canOpenWith = n == 1;
    final canShare = n >= 1;
    final allDisk = _selectionAllDisk;

    final canCopyPath = n == 1;
    final canRename = n == 1 && allDisk;
    final canMove = n >= 1 && allDisk;
    final canCopy = n >= 1 && allDisk;
    final canDelete = n >= 1 && allDisk;
    final canExportListing = n == 1 && allDisk;

    final s = Theme.of(context).colorScheme;

    final outlineStyle = FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.black,
      side: BorderSide(color: s.primary),
    );

    const labelStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.bold,
    );

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: s.surface,
          border: Border(
            top: BorderSide(color: s.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 第一行：可左右滑动
            SizedBox(
              height: 38,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,







child: Row(
  children: [
    SizedBox(
      width: 160,
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
    SizedBox(
      width: 68,
      child: FilledButton(
        style: outlineStyle,
        onPressed: canCopyPath ? _copyPath : null,
        child: const Text(
          '复制路径',
          style: labelStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
    const SizedBox(width: 3),
    SizedBox(
      width: 68,
      child: FilledButton(
        style: outlineStyle,
        onPressed: canOpenWith ? _openWithApp : null,
        child: const Text(
          '打开方式',
          style: labelStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
    const SizedBox(width: 3),
    SizedBox(
      width: 68,
      child: FilledButton(
        style: outlineStyle,
        onPressed: canShare ? _shareSelected : null,
        child: const Text(
          '分享',
          style: labelStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
    const SizedBox(width: 3),
    SizedBox(
      width: 68,
      child: FilledButton(
        style: outlineStyle,
        onPressed: canMd5 ? _md5Compare : null,
        child: const Text(
          'MD5对比',
          style: labelStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
    const SizedBox(width: 3),
    SizedBox(
      width: 68,
      child: FilledButton(
        style: outlineStyle,
        onPressed:
            canExportListing ? _exportFolderListing : null,
        child: const Text(
          '导出清单',
          style: labelStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
  ],
),



                  
                








                  
              ),
            ),
            const SizedBox(height: 4),
            // 第二行
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
                    onPressed: canMove ? _move : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.copy_all_outlined,
                    label: '复制',
                    onPressed: canCopy ? _copy : null,
                  ),
                ),
                Expanded(
                  child: _wideAction(
                    icon: Icons.delete_outline,
                    label: '删除',
                    onPressed: canDelete ? _delete : null,
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
        : _buildListBody();
  }

  // ==================== 列表模式（无粘性头部） ====================

  Widget _buildListBody() {
    final fontName = ref.watch(browserFontListNameProvider);
    final fontMeta = ref.watch(browserFontListMetaProvider);
    final colorScheme = Theme.of(context).colorScheme;

    final items = _cachedDisplayItems ?? const <_DisplayItem>[];

    // ★ 粘性头部已停用：直接返回列表，结构恒定，
    //   不会再因为 Stack 结构切换而丢失滚动位置。
    return ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final item = items[i];
        return RepaintBoundary(
          key: ValueKey('rb_${item.key}'),
          child: _buildDisplayItemTile(item, fontName, fontMeta, colorScheme),
        );
      },
    );
  }

  /// 渲染一个 display item。磁盘项、zip 头、zip 内项各有不同样式。
  Widget _buildDisplayItemTile(
    _DisplayItem item,
    double fontName,
    double fontMeta,
    ColorScheme colorScheme,
  ) {
    // loading / error 提示行
    if (item.key.startsWith('__loading__')) {
      return Padding(
        padding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 12,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              item.displayName,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    if (item.key.startsWith('__error__')) {
      return Padding(
        padding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 12,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.displayName,
                style: const TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ),
          ],
        ),
      );
    }

    final selected = _selectedPaths.contains(item.key);

    // zip 头（顶层或嵌套）：和普通文件一样的 ListTile，
    // 只用图标区分展开/折叠（折叠=空心蓝，展开=实心蓝）。

// 只用图标区分展开/折叠（折叠=空心蓝，展开=实心蓝）。
if (item.isZip) {
  final isExpanded = _expandedZipKeys.contains(item.key);
  // 只有"顶层压缩包 + 已展开"时用实心图标；
  // 嵌套压缩包始终空心。
  final isTopLevel = item.ownerZipKey == null;
  final zipIcon = (isTopLevel && isExpanded)
    ? Icons.folder_zip_outlined
    : Icons.folder_zip;
  final metaLine = _buildItemMetaLine(item);




    
return Container(
  foregroundDecoration: selected
      ? BoxDecoration(
          border: Border(
            top: BorderSide(
  
              color: const Color(0xFFB000FF),   // 紫色
              width: 1,
            ),
            bottom: BorderSide(
   
              color: const Color(0xFFB000FF),   // 紫色
              width: 1,
            ),
            left: BorderSide(
   
              color: const Color(0xFFB000FF),   // 紫色
              width: 2,
            ),
            right: BorderSide(
   
              color: const Color(0xFFB000FF),   // 紫色
              width: 2,
            ),
          ),
        )
      : null,
  child: ListTile(




        
      dense: true,

         minVerticalPadding: 0,                                              // ← 加这行
  visualDensity: const VisualDensity(horizontal: 0, vertical: -4),   // ← 加这行


        
      contentPadding: EdgeInsets.only(
        left: 8.0 + item.depth * 18.0,
        right: 8,
      ),
      selected: selected,
      selectedTileColor: const Color(0xFFFFF3FB),
      
        leading: Icon(
  zipIcon,
          color: Colors.blue.shade600,
        
      ),
      title: Text(
        item.displayName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontName,
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: metaLine.isEmpty
          ? null
          : Text(
              metaLine,
              style: TextStyle(
                fontSize: fontMeta,
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      onTap: () {
        if (_selectionMode) {
          _toggleSelectionByKey(item.key);
          return;
        }
        _handleTapItem(item);
      },
      onLongPress: () => _onLongPressItem(item),
    ),
  );
}

    // zip 内目录
    if (item.isZipInner && item.isDir) {
      return Padding(
        padding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 12,
          top: 5,
          bottom: 5,
        ),
        child: Row(
          children: [
            const SizedBox(width: 22),
            Icon(Icons.folder, size: 18, color: Colors.amber.shade600),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontName - 1,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 通用文件行（磁盘文件 或 zip 内文件）
    final isZipInner = item.isZipInner;
    final metaLine = _buildItemMetaLine(item);



      return Container(
  foregroundDecoration: selected
      ? BoxDecoration(
          border: Border(
            top: BorderSide(
              color: const Color(0xFFB000FF),   // 紫色
              width: 1,
            ),
            bottom: BorderSide(
              color: const Color(0xFFB000FF),   // 紫色
              width: 1,
            ),
            left: BorderSide(
             color: const Color(0xFFB000FF),   // 紫色
              width: 2,
            ),
            right: BorderSide(
              color: const Color(0xFFB000FF),   // 紫色
              width: 2,
            ),
          ),
        )
      : null,
  child: ListTile(





    
  dense: true,
  minVerticalPadding: 0,
  visualDensity: const VisualDensity(horizontal: 0, vertical: -4),

  contentPadding: EdgeInsets.only(

            
          left: 8.0 + item.depth * 18.0,
          right: 8,
        ),
        selected: selected,
        selectedTileColor: const Color(0xFFFFF3FB),
        leading: Icon(
  isZipInner
                ? Icons.insert_drive_file_outlined
                : (item.isDir
                    ? Icons.folder
                    : Icons.insert_drive_file_outlined),
            color: isZipInner
                ? Colors.blueGrey.shade300
                : (item.isDir
                    ? Colors.amber.shade600
                    : _fileColor(item.displayName)),
          
        ),
        title: Text(
          item.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: fontName,
            fontWeight: FontWeight.bold,
            color: isZipInner
                ? colorScheme.onSurface.withOpacity(0.85)
                : null,
          ),
        ),
        subtitle: metaLine.isEmpty
            ? null
            : Text(
                metaLine,
                style: TextStyle(
                  fontSize: fontMeta,
                  color: colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        onTap: () {
          if (_selectionMode) {
            _toggleSelectionByKey(item.key);
            return;
          }
          _handleTapItem(item);
        },
        onLongPress: () => _onLongPressItem(item),
      ),
    );
  }

  String _buildItemMetaLine(_DisplayItem item) {
    final parts = <String>[];
    if (item.size != null && !item.isDir) {
      final s = _formatSize(item.size);
      if (s.isNotEmpty) parts.add(s);
    }
    if (item.modified != null) {
      parts.add(_formatTime(item.modified));
    }
    return parts.join(' · ');
  }

  // ==================== 网格模式（不支持 zip 展开） ====================

  Widget _buildGridBody(List<EntryInfo> entries) {
    final showSize = ref.watch(browserGridShowSizeProvider);
    final showTime = ref.watch(browserGridShowTimeProvider);
    final fontName = ref.watch(browserFontGridNameProvider);
    final fontMeta = ref.watch(browserFontGridMetaProvider);

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
        );

        final rightWidget = rightInfo == null
            ? const SizedBox.shrink()
            : _buildGridCell(
                info: rightInfo,
                showSize: showSize,
                showTime: showTime,
                fontName: fontName,
                fontMeta: fontMeta,
              );

        return RepaintBoundary(
          key: ValueKey('rb_grid_$rowIdx'),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: leftWidget),
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
  }) {
    final e = info.entity;
    final selected = _selectedPaths.contains(e.path);
    final colorScheme = Theme.of(context).colorScheme;

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
          _toggleSelectionByKey(e.path);
          return;
        }
        if (info.isDir) {
          _navigateTo(e.path);
        } else {
          // ★ 网格模式不支持展开压缩包，只弹"打开方式 / 分享"
          _openFile(e.path, info.name, info.size, allowExpand: false);
        }
      },
      onLongPress: () {
        final all = _cachedDisplayItems ?? const <_DisplayItem>[];
        final it = all.firstWhere(
          (x) => x.key == e.path,
          orElse: () => _DisplayItem(
            key: e.path,
            displayName: info.name,
            depth: 0,
          ),
        );
        _onLongPressItem(it);
      },
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? _gridSelectedBg
              : (info.isDir
                  ? null
                  : (_textExts.contains(_extOf(info.name))
                      ? null
                      : const Color(0xFFF0F0F0))),
        ),
        foregroundDecoration: BoxDecoration(
          border: selected
              ? Border.all(
                  color: colorScheme.primary,
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
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGridName(EntryInfo info, double fontSize) {
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
    final isText = _textExts.contains(_extOf(name));
    final isLarge = isText &&
        info.size != null &&
        info.size! > 3 * 1024 * 1024;

    final dotIdx = name.lastIndexOf('.');
    final hasExt = dotIdx > 0 && dotIdx < name.length - 1;

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

  // ==================== 搜索结果列表（无粘性头部） ====================

  Widget _buildSearchResultsList() {
    if (_searchResults.isEmpty) {
      return Center(
        child: Text(_searching ? '正在扫描...' : '未找到匹配'),
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    final fontName = ref.watch(browserFontListNameProvider);
    final fontMeta = ref.watch(browserFontListMetaProvider);

    final items = _cachedDisplayItems ?? const <_DisplayItem>[];

    // ★ 粘性头部已停用：直接返回列表。
    return ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final item = items[i];
        return RepaintBoundary(
          key: ValueKey('rb_search_${item.key}'),
          child: _buildSearchResultTile(item, fontName, fontMeta, colorScheme),
        );
      },
    );
  }

  /// 搜索结果模式的列表项渲染（跟普通列表不同：显示路径副标题）。
  Widget _buildSearchResultTile(
    _DisplayItem item,
    double fontName,
    double fontMeta,
    ColorScheme colorScheme,
  ) {
    if (item.key.startsWith('__loading__') ||
        item.key.startsWith('__error__')) {
      return _buildDisplayItemTile(item, fontName, fontMeta, colorScheme);
    }

    if (item.isZip && !item.isZipInner) {
      return _buildDisplayItemTile(item, fontName, fontMeta, colorScheme);
    }

    if (item.isZipInner && item.isDir) {
      return _buildDisplayItemTile(item, fontName, fontMeta, colorScheme);
    }

    final selected = _selectedPaths.contains(item.key);
    final isZipInner = item.isZipInner;
    final metaLine = _buildItemMetaLine(item);
    final pathLine = isZipInner
        ? item.fullDisplayPath
        : (item.diskPath ?? '');

    return Container(
      foregroundDecoration: selected
          ? BoxDecoration(
              border: Border.all(
                
                  color: const Color(0xFFFF00C3),   // 紫色
                width: 1,
              ),
            )
          : null,
      child: ListTile(
        dense: true,
        isThreeLine: true,
          minVerticalPadding: 0,                                              // ← 加这行
  visualDensity: const VisualDensity(horizontal: 0, vertical: -4),   // ← 加这行
        contentPadding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 8,
        ),
        selected: selected,
        selectedTileColor: const Color(0xFFFFF3FB),
        leading: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Icon(
            Icons.insert_drive_file_outlined,
            color: isZipInner
                ? Colors.blueGrey.shade300
                : _fileColor(item.displayName),
          ),
        ),
        title: Text(
          item.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: fontName,
            fontWeight: FontWeight.bold,
            color: isZipInner
                ? colorScheme.onSurface.withOpacity(0.85)
                : null,
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
                  color: colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              pathLine,
              style: TextStyle(
                fontSize: fontMeta,
                color: colorScheme.onSurface,
              ),
              softWrap: true,
            ),
          ],
        ),
        onTap: () {
          if (_selectionMode) {
            _toggleSelectionByKey(item.key);
            return;
          }
          _handleTapItem(item);
        },
        onLongPress: () => _onLongPressItem(item),
      ),
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
  static const String _internalRoot = '/storage/emulated/0';
  static const Color _rangeBlue = Color(0xFF3D7CFF);
  static const Color _rangeHighlight = Color(0x333D7CFF);

  late String _path;
  late List<String> _selected;
  late final TextEditingController _jumpCtrl;
  List<Directory> _dirs = const [];
  bool _loading = true;

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

  String get _relPath {
    if (_path == widget.rootPath) return '~/';
    if (_path == _internalRoot || _path.startsWith('$_internalRoot/')) {
      final sub = _path.substring(_internalRoot.length);
      return sub.isEmpty ? '~' : '~$sub';
    }
    return _path;
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
      _rangeAnchorPath = null;
    });
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

  void _toggleRangeMode() {
    setState(() {
      _rangeMode = !_rangeMode;
      _rangeAnchorPath = null;
    });
  }

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
      setState(() => _rangeAnchorPath = path);
      return;
    }
    final lo = from < to ? from : to;
    final hi = from < to ? to : from;

    setState(() {
      for (var i = lo; i <= hi; i++) {
        _selected.add(visible[i]);
      }
      _rangeMode = false;
      _rangeAnchorPath = null;
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

  String get _titleText {
    if (_rangeMode) {
      return _rangeAnchorPath == null ? '点一行内容为起点' : '再点一行内容为终点';
    }
    return '点击左侧方框勾选对应文件夹';
  }

  double get _titleSize => _rangeMode ? 14.0 : 16.0;

  Color? get _titleColor => _rangeMode ? _rangeBlue : null;

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
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
              child: Row(
                children: [
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
                  FilterChip(
                    label: const Text('区间'),
                    selected: _rangeMode,
                    onSelected: (_) => _toggleRangeMode(),
                    backgroundColor: Colors.white,
                    selectedColor: const Color(0xFFE3F2FD),
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

// ==================== 属性弹窗（含手动计算 MD5） ====================

class _PropertiesDialog extends StatefulWidget {
  const _PropertiesDialog({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modified,
    required this.accessed,
  });

  final String name;
  final String path;
  final bool isDir;
  final int? size;
  final DateTime? modified;
  final DateTime? accessed;

  @override
  State<_PropertiesDialog> createState() => _PropertiesDialogState();
}

class _PropertiesDialogState extends State<_PropertiesDialog> {
  // ★修复：_PropertiesDialogState 不能访问 _FileBrowserScreenState 的
  // private static 常量，这里本地补一份（文件底部还有 _dlgInsetG 等全局常量，
  // 直接使用也可以）。
  static const EdgeInsets _dlgInset = EdgeInsets.all(4);
  static const EdgeInsets _dlgTitlePad = EdgeInsets.fromLTRB(12, 8, 12, 0);
  static const EdgeInsets _dlgContentPad = EdgeInsets.fromLTRB(8, 4, 8, 4);
  static const EdgeInsets _dlgActionsPad = EdgeInsets.fromLTRB(4, 0, 4, 4);

  String? _md5;
  bool _md5Loading = false;
  String? _md5Error;

  Future<void> _computeMd5() async {
    if (widget.isDir) return;
    setState(() {
      _md5Loading = true;
      _md5Error = null;
    });
    try {
      final bytes = await File(widget.path).readAsBytes();
      final hash = await compute(
        _FileBrowserScreenState._md5Worker,
        bytes,
      );
      if (!mounted) return;
      setState(() {
        _md5 = hash;
        _md5Loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _md5Error = e.toString();
        _md5Loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 2),
              SelectableText(value),
            ],
          ),
        );

    return AlertDialog(
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
              row('名称', widget.name),
              row('路径', widget.path),
              row('类型', widget.isDir ? '文件夹' : '文件'),
              row(
                '大小',
                widget.isDir
                    ? '—'
                    : (widget.size == null
                        ? '—'
                        : _FileBrowserScreenState._formatSize(widget.size)),
              ),
              if (widget.modified != null)
                row(
                  '修改时间',
                  _FileBrowserScreenState._formatTimeFull(widget.modified!),
                ),
              if (widget.accessed != null)
                row(
                  '访问时间',
                  _FileBrowserScreenState._formatTimeFull(widget.accessed!),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MD5',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 4),
                    _buildMd5Area(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildMd5Area() {
    if (widget.isDir) {
      return const Text(
        '文件夹不支持计算 MD5',
        style: TextStyle(fontSize: 13, color: Colors.grey),
      );
    }

    if (_md5Loading) {
      return const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('计算中…', style: TextStyle(fontSize: 13)),
        ],
      );
    }

    if (_md5 != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _md5!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: '重新计算',
                visualDensity: VisualDensity.compact,
                onPressed: _computeMd5,
              ),
            ],
          ),
          if (_md5Error != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '计算失败：$_md5Error',
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
        ],
      );
    }

    return OutlinedButton.icon(
      onPressed: _computeMd5,
      icon: const Icon(Icons.fingerprint, size: 16),
      label: const Text('点击计算 MD5'),
    );
  }
}
