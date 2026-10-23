import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:charset/charset.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable, compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../help/presentation/help_screen.dart';
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
enum _ConflictAction { skip, overwrite, rename }
// ==================== 高级搜索条件 ====================

enum _SearchOperator { or, and, not }

class _SearchCondition {
  _SearchCondition({required this.operator, String text = ''})
      : controller = TextEditingController(text: text);
  _SearchOperator operator;
  final TextEditingController controller;
  String get text => controller.text;
  void dispose() => controller.dispose();
}
class _SearchHit {
  _SearchHit({
    required this.path,
    required this.name,
    this.isDir = false,
    this.size,
    this.modified,
  });
  final String path;
  final String name;
  final bool isDir;
  final int? size;
  final DateTime? modified;
}

class _AdvancedOverlayContent extends StatefulWidget {
  const _AdvancedOverlayContent({
    required this.panelTop,
    required this.panelLeft,
    required this.panelWidth,
    required this.conditions,
    required this.onChanged,
    required this.onClearAll,
    required this.onSubmit,
    required this.onClose,
  });

  final double panelTop;
  final double panelLeft;
  final double panelWidth;
  final List<_SearchCondition> conditions;
  final VoidCallback onChanged;
  final VoidCallback onClearAll;
  final VoidCallback onSubmit;
  final VoidCallback onClose;

  @override
  State<_AdvancedOverlayContent> createState() =>
      _AdvancedOverlayContentState();
}

class _AdvancedOverlayContentState extends State<_AdvancedOverlayContent> {
  int? _openMenuIndex;
  final Map<int, GlobalKey> _btnKeys = {};

  GlobalKey _keyFor(int i) => _btnKeys.putIfAbsent(i, () => GlobalKey());

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: _handleOutsideTap,
            behavior: HitTestBehavior.translucent,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: widget.panelLeft,
          top: widget.panelTop,
          width: widget.panelWidth,
          child: _buildPanel(),
        ),
        if (_openMenuIndex != null) _buildMenu(),
      ],
    );
  }

  void _handleOutsideTap() {
    if (_openMenuIndex != null) {
      setState(() => _openMenuIndex = null);
    } else {
      widget.onClose();
    }
  }

  Widget _buildPanel() {
    final hasAny = widget.conditions.any((c) => c.text.trim().isNotEmpty);
    final cs = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      color: cs.surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.conditions.isEmpty)
              const SizedBox(height: 8)
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  itemCount: widget.conditions.length,
                  itemBuilder: (_, i) => _row(i),
                ),
              ),
            _addClearRow(hasAny),
            _submitButton(hasAny),
          ],
        ),
      ),
    );
  }

  Widget _row(int i) {
    final cond = widget.conditions[i];
    return Padding(
      padding: const EdgeInsets.only(left: 3, right: 1, top: 3, bottom: 3),
      child: Row(
        children: [
          _operatorBtn(i, cond),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: cond.controller,
                onChanged: (_) => widget.onChanged(),
                style: const TextStyle(fontSize: 14),
                cursorColor: Theme.of(context).colorScheme.primary,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '输入文字',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 1.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 28,
            height: 36,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: Icon(Icons.close,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              tooltip: '删除此条件',
              onPressed: () => _remove(i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _operatorBtn(int i, _SearchCondition cond) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      key: _keyFor(i),
      width: 68,
      height: 36,
      child: Material(
        color: cs.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _toggleMenu(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _label(cond.operator),
                  style: TextStyle(fontSize: 13, color: cs.onSurface),
                ),
                Icon(Icons.arrow_drop_down,
                    size: 18, color: cs.onSurface),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toggleMenu(int i) {
    setState(() {
      _openMenuIndex = (_openMenuIndex == i) ? null : i;
    });
  }

  void _selectOperator(int i, _SearchOperator op) {
    setState(() {
      widget.conditions[i].operator = op;
      _openMenuIndex = null;
    });
    widget.onChanged();
  }

  void _add() {
    setState(() {
      widget.conditions
          .add(_SearchCondition(operator: _SearchOperator.or));
      _btnKeys.clear();
    });
    widget.onChanged();
  }

  void _remove(int i) {
    if (i < 0 || i >= widget.conditions.length) return;
    setState(() {
      if (_openMenuIndex == i) _openMenuIndex = null;
      widget.conditions[i].dispose();
      widget.conditions.removeAt(i);
      _btnKeys.clear();
    });
    widget.onChanged();
  }

  Widget _buildMenu() {
    final i = _openMenuIndex!;
    if (i < 0 || i >= widget.conditions.length) {
      return const SizedBox.shrink();
    }
    final key = _keyFor(i);
    final btnBox = key.currentContext?.findRenderObject() as RenderBox?;
    if (btnBox == null) return const SizedBox.shrink();
    final btnPos = btnBox.localToGlobal(Offset.zero);
    final top = btnPos.dy + btnBox.size.height + 2;
    final left = btnPos.dx;

    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.surface,
        child: SizedBox(
          width: 210,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _menuItem(i, _SearchOperator.or, '或者', '命中一个就行'),
              _menuItem(i, _SearchOperator.and, '同时', '必须都出现'),
              _menuItem(i, _SearchOperator.not, '排除', '不要这个'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuItem(
      int i, _SearchOperator op, String label, String hint) {
    final cs = Theme.of(context).colorScheme;
    final selected = widget.conditions[i].operator == op;
    return InkWell(
      onTap: () => _selectOperator(i, op),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: selected
                  ? Icon(Icons.check,
                      size: 16, color: cs.primary)
                  : null,
            ),
            Text(label,
                style: TextStyle(
                    fontSize: 14, color: cs.onSurface)),
            const SizedBox(width: 12),
            Text(hint,
                style: TextStyle(
                    fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _addClearRow(bool hasAny) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 12, 3, 0),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: Material(
                color: cs.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _add,
                  child: Center(
                    child: Text(
                      '＋ 添加条件',
                      style: TextStyle(fontSize: 13, color: cs.onSurface),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 40,
              child: Material(
                color: cs.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: hasAny ? widget.onClearAll : null,
                  child: Center(
                    child: Text(
                      '🗑 清空条件',
                      style: TextStyle(
                        fontSize: 13,
                        color: hasAny
                            ? cs.onSurface
                            : cs.onSurfaceVariant.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _submitButton(bool hasAny) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 12, 3, 10),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: FilledButton(
          onPressed: hasAny ? widget.onSubmit : null,
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
          ),
          child: const Text(
            '搜索',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  String _label(_SearchOperator op) {
    switch (op) {
      case _SearchOperator.or:
        return '或者';
      case _SearchOperator.and:
        return '同时';
      case _SearchOperator.not:
        return '排除';
    }
  }
}
// ==================== 统一列表项 ====================

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

  final String? ownerZipKey;
  final String? innerPath;
  final String? innerPathForDisplay;
  final Archive? innerArchive;

  bool get isDiskItem => diskEntry != null || searchHit != null;
  bool get canExpand => isZip;
  String? get diskPath => diskEntry?.path ?? searchHit?.path;

  String get fullDisplayPath {
    if (ownerZipKey == null) return displayName;
    final zipName = ownerZipKey!.split('/').last;
    final inner = innerPathForDisplay ?? displayName;
    return '$zipName > $inner';
  }
}

// ==================== 虚拟 key 工具 ====================

const String _zipInnerPrefix = 'zip://';
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

  static const EdgeInsets _dlgInset = EdgeInsets.all(4);
  static const EdgeInsets _dlgTitlePad =
      EdgeInsets.fromLTRB(12, 8, 12, 0);
  static const EdgeInsets _dlgContentPad = EdgeInsets.fromLTRB(8, 4, 8, 4);
  static const EdgeInsets _dlgActionsPad =
      EdgeInsets.fromLTRB(4, 0, 4, 4);

  static const double _gridCellPadH = 8.0;
  static const double _gridCellPadV = 6.0;
  static const double _gridDividerThickness = 0.5;

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
static const Set<String> _imageExts = {
  '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.ico',
  '.tif', '.tiff', '.heic', '.raw',
};

static const Set<String> _videoExts = {
  '.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.m4v',
  '.3gp', '.mpg', '.mpeg', '.rmvb', '.rm', '.vob',
};

static const Set<String> _audioExts = {
  '.mp3', '.flac', '.wav', '.aac', '.ogg', '.m4a', '.wma', '.ape',
  '.opus',
};

static const Set<String> _archiveExts = {
  '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso',
  '.cab', '.lz', '.lzma', '.zst', '.apk', '.apks', '.xapk', '.aab',
};
  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    if (i <= 0 || i == name.length - 1) return '';
    return name.substring(i).toLowerCase();
  }

  // 图标颜色：不再按扩展名区分色相。文件类型靠图标形状区分。
  // 文件夹用 primary（主题色，导航暗示），文件用 onSurfaceVariant（中性灰）。
  Color _fileIconColor(BuildContext context, {required bool isDir}) {
    final cs = Theme.of(context).colorScheme;
    return isDir ? cs.primary : cs.onSurfaceVariant;
  }

  Color _gridDividerColorOf(BuildContext context) =>
      Theme.of(context).colorScheme.outlineVariant;

  // ==================== 状态字段 ====================

  late String _currentPath;
  List<EntryInfo>? _entries;
  bool _loading = false;
  bool _showSkeleton = false;
  Timer? _skeletonTimer;
  int _bodyRevision = 0; // 每次切目录 +1，用来强制 AnimatedSwitcher 重建
  String? _error;

  LoadCancelToken? _loadCancelToken;

  final TextEditingController _searchCtrl = TextEditingController();

  /// 搜索输入框的焦点节点。
  /// 用于：展开搜索栏时自动聚焦；监听聚焦变化以刷新边框/标签颜色。
  final FocusNode _searchFocus = FocusNode();

  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  final Map<String, int> _dirScrollPositions = {};

  /// 当前列表（网格模式按行算）的条目总数，供自定义滚动条与翻页按钮使用。
  /// 每次构建列表时刷新；非列表状态（加载中/空目录/出错）置 0。
  int _scrollItemCount = 0;

  bool _selectionMode = false;
  final Set<String> _selectedPaths = <String>{};
  String? _anchorPath;

  List<_SearchHit> _searchResults = <_SearchHit>[];
  bool _searching = false;
  bool _searchActive = false;
  int _searchTaskId = 0;
  DateTime _lastUiRefresh = DateTime.now();

  // ★ 新增：最近一次整行点击的 x 坐标（相对行左边）。
  // 用来判断点的是不是左侧图标区（图标区点=选中，其它=打开）。
  double _lastTapX = double.infinity;
// ==================== 高级搜索条件状态 ====================
bool _advancedOpen = false;
final List<_SearchCondition> _searchConditions = [];
final GlobalKey _searchBarBoxKey = GlobalKey();
final GlobalKey _searchInputKey = GlobalKey();
OverlayEntry? _advancedOverlay;


  // ==================== zip 展开状态 ====================

  final Set<String> _expandedZipKeys = <String>{};
  final Map<String, Archive> _zipArchives = <String, Archive>{};
  final Set<String> _loadingZipKeys = <String>{};
  final Map<String, String> _zipErrors = <String, String>{};

  /// ★ 粘性头部已停用，此字段保留但始终为 null。
String? _stickyZipKey;

// ==================== 过滤状态 ====================

int _filterTaskId = 0;
List<_DisplayItem>? _visibleItems;
List<_DisplayItem>? _cachedDisplayItems;
List<String?>? _cachedOwnerZipPerIndex;

  static const int _maxZipBytes = 50 * 1024 * 1024;

  static const Set<String> _forceSystemPickerExts = {
    '.7z', '.rar', '.dzip', '.iso', '.tz', '.gz',
    '.epub', '.pdf', '.doc', '.docx',
  };

	/// 单次展开中，所有嵌套 zip 解压后的累计大小上限。
/// _maxZipBytes 只限制顶层 zip 磁盘大小，拦不住"小包大解压"
/// 和"嵌套 zip 层层解压"。这里累计统计解压后内容，超限停手。
static const int _maxTotalDecodedBytes = 200 * 1024 * 1024;

/// 本次展开中已累计的解压字节数。
int _expandedDecodedBytes = 0;

  // ==================== 生命周期 ====================

  
  @override
void initState() {
  super.initState();
  // 清掉上次会话遗留的 zip 内临时文件。
  // 不 await：后台跑，不阻塞启动。
  _cleanTempDirOnce();
  final saved = ref.read(lastPathProvider);
  _currentPath = _resolveInitialPath(saved);
  _positionsListener.itemPositions.addListener(_onPositionsChanged);
  _searchFocus.addListener(_onSearchFocusChanged);
  _load();
}

void _onSearchFocusChanged() {
  if (mounted) setState(() {});
}

/// 清空 systemTemp 里所有 zzz_ 前缀的文件。
/// 这个前缀专门标记 App 自己写的临时文件，避免误删别人的东西。
Future<void> _cleanTempDirOnce() async {
  try {
    final dir = Directory.systemTemp;
    if (!await dir.exists()) return;
    var n = 0;
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.path.split('/').last;
      if (!name.startsWith('zzz_')) continue;
      try {
        await e.delete();
        n++;
      } catch (_) {}
    }
    if (n > 0) {
      ReaderLoadLog.instance.info('[TempCleanup] 清理 $n 个临时文件');
    }
  } catch (_) {}
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
  _skeletonTimer?.cancel();
  _positionsListener.itemPositions.removeListener(_onPositionsChanged);
  _searchFocus.removeListener(_onSearchFocusChanged);
  _searchFocus.dispose();
  _searchCtrl.dispose();
  _advancedOverlay?.remove();
  _advancedOverlay = null;
  for (final c in _searchConditions) {
    c.dispose();
  }
  _searchConditions.clear();
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
  }

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
  isDir: hit.isDir,    // ★ 加这行
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

  // ==================== 加载目录 ====================

  Future<void> _load({
  bool restoreScroll = false,
  bool skipCache = false,
  bool silent = false,
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
          _showSkeleton = false;
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
        _showSkeleton = false;
        _error = null;
      });
      DirCache.instance.put(cacheKey, entries);
      if (anchor.isNotEmpty) _restoreScrollAnchor(anchor);
      return;
    }

   if (!silent) {
  setState(() {
    _loading = true;
    _error = null;
    _bodyRevision++; // 只在真正显示 loading 时递增，缓存命中/静默刷新保持原地更新
  });
  _skeletonTimer?.cancel();
  _showSkeleton = false;
  _skeletonTimer = Timer(const Duration(milliseconds: 180), () {
    if (mounted && _loading) {
      setState(() => _showSkeleton = true);
    }
  });
} else if (_error != null) {
  setState(() => _error = null);
}

try {
  await loadDirectoryAsync(
        path: _currentPath,
        sortField: sortField,
        sortAsc: sortAsc,
        cancelToken: token,
        onUpdate: (list) {
          if (!mounted || token.isCancelled) return;
          _skeletonTimer?.cancel();
          setState(() {
            _entries = list;
            _loading = false;
            _showSkeleton = false;
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
          _skeletonTimer?.cancel();
          setState(() {
            _entries = list;
            _showSkeleton = false;
          });
          DirCache.instance.put(cacheKey, list);
        },
      );
    } catch (e) {
      if (!mounted || token.isCancelled) return;
      _skeletonTimer?.cancel();
      setState(() {
        _error = e.toString();
        _loading = false;
        _showSkeleton = false;
      });
    }
  }

  // ==================== 滚动锚点 ====================

  bool get _isGridMode =>
      !_searchActive && ref.read(browserGridModeProvider);

  List<String> _snapshotVisiblePaths() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return const <String>[];
    // 列表实际渲染的是 _visibleItems（过滤模式下的子集），
    // 用全量列表按下标取 key 会错位。
    final allItems = _visibleItems ?? _cachedDisplayItems;
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
    final allItems = _visibleItems ?? _cachedDisplayItems;
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
_advancedOverlay?.remove();
_advancedOverlay = null;
_advancedOpen = false;
_clearConditions();
_filterTaskId++;
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
// ==================== 高级搜索条件 · 逻辑 ====================

int get _activeConditionCount =>
    _searchConditions.where((c) => c.text.trim().isNotEmpty).length;

/// 有没有非空条件。
bool get _hasActiveConditions => _activeConditionCount > 0;

/// 上一次点"搜索"时的关键词。关键词变了就清空高级条件。
String _lastSearchedQuery = '';




void _clearConditions() {
  for (final c in _searchConditions) {
    c.dispose();
  }
  _searchConditions.clear();
}

/// 核心匹配函数。所有搜索/过滤入口都用它。
bool _matchNameForSearch(String name) {
  final lower = name.toLowerCase();
  final mainText = _searchCtrl.text.trim().toLowerCase();
  final orTexts = <String>[];
  if (mainText.isNotEmpty) orTexts.add(mainText);

  final andTexts = <String>[];
  final notTexts = <String>[];

  for (final c in _searchConditions) {
    final t = c.text.trim().toLowerCase();
    if (t.isEmpty) continue;
    switch (c.operator) {
      case _SearchOperator.or:
        orTexts.add(t);
      case _SearchOperator.and:
        andTexts.add(t);
      case _SearchOperator.not:
        notTexts.add(t);
    }
  }

  if (orTexts.isEmpty && andTexts.isEmpty && notTexts.isEmpty) {
    return true;
  }
  if (orTexts.isNotEmpty && !orTexts.any(lower.contains)) return false;
  for (final t in andTexts) {
    if (!lower.contains(t)) return false;
  }
  for (final t in notTexts) {
    if (lower.contains(t)) return false;
  }
  return true;
}

// ==================== 高级搜索条件 · Overlay ====================

void _toggleAdvanced() {
  FocusManager.instance.primaryFocus?.unfocus();
  if (_advancedOpen) {
    _closeAdvanced();
  } else {
    setState(() => _advancedOpen = true);
    _showAdvancedOverlay();
  }
}

void _closeAdvanced() {
  _advancedOverlay?.remove();
  _advancedOverlay = null;
  if (mounted && _advancedOpen) {
    setState(() => _advancedOpen = false);
  }
}

void _showAdvancedOverlay() {
  _advancedOverlay?.remove();
  _advancedOverlay = null;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final box =
        _searchBarBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screenWidth = MediaQuery.of(context).size.width;

    _advancedOverlay = OverlayEntry(
      builder: (ctx) => _AdvancedOverlayContent(
        panelTop: pos.dy + size.height + 2,
        panelLeft: 8,
        panelWidth: screenWidth - 16,
        conditions: _searchConditions,
        onChanged: () {
          if (!mounted) return;
          setState(() {});
          _advancedOverlay?.markNeedsBuild();
        },
        onClearAll: () {
          _clearConditions();
          setState(() {});
          _advancedOverlay?.markNeedsBuild();
        },
        onSubmit: () {
          _closeAdvanced();
          _doSearch();
        },
        onClose: _closeAdvanced,
      ),
    );
    Overlay.of(context).insert(_advancedOverlay!);
  });
}

// ==================== 高级搜索条件 · UI ====================






Widget _buildAdvancedToggle() {
  final cs = Theme.of(context).colorScheme;
  // 只有两态：展开 / 收起。有没有条件靠颜色和 tooltip 表达。
  final icon = _advancedOpen
      ? Icons.keyboard_arrow_up
      : Icons.keyboard_arrow_down;
  final color =
      _hasActiveConditions ? cs.primary : cs.onSurfaceVariant;
  final tip = _hasActiveConditions
      ? '高级搜索（有 $_activeConditionCount 条条件）'
      : '高级搜索';
  return SizedBox(
    width: 40,
    height: 44,
    child: InkResponse(
      onTap: _toggleAdvanced,
      radius: 20,
      child: Tooltip(
        message: tip,
        child: Icon(icon, color: color, size: 22),
      ),
    ),
  );
}
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
      // 用屏幕上实际显示的列表，避免过滤模式下把隐藏项一起选上。
      final all =
          _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
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
    final all =
        _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectable = all
        .where((it) => !it.key.startsWith('__loading__') &&
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
    if (r > 0xFF) return name;
    if (r >= 0x80) hasHigh = true;
  }
  if (!hasHigh) return name;

  final bytes = Uint8List.fromList(name.codeUnits);

  try {
    final utf8Name = utf8.decode(bytes);
    if (utf8Name != name) return utf8Name;
  } catch (_) {}

  try {
    final gbkName = gbk.decode(bytes);
    if (gbkName != name) return gbkName;
  } catch (_) {}

  return name;
}

  Future<bool> _isEncryptedZip(String path) async {
    try {
      final raf = await File(path).open();
      try {
        final header = await raf.read(8);
        if (header.length < 8) return false;
        if (header[0] != 0x50 ||
            header[1] != 0x4B ||
            header[2] != 0x03 ||
            header[3] != 0x04) {
          return false;
        }
        return (header[6] & 0x01) != 0;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

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

Archive _parseTarWithGbk(Uint8List bytes) {
  final archive = Archive();
  var offset = 0;
  Uint8List? pendingLongNameBytes;

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
    final prefix = decodeName(header.sublist(345, 500));
    if (prefix.isNotEmpty) {
      name = '$prefix/$name';
    }

    offset += 512;
    if (offset + size > bytes.length) break;

    if (type == 0x4C) {
      pendingLongNameBytes =
          Uint8List.fromList(bytes.sublist(offset, offset + size));
      offset += alignTo512(size);
      continue;
    }

    if (type == 0x78 || type == 0x67) {
      offset += alignTo512(size);
      continue;
    }

    if (type == 0x00 || type == 0x30 || type == 0x35) {
      if (pendingLongNameBytes != null) {
        name = decodeName(pendingLongNameBytes);
        pendingLongNameBytes = null;
      }

      final isDir = type == 0x35;
      final content = isDir
          ? Uint8List(0)
          : Uint8List.fromList(bytes.sublist(offset, offset + size));

      final cleanName = isDir && name.endsWith('/')
          ? name.substring(0, name.length - 1)
          : name;

      if (cleanName.isNotEmpty) {
        archive.addFile(ArchiveFile(cleanName, content.length, content));
      }
      offset += alignTo512(size);
    } else {
      offset += alignTo512(size);
    }
  }

  return archive;
}

Future<void> _expandZip(String zipDiskPath) async {
  if (_expandedZipKeys.contains(zipDiskPath)) return;
  if (_loadingZipKeys.contains(zipDiskPath)) return;

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

  // 重置本次展开的累计解压计数，并把顶层解压后的内容算进去。
  _expandedDecodedBytes = 0;
  final topDecodedSize =
      archive.files.fold<int>(0, (s, f) => s + f.size);
  _expandedDecodedBytes = topDecodedSize;

  _zipArchives[zipDiskPath] = archive;
  _collectNestedZips(zipDiskPath, archive, '', '');


		

    if (!mounted) return;
    setState(() {
      _loadingZipKeys.remove(zipDiskPath);
    });
  } catch (e) {
    if (!mounted) return;

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

  void _collectNestedZips(
  String ownerZipDiskPath,
  Archive archive,
  String at,
  String innerPrefix,
) {
  if (_expandedDecodedBytes >= _maxTotalDecodedBytes) return;
  final children = _directZipChildren(archive, at);
    for (final c in children) {
      if (c.isDir) {
        _collectNestedZips(ownerZipDiskPath, archive, c.fullPath, innerPrefix);
      } else if (c.isZip) {
  // 累计已超上限，不再展开更深的嵌套。
  if (_expandedDecodedBytes >= _maxTotalDecodedBytes) continue;

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

    // 把这一层的解压内容累计进去。
    final innerDecodedSize =
        inner.files.fold<int>(0, (s, file) => s + file.size);
    _expandedDecodedBytes += innerDecodedSize;
    if (_expandedDecodedBytes > _maxTotalDecodedBytes) {
      // 超限：不再记录这一层，也不再往下钻。
      continue;
    }

    final innerFull = innerPrefix.isEmpty
        ? c.fullPath
        : '$innerPrefix>${c.fullPath}';
    final nestedKey = _makeZipInnerKey(ownerZipDiskPath, innerFull);
    _zipArchives[nestedKey] = inner;
    _expandedZipKeys.add(nestedKey);
    _collectNestedZips(ownerZipDiskPath, inner, '', innerFull);
  } catch (_) {}
}
    }
  }

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

  Future<void> _toggleZipExpand(_DisplayItem zipItem) async {
    if (zipItem.isZipInner) {
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

  // ignore: unused_element
  void _onStickyZipTap(String zipDiskPath) {
    _collapseZip(zipDiskPath);
  }

  // ==================== 打开 / 查看 ====================

  Future<void> _handleTapItem(_DisplayItem item) async {
    if (item.key.startsWith('__loading__') ||
        item.key.startsWith('__error__')) {
      return;
    }

    if (item.isZip) {
      await _toggleZipExpand(item);
      return;
    }

    if (item.isZipInner && item.isDir) {
      return;
    }

    if (item.isZipInner) {
      await _openZipInnerFile(item);
      return;
    }

    if (item.isDir) {
      final p = item.diskPath;
      if (p != null) _navigateTo(p);
      return;
    }

    final p = item.diskPath;
    if (p != null) {
      await _openFile(p, item.displayName, item.size);
    }
  }

  Future<void> _openZipInnerFile(_DisplayItem item) async {
    final ext = _extOf(item.displayName);
    final isText = _textExts.contains(ext);

    final bytes = _readZipInnerBytes(item);
    if (bytes == null) {
      _toast('读取失败');
      return;
    }

    if (isText) {
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
      final tmp = await _writeTempFile(bytes, item.displayName);
      if (tmp == null) {
        _toast('无法创建临时文件');
        return;
      }
      if (!mounted) return;
      await showOpenOrShareSheet(context, tmp, item.displayName);
    }
  }

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

  /// 把 zip 内文件写到临时目录。
///
/// 用固定文件名（不带时间戳）：同名文件自动覆盖，不积累。
/// 上次会话遗留的文件，App 启动时由 _cleanTempDirOnce 清掉。
Future<String?> _writeTempFile(Uint8List bytes, String fileName) async {
  try {
    final dir = Directory.systemTemp;
    final safe = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final path = '${dir.path}/zzz_$safe';
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

    if (_isExpandableArchiveName(name)) {
      if (lowerName.endsWith('.zip') && await _isEncryptedZip(path)) {
        if (!mounted) return;
        await openFileWithSystemPicker(path, context);
        return;
      }
if (!allowExpand) {
  if (!mounted) return;
  await openFileWithSystemPicker(path, context);
  return;
}
      await _expandZip(path);
      return;
    }

    if (_forceSystemPickerExts.any((ext) => lowerName.endsWith(ext))) {
      if (!mounted) return;
      await openFileWithSystemPicker(path, context);
      return;
    }

    await showOpenOrShareSheet(context, path, name);
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
      backgroundColor: Theme.of(context).colorScheme.surface,
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
void _jumpToTop() {
  if (!_itemScrollController.isAttached) return;
  _itemScrollController.jumpTo(index: 0);
}
  void _scrollToPath(String path) {
    final allItems = _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
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
    final color = _fileIconColor(context, isDir: isDir);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Icon(icon, color: color),
    );
  }

  // ==================== 搜索 ====================

  void _onSearchChanged(String v) {
  final mode = ref.read(searchBoxModeProvider);
  if (mode == SearchBoxMode.filter) {
    _onFilterTextChanged(v);
  } else {
    setState(() {});
  }
}
// ==================== 过滤 ====================

void _onFilterTextChanged(String q) {
  _filterTaskId++;
  setState(() {
    // 过滤条件变了，屏幕上看得见的项也跟着变了。
    // 把已经不在可见列表里的选中项清掉，避免"看不见却选着"
    // 导致数量对不上、删/移动/复制时误伤隐藏文件。
    if (ref.read(searchBoxModeProvider) == SearchBoxMode.filter) {
      final visible = _computeVisibleItems(_buildDisplayItems());
      final visibleKeys = visible.map((it) => it.key).toSet();
      _selectedPaths.removeWhere((k) => !visibleKeys.contains(k));
      if (_selectedPaths.isEmpty) {
        _selectionMode = false;
        _anchorPath = null;
      }
    }
  });
}

List<_DisplayItem> _computeVisibleItems(List<_DisplayItem> all) {
  if (_searchActive) return all;
  if (ref.read(searchBoxModeProvider) != SearchBoxMode.filter) return all;

  final q = _searchCtrl.text.trim().toLowerCase();
  if (q.isEmpty) return all;

  final matchedTop = <String>{};
  for (final it in all) {
    if (it.depth != 0) continue;
    if (it.displayName.toLowerCase().contains(q)) {
      matchedTop.add(it.key);
    }
  }

  return [
    for (final it in all)
      if (it.depth == 0 && matchedTop.contains(it.key))
        it
      else if (it.ownerZipKey != null &&
          matchedTop.contains(it.ownerZipKey))
        it,
  ];
}

List<EntryInfo> _filterEntries(List<EntryInfo> entries) {
  if (ref.read(searchBoxModeProvider) != SearchBoxMode.filter) {
    return entries;
  }
  final q = _searchCtrl.text.trim().toLowerCase();
  if (q.isEmpty) return entries;
  return entries
      .where((e) => e.name.toLowerCase().contains(q))
      .toList();
}

void _clearFilter() {
  _searchTaskId++;
  _filterTaskId++;
  _searchCtrl.clear();
  _selectionMode = false;
  _selectedPaths.clear();
  _anchorPath = null;
  setState(() {});
}
  void _doSearch() {
  final q = _searchCtrl.text.trim();
  if (q.isEmpty && !_hasActiveConditions) return;

  // 关键词变了 → 清空高级搜索条件，关闭面板。
  // 用户从"搜张三+排除斗罗"改到"搜我吃西红柿"时，条件不应跟着走。
  if (_lastSearchedQuery != q) {
    if (_searchConditions.isNotEmpty) {
      _clearConditions();
      _advancedOverlay?.remove();
      _advancedOverlay = null;
      _advancedOpen = false;
    }
    _lastSearchedQuery = q;
  }

  if (q.isNotEmpty) {
    ref.read(browserSearchHistoryProvider.notifier).add(q);
  }
  setState(() {
    _searchActive = true;
    _bodyRevision++; // 搜索/普通列表共用 _itemScrollController，整体重建避免交叉淡入期双挂载
  });
  _startSearch();
}
/// 只清空输入框，退出搜索交给 AppBar 的返回箭头。
void _clearSearchInput() {
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
    // 注意：_searchActive 保持 true，留在搜索模式
  });
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
      _bodyRevision++; // 退出搜索时整体重建，避免新旧列表交叉淡入双挂载 controller
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

  List<String> _dedupFolders(List<String> folders) {
    final sorted = List<String>.from(folders)..sort();
    final out = <String>[];
    for (final f in sorted) {
      final covered = out.any((p) => f == p || f.startsWith('$p/'));
      if (!covered) out.add(f);
    }
    return out;
  }

Future<void> _startSearch() async {
  final taskId = ++_searchTaskId;
  final q = _searchCtrl.text.trim();
  if (q.isEmpty && !_hasActiveConditions) {
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
      _toast('请先点击左侧搜索设置 → 管理搜索范围');
      if (mounted) setState(() => _searching = false);
      return;
    }
    roots.addAll(_dedupFolders(customFolders));
  }

  final results = <_SearchHit>[];

  for (final root in roots) {
    if (taskId != _searchTaskId) return;
    await _scanDir(root, results, taskId);
  }

  if (taskId != _searchTaskId) return;
  if (!mounted) return;

  final sortField = ref.read(searchSortFieldProvider);
  final sortAsc = ref.read(searchSortAscProvider);

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

        if (_matchNameForSearch(name)) {
          DateTime? modified;
          try {
            final st = await e.stat();
            modified = st.modified;
          } catch (_) {}

          results.add(_SearchHit(
            path: e.path,
            name: name,
            isDir: true,
            size: null,
            modified: modified,
          ));

          final now = DateTime.now();
          if (mounted &&
              now.difference(_lastUiRefresh).inMilliseconds > 100) {
            _lastUiRefresh = now;
            setState(() => _searchResults = List.from(results));
          }
        }

        await _scanDir(e.path, results, taskId);
      } else if (e is File) {
        final name = e.path.split('/').last;
        if (_matchNameForSearch(name)) {
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
            isDir: false,
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
    _startSearch();
      }
    }
  }

  // ==================== 对比 / MD5 / 属性 / 复制路径 ====================

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

      final leftBytes = await _readBytesOfItem(items[0]);
      if (leftBytes == null) throw Exception('读取左侧文件失败');
      final leftParsed = await DocumentParser.parse(
        fileName: items[0].displayName,
        bytes: leftBytes,
      );
      leftText = leftParsed.plainText;
      leftName = leftParsed.fileName;
      leftPath = items[0].isDiskItem ? items[0].diskPath : null;

      final rightBytes = await _readBytesOfItem(items[1]);
      if (rightBytes == null) throw Exception('读取右侧文件失败');
      final rightParsed = await DocumentParser.parse(
        fileName: items[1].displayName,
        bytes: rightBytes,
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
      ref.read(originalSharedTempPathProvider.notifier).state = null;
      ref.read(modifiedSharedTempPathProvider.notifier).state = null;
      ref.read(importRevisionProvider.notifier).state++;
      ref.read(editedOriginalProvider.notifier).state = null;
      ref.read(editedModifiedProvider.notifier).state = null;

      await Navigator.of(context).push(
        PageRouteBuilder<void>(
          pageBuilder: (_, __, ___) => const DiffViewerScreen(),
          // 零转场：进入/退出对比页均无动画，保证"加载小圈→表情圆环"接力不中断
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
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
                      color: same
                          ? Theme.of(c).colorScheme.primary
                          : Theme.of(c).colorScheme.error,
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

// ==================== 当前目录信息 ====================

Future<void> _showDirInfoDialog() async {
  if (_loading) {
    _toast('目录还在加载中，请稍候');
    return;
  }

  final entries = _entries ?? const <EntryInfo>[];

  var dirCount = 0;
  var fileCount = 0;
  var totalBytes = 0;
  var hasUnknownSize = false;

  var textCount = 0;
  var imageCount = 0;
  var videoCount = 0;
  var audioCount = 0;
  var archiveCount = 0;
  var otherCount = 0;

  int? maxSize;
  String? maxSizeName;
  DateTime? newestTime;
  String? newestName;
  DateTime? oldestTime;
  String? oldestName;

  for (final info in entries) {
    if (info.isDir) {
      dirCount++;
      continue;
    }
    fileCount++;

    final sz = info.size;
    if (sz != null) {
      totalBytes += sz;
      if (maxSize == null || sz > maxSize) {
        maxSize = sz;
        maxSizeName = info.name;
      }
    } else {
      hasUnknownSize = true;
    }

    final t = info.modified;
    if (t != null) {
      if (newestTime == null || t.isAfter(newestTime)) {
        newestTime = t;
        newestName = info.name;
      }
      if (oldestTime == null || t.isBefore(oldestTime)) {
        oldestTime = t;
        oldestName = info.name;
      }
    }

    final ext = _extOf(info.name);
    if (_textExts.contains(ext)) {
      textCount++;
    } else if (_imageExts.contains(ext)) {
      imageCount++;
    } else if (_videoExts.contains(ext)) {
      videoCount++;
    } else if (_audioExts.contains(ext)) {
      audioCount++;
    } else if (_archiveExts.contains(ext)) {
      archiveCount++;
    } else {
      otherCount++;
    }
  }

  if (!mounted) return;

  final sortField = ref.read(sortFieldProvider);
  final sortAsc = ref.read(sortAscProvider);
  final gridMode = ref.read(browserGridModeProvider);

  String sizeText;
  if (hasUnknownSize) {
    sizeText = '${_formatSize(totalBytes)} + 部分未统计';
  } else {
    sizeText = _formatSize(totalBytes);
  }

  await showDialog<void>(
    context: context,
    builder: (c) {
      final s = Theme.of(c).colorScheme;

      Widget kv(String label, String value, {bool selectable = false}) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(c).textTheme.labelSmall),
              const SizedBox(height: 2),
              selectable
                  ? SelectableText(value, style: const TextStyle(fontSize: 13))
                  : Text(value, style: const TextStyle(fontSize: 13)),
            ],
          ),
        );
      }

      return AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        title: const Text('当前目录信息'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(c).size.height * 0.7,
          ),
          child: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  kv('路径', _currentPath, selectable: true),
                  const SizedBox(height: 4),

                  Text(
                    '共 ${entries.length} 项',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$dirCount 个文件夹 · $fileCount 个文件',
                    style: TextStyle(
                      fontSize: 13,
                      color: s.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),

                  kv('总大小（不含子目录）', sizeText),

                  if (maxSizeName != null)
                    kv('最大文件',
                        '$maxSizeName（${_formatSize(maxSize!)}）'),

                  if (newestTime != null)
                    kv('最新文件',
                        '$newestName（${_formatTime(newestTime!)}）'),

                  if (oldestTime != null)
                    kv('最旧文件',
                        '$oldestName（${_formatTime(oldestTime!)}）'),

                  kv('当前排序',
                      '${_sortLabel(sortField)} · ${sortAsc ? "升序" : "降序"}'),

                  kv('显示模式', gridMode ? '网格' : '列表'),

                  const SizedBox(height: 4),
                  const Divider(height: 1),
                  const SizedBox(height: 8),

                  Text(
                    '类型分布',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: s.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '文本 $textCount · 图片 $imageCount · 视频 $videoCount · '
                    '音频 $audioCount · 压缩包 $archiveCount · 其他 $otherCount',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
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
  );
}

  // ==================== 收藏 / 配置 ====================

  void _toggleSearchBarCollapsed() {
    final notifier = ref.read(searchBarCollapsedProvider.notifier);
    final currentlyCollapsed = ref.read(searchBarCollapsedProvider);

    if (currentlyCollapsed) {
      // 展开 + 自动聚焦
      notifier.update(false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    } else {
      // 折叠：只收起 UI，不清空搜索内容（对标 Solid Explorer）。
      // 想清空请用输入框右边的 × 按钮。
      FocusManager.instance.primaryFocus?.unfocus();
      notifier.update(true);
    }
  }

  /// 搜索栏区域当前是否可见。
  /// - 选择模式：始终可见（显示提示条）
  /// - 始终显示：可见
  /// - 可折叠 + 已折叠：隐藏
  bool get _searchBarAreaVisible {
    if (_selectionMode) return true;
    if (ref.watch(searchBarVisibilityProvider) ==
        SearchBarVisibility.alwaysVisible) {
      return true;
    }
    return !ref.watch(searchBarCollapsedProvider);
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
          final cs = Theme.of(context).colorScheme;

          return AlertDialog(
            insetPadding: const EdgeInsets.all(16),
            title: const Text('已收藏目录'),
            content: SizedBox(
              width: 360,
              height: MediaQuery.of(context).size.height * 0.55,
              child: Column(
                children: [
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        isFav ? Icons.star : Icons.star_border,
                        color: isFav ? Colors.amber : cs.onSurfaceVariant,
                      ),
                      title: Text(
                        isFav ? '取消收藏当前目录' : '收藏当前目录',
                        style: TextStyle(color: cs.onSurface),
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
                          ? Center(
                              child: Text(
                                '还没有收藏任何目录',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: favorites.length,
                              itemBuilder: (ctx, i) {
                                final p = favorites[i];
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    Icons.folder,
                                    color: cs.primary,
                                  ),
                                  title: Text(
                                    p,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => Navigator.pop(c, p),
                                  trailing: IconButton(
                                    icon: Icon(
                                      Icons.delete_outline,
                                      size: 20,
                                      color: cs.onSurfaceVariant,
                                    ),
                                    tooltip: '移除收藏',
                                    onPressed: () async {
                                      final ok = await showDialog<bool>(
                                        context: ctx,
                                        builder: (dc) => AlertDialog(
                                          title: const Text('移除收藏？'),
                                          content: Text(p),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(dc, false),
                                              child: const Text('取消'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(dc, true),
                                              child: const Text('移除'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok != true) return;
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
    // 权限被收回时 existsSync 也会返回 false。
    // 不自动删收藏，让用户自己决定。
    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: _dlgInset,
        title: const Text('目录打不开'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('无法访问：', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(
              picked,
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
            const Text(
              '这条收藏要保留吗？',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('保留'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(c, 'remove'),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (action == 'remove' && mounted) {
      ref.read(favoritesProvider.notifier).remove(picked);
      _toast('已移除');
    }
  }
}
  }

  // ==================== 文件操作 ====================

  // 记录上一次 toast 的消息和时间，用于"短时间内相同消息不重复弹"。
  String? _lastToastMsg;
  DateTime? _lastToastTime;

  void _toast(String msg) {
    if (!mounted) return;

    // 去重：1.5 秒内同一条消息不再重弹。
    final now = DateTime.now();
    if (_lastToastMsg == msg &&
        _lastToastTime != null &&
        now.difference(_lastToastTime!) < const Duration(milliseconds: 1500)) {
      return;
    }
    _lastToastMsg = msg;
    _lastToastTime = now;

    final ms = msg.length <= 10 ? 1500 : 2000;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onInverseSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
        duration: Duration(milliseconds: ms),
        // 悬浮样式：浮在底部操作栏上方，不会被遮挡。
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: 72,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<bool> _confirm(String title, String message) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 32,
          vertical: 24,
        ),
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
_load(restoreScroll: true, silent: true);
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
  final target = await _pickDirectory('移动到哪？', paths);
  if (target == null) return;

  // 冲突预检
  final conflictNames = <String>[];
  for (final src in paths) {
    final name = src.split('/').last;
    final dst = '$target/$name';
    if (src == dst) continue;
    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      conflictNames.add(name);
    }
  }

  _ConflictAction? action;
  if (conflictNames.isNotEmpty) {
    action = await _askConflict(conflictNames);
    if (action == null) return; // 用户取消
  }

 var ok = 0, fail = 0, skipped = 0;
final movedSources = <String>{};
for (final src in paths) {
    final name = src.split('/').last;
    var dst = '$target/$name';
    if (src == dst) continue;

    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      if (action == _ConflictAction.skip) {
        skipped++;
        continue;
      } else if (action == _ConflictAction.rename) {
        dst = _findNonConflictPath(dst);
      } else if (action == _ConflictAction.overwrite) {
        try {
          if (Directory(dst).existsSync()) {
            await Directory(dst).delete(recursive: true);
          } else {
            await File(dst).delete();
          }
        } catch (_) {}
      }
    }

    try {


		
       if (Directory(src).existsSync()) {
      await Directory(src).rename(dst);
    } else {
      await File(src).rename(dst);
    }
    ok++;
    movedSources.add(src);
  } catch (_) {
    fail++;
  }
}

 if (ok > 0) {
  ref.read(recentMoveTargetsProvider.notifier).add(target);
  DirCache.instance.invalidate(target);
}
_clearSelection();

if (movedSources.isNotEmpty && target != _currentPath) {
  // 目标不是当前目录：就地剔除源
  setState(() {
    _entries = (_entries ?? const <EntryInfo>[])
        .where((e) => !movedSources.contains(e.path))
        .toList();
  });
  DirCache.instance.applyToAll(
    _currentPath,
    (list) => list
        .where((e) => !movedSources.contains(e.path))
        .toList(),
  );
} else if (target == _currentPath) {
  // 目标就是当前目录（少见）：退化为静默重载
  _load(restoreScroll: true, silent: true);
}

final parts = <String>['已移动 $ok 项'];
	  
  if (skipped > 0) parts.add('跳过 $skipped 项');
  if (fail > 0) parts.add('$fail 项失败');
  _toast(parts.join('，'));
}

 Future<void> _copy() async {
  final paths = _selectedDiskPaths();
  if (paths.isEmpty) {
    _toast('压缩包内的文件不支持复制');
    return;
  }
  final target = await _pickDirectory('复制到哪？', paths);
  if (target == null) return;

  final conflictNames = <String>[];
  for (final src in paths) {
    final name = src.split('/').last;
    final dst = '$target/$name';
    if (src == dst) continue;
    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      conflictNames.add(name);
    }
  }

  _ConflictAction? action;
  if (conflictNames.isNotEmpty) {
    action = await _askConflict(conflictNames);
    if (action == null) return;
  }

  var ok = 0, fail = 0, skipped = 0;
  for (final src in paths) {
    final name = src.split('/').last;
    var dst = '$target/$name';
    if (src == dst) continue;

    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      if (action == _ConflictAction.skip) {
        skipped++;
        continue;
      } else if (action == _ConflictAction.rename) {
        dst = _findNonConflictPath(dst);
      } else if (action == _ConflictAction.overwrite) {
        try {
          if (Directory(dst).existsSync()) {
            await Directory(dst).delete(recursive: true);
          } else {
            await File(dst).delete();
          }
        } catch (_) {}
      }
    }

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
  if (target == _currentPath) {
    DirCache.instance.invalidate(_currentPath);
  }
}
_clearSelection();
_load(restoreScroll: true, silent: true);

final parts = <String>['已复制 $ok 项'];
  if (skipped > 0) parts.add('跳过 $skipped 项');
  if (fail > 0) parts.add('$fail 项失败');
  _toast(parts.join('，'));
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
Future<_ConflictAction?> _askConflict(List<String> conflictNames) async {
  return showDialog<_ConflictAction>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      insetPadding: _dlgInset,
      title: const Text('目标目录有同名项'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(c).size.height * 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('以下 ${conflictNames.length} 个名称已在目标目录中存在：'),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: conflictNames.length,
                itemBuilder: (ctx, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '· ${conflictNames[i]}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, _ConflictAction.skip),
          child: const Text('跳过'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(c).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(c, _ConflictAction.overwrite),
          child: const Text('覆盖'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, _ConflictAction.rename),
          child: const Text('重命名'),
        ),
      ],
    ),
  );
}

/// 给 dst 找一个不冲突的路径：加 " (1)" " (2)" 之类的后缀。
String _findNonConflictPath(String originalDst) {
  final dotIdx = originalDst.lastIndexOf('.');
  final slashIdx = originalDst.lastIndexOf('/');
  final hasExt = dotIdx > slashIdx && dotIdx < originalDst.length - 1;
  final base = hasExt ? originalDst.substring(0, dotIdx) : originalDst;
  final ext = hasExt ? originalDst.substring(dotIdx) : '';
  for (var i = 1; i < 10000; i++) {
    final candidate = '$base ($i)$ext';
    if (FileSystemEntity.typeSync(candidate) ==
        FileSystemEntityType.notFound) {
      return candidate;
    }
  }
  return '$base (${DateTime.now().millisecondsSinceEpoch})$ext';
}

  Future<void> _delete() async {
    final paths = _selectedDiskPaths();
    if (paths.isEmpty) {
      _toast('压缩包内的文件不支持删除');
      return;
    }
    final n = paths.length;
final ok = await showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _DeleteConfirmDialog(paths: paths),
);
if (ok != true) return;

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
  // 就地移除，不重载
  setState(() {
    _entries = (_entries ?? const <EntryInfo>[])
        .where((e) => !deletedPaths.contains(e.path))
        .toList();
  });
  DirCache.instance.applyToAll(
    _currentPath,
    (list) => list
        .where((e) => !deletedPaths.contains(e.path))
        .toList(),
  );
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
_load(silent: true);
_toast('已新建 $trimmed');
    } catch (e) {
      _toast('新建失败：$e');
    }
  }

  Future<void> _showJumpToPathDialog() async {
    final ctrl = TextEditingController();
    final cs = Theme.of(context).colorScheme;
    final path = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 32,
          vertical: 24,
        ),
        title: const Text('跳转到目录'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '输入或粘贴完整路径',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '/storage/emulated/0/xxx',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: cs.primary, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                onSubmitted: (v) => Navigator.pop(c, v),
              ),
              const SizedBox(height: 8),
              Text(
                '若粘贴的是文件路径，会跳到该文件所在目录',
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                ),
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

  var target = path.trim();
  if (target.isEmpty) return;

  // 常见路径前缀统一换成 /storage/emulated/0
  target = _normalizePath(target);

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

/// 归一化用户粘贴的路径。
/// · /sdcard/...         → /storage/emulated/0/...
/// · /storage/self/primary/... → /storage/emulated/0/...
/// · /storage/emulated/legacy/... → /storage/emulated/0/...
/// · /mnt/sdcard/...     → /storage/emulated/0/...
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




	  
  

  Future<String?> _pickDirectory(String title, List<String> pickedPaths) async {
  return showDialog<String>(
    context: context,
    builder: (_) => DirectoryPickerDialog(
      title: title,
      rootPath: _topPath,
      initialPath: _currentPath,
      pickedPaths: pickedPaths,
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
          color: _selectionMode ? s.outlineVariant : s.outline,
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
                    ? s.onSurfaceVariant.withValues(alpha: 0.4)
                    : (isLast ? s.onSurface : s.onSurfaceVariant),
                fontWeight: isLast ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
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
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
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
  
  // ==================== build ====================
    // ==================== build ====================
    @override
    Widget build(BuildContext context) {
      _cachedDisplayItems = _buildDisplayItems();
      _visibleItems = _computeVisibleItems(_cachedDisplayItems!);
      return PopScope(
        canPop: _currentPath == _topPath &&
            !_selectionMode &&
            !_searchActive &&
            _expandedZipKeys.isEmpty,
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
          } else if (_canGoUp) {
            _goUp();
          }
          // 在存储选择页（_topPath）时 canPop 为 true，
          // 路由会直接 pop（退出 App 回到桌面），不走这里。
        },

      child: Scaffold(
        appBar:
            _selectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
       body: SafeArea(
  top: false,
  child: Stack(
    children: [
      Column(
        children: [
          _buildBreadcrumbs(),
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: _searchBarAreaVisible
                  ? _buildTopBarWithSelectionOverlay()
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ),
          Expanded(child: _buildBodyWithOverlays()),
        ],
      ),
      // 选中底栏改为覆盖层：ScrollablePositionedList 是底部锚定的，
      // 用 bottomNavigationBar 改变列表高度会让整个列表上下跳动。
      if (_selectionMode)
        Positioned(left: 0, right: 0, bottom: 0, child: _buildBottomBar()),
    ],
  ),
),
        floatingActionButton: null,
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar() {
    final favorites = ref.watch(favoritesProvider);
    final isFav = favorites.contains(_currentPath);
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.surface, // 顶栏与主题同色
      surfaceTintColor: Colors.transparent, // Material3 下防止主题色 tint 覆盖
      elevation: 0, // 不要阴影，保持和面包屑同一平面
      title: GestureDetector(
        onLongPress: _showJumpToPathDialog,
        child: Text(
          (_searchActive &&
                  ref.watch(searchScopeProvider) == SearchScope.custom)
              ? '自定义的搜索范围'
              : _title,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
          ),
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
        // 折叠按钮：只在 collapsible 时显示
        if (ref.watch(searchBarVisibilityProvider) ==
            SearchBarVisibility.collapsible)
          IconButton(
                  iconSize: 22,
                  icon: Icon(
                    ref.watch(searchBarCollapsedProvider)
                        ? Icons.search
                        : Icons.search_off,
                  ),
            tooltip: ref.watch(searchBarCollapsedProvider)
                ? '展开搜索栏'
                : '收起搜索栏',
            onPressed: _toggleSearchBarCollapsed,
          ),
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
          tooltip: '对比规则设置',
          onPressed: () {
            Navigator.of(context).push(_noAnimRoute(
              const ComparisonSettingsScreen(),
            ));
          },
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: '更多',
          
          
          onSelected: (v) async {
  switch (v) {
    case 'browserSettings':
      final beforeField = ref.read(sortFieldProvider);
      final beforeAsc = ref.read(sortAscProvider);
      await Navigator.of(context).push(_noAnimRoute(
        const BrowserSettingsScreen(),
      ));
      if (!mounted) return;
      final afterField = ref.read(sortFieldProvider);
      final afterAsc = ref.read(sortAscProvider);
      if (beforeField != afterField || beforeAsc != afterAsc) {
        DirCache.instance.invalidate(_currentPath);
        _load();
      }
    case 'searchSettings':
      _showSearchSettings();
    case 'exportConfig':
      _exportConfig();
    case 'importConfig':
      _importConfig();
   case 'refresh':
  DirCache.instance.invalidate(_currentPath);
  _load(skipCache: true);
case 'jumpToPath':
  _showJumpToPathDialog();
case 'jumpToTop':
  _jumpToTop();
case 'dirInfo':
  _showDirInfoDialog();
case 'favorites':
  _showFavorites();
    case 'newFolder':
      _newFolder();
    case 'help':
      Navigator.of(context).push(_noAnimRoute(const HelpScreen()));
  }
},
          itemBuilder: (context) => [
            const PopupMenuItem<String>(
              value: 'browserSettings',
              child: Text('浏览器设置'),
            ),
            const PopupMenuItem<String>(
              value: 'searchSettings',
              child: Text('搜索设置'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'exportConfig',
              child: Text('导出配置'),
            ),
            const PopupMenuItem<String>(
              value: 'importConfig',
              child: Text('导入配置'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'refresh',
              child: Text('刷新'),
            ),
            const PopupMenuItem<String>(
              value: 'jumpToPath',
              child: Text('跳转到目录'),
            ),
            const PopupMenuItem<String>(
              value: 'jumpToTop',
              child: Text('跳到此目录顶部'),
            ),
            const PopupMenuItem<String>(
              value: 'dirInfo',
              child: Text('当前目录信息'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'favorites',
              child: Text('已收藏目录 (${favorites.length})'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'newFolder',
              child: Text('新建文件夹'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'help',
              child: Text('使用说明'),
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
    final all =
        _visibleItems ?? _cachedDisplayItems ?? const <_DisplayItem>[];
    final selectable = all
        .where((it) => !it.key.startsWith('__loading__') &&
            !it.key.startsWith('__error__'))
        .map((it) => it.key)
        .toList();
    final allSelected = selectable.isNotEmpty &&
        selectable.every((k) => _selectedPaths.contains(k));
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
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


/// 顶部区域：搜索栏（+状态栏/展开条）。
/// 选择模式下不替换，而是把提示条覆盖在上面。
/// 用 Stack + Visibility(maintainSize) 保证两种模式高度一致，
/// 否则 Expanded 的列表会跟着上下跳。
/// ExcludeFocus 在选择模式下把搜索框的焦点断掉，
/// 防止透明状态下仍弹输入法。
Widget _buildTopBarWithSelectionOverlay() {
  final normal = ExcludeFocus(
    excluding: _selectionMode,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchBar(),
        if (_searchActive) _buildSearchStatusBar(),
        if (!_searchActive && _expandedZipKeys.isNotEmpty)
          _buildExpandedZipBar(),
      ],
    ),
  );

  return Stack(
    children: [
      // 高度基准。选择模式下隐藏但仍占位。
      Visibility(
        visible: !_selectionMode,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: normal,
      ),
      if (_selectionMode)
        Positioned.fill(child: _buildSelectionHintBar()),
    ],
  );
}

/// 选中模式下替代搜索栏显示的提示条。
/// 高度与搜索栏（8 + 44 + 4 ≈ 56）对齐，切换时不跳动。
Widget _buildSelectionHintBar() {
  final n = _selectedPaths.length;
  final items = _resolveSelectedItems();

  bool isComparable(_DisplayItem it) =>
      !it.isDir && !(it.isZip && !it.isZipInner);

  final allComparable =
      items.isNotEmpty && items.every(isComparable);

  String line1;
  String line2;

  if (allComparable && n == 2) {
    // 两个文件都在，左右已经可以自证，直接给出角色
    line1 = '左：${items[0].displayName}';
    line2 = '右：${items[1].displayName} · 可对比 / MD5 对比';
  } else {
    line1 = '长按另一个文件可进行区间选择，点击可继续加选';
    if (allComparable && n == 1) {
      line2 = '此项会放在对比页左边';
    } else {
      line2 = '如果想对比文件，请选择两个文件';
    }
  }

  final cs = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    // 高度不再写死：由 Positioned.fill 从 Stack 拉满，
    // 等于搜索栏（+状态栏/展开条）的实际高度，切换选择模式时列表不动。
    margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    decoration: BoxDecoration(
      color: cs.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: cs.outlineVariant),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          line1,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.25,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          line2,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.25,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

  Widget _buildSearchBar() {
  final cs = Theme.of(context).colorScheme;
  final scope = ref.watch(searchScopeProvider);
  final mode = ref.watch(searchBoxModeProvider);
  final isFilter = mode == SearchBoxMode.filter;
  final isCustom = scope == SearchScope.custom;
  final customFolders = ref.watch(customSearchFoldersProvider);
  final hasText = _searchCtrl.text.isNotEmpty;
  final focused = _searchFocus.hasFocus;

  // ===== 左侧标签 =====
  final String label;
  final String? badge;
  if (isFilter) {
    label = '过滤';
    badge = null;
  } else if (isCustom) {
    label = '自定义';
    badge = customFolders.isEmpty ? null : '${customFolders.length}';
  } else {
    label = '当前目录';
    badge = null;
  }

  // ===== 输入框占位文案 =====
  final String hintText;
  if (isFilter) {
    hintText = '过滤当前目录';
  } else if (isCustom) {
    if (customFolders.isEmpty) {
      hintText = '点左侧标签设置搜索范围';
    } else if (customFolders.length == 1) {
      hintText = '在 1 个自定义目录中搜索';
    } else {
      hintText = '在 ${customFolders.length} 个自定义目录中搜索';
    }
  } else {
    hintText = '在当前目录中搜索';
  }

  // ===== 右侧按钮：形状区分模式 =====
  final IconData actionIcon =
      isFilter ? Icons.filter_alt_outlined : Icons.search;
  final Color actionColor = (isFilter || !hasText)
      ? cs.onSurfaceVariant
      : cs.onSurface;

  // ===== 输入框形状：搜索=胶囊，过滤=圆角矩形 =====
  final double radius = isFilter ? 8.0 : 22.0;
  final Color borderColor = focused ? cs.onSurface : cs.outline;
  final double borderWidth = focused ? 1.5 : 1.0;

  // ===== 标签颜色：聚焦或有字时加深 =====
  final bool labelActive = focused || hasText;
  final Color labelColor =
      labelActive ? cs.onSurface : cs.onSurfaceVariant;

  return TapRegion(
    onTapOutside: (_) {
      FocusManager.instance.primaryFocus?.unfocus();
    },
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          // ===== 左侧活字标签 =====
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _showSearchSettings,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: labelActive
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: labelColor,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 3),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: cs.surfaceVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 3),
                    Icon(
                      Icons.settings_outlined,
                      size: 14,
                      color: labelColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),

          // ===== 输入框 =====
          Expanded(
            child: AnimatedContainer(
              key: _searchBarBoxKey,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: borderColor,
                  width: borderWidth,
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: _searchInputKey,
                      controller: _searchCtrl,
                      focusNode: _searchFocus,
                      cursorColor: cs.primary,
                      style: TextStyle(fontSize: 14, color: cs.onSurface),
                      decoration: InputDecoration(
                        hintText: hintText,
                        hintStyle: TextStyle(
                          fontSize: 14,
                          color: cs.onSurfaceVariant,
                        ),
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: _onSearchChanged,
                      onSubmitted: isFilter
                          ? (_) => FocusManager.instance
                              .primaryFocus
                              ?.unfocus()
                          : (_) => _doSearch(),
                    ),
                  ),
                  // 条件徽章：只显示数字，点它打开高级面板
                  if (_hasActiveConditions)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _toggleAdvanced,
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '条件·$_activeConditionCount',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: cs.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 高级搜索（仅搜索模式 + 有文字时出现）
                  if (hasText && !isFilter) _buildAdvancedToggle(),
                  // 清空 / 历史
                  SizedBox(
                    width: 40,
                    height: 44,
                    child: InkResponse(
                      onTap: hasText
                          ? (isFilter ? _clearFilter : _clearSearchInput)
                          : _showSearchHistory,
                      radius: 20,
                      child: Tooltip(
                        message: hasText ? '清空输入' : '搜索历史',
                        child: Icon(
                          hasText ? Icons.close : Icons.history,
                          size: 20,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),

          // ===== 右侧执行 / 标识按钮 =====
          SizedBox(
            width: 44,
            height: 44,
            child: InkResponse(
              radius: 22,
              onTap: () {
                if (isFilter) {
                  // 过滤模式：点击 = 收键盘（过滤是实时的，无"执行"语义）
                  FocusManager.instance.primaryFocus?.unfocus();
                } else if (hasText || _hasActiveConditions) {
                  _doSearch();
                } else {
                  // 搜索模式无内容：聚焦输入框
                  _searchFocus.requestFocus();
                }
              },
              child: Icon(actionIcon, size: 22, color: actionColor),
            ),
          ),
        ],
      ),
    ),
  );
}
Future<void> _showSearchSettings() async {
  FocusManager.instance.primaryFocus?.unfocus();

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (c) => Consumer(
      builder: (c, ref, _) {
        final cs = Theme.of(c).colorScheme;
        final scope = ref.watch(searchScopeProvider);
        final customFolders = ref.watch(customSearchFoldersProvider);
        final searchSortField = ref.watch(searchSortFieldProvider);
        final searchSortAsc = ref.watch(searchSortAscProvider);
        final boxMode = ref.watch(searchBoxModeProvider);
        final isFilter = boxMode == SearchBoxMode.filter;

        final String scopeLabel;
        if (isFilter) {
          scopeLabel = '过滤当前目录';
        } else if (scope == SearchScope.custom) {
          scopeLabel = '在 ${customFolders.length} 个自定义目录中搜索';
        } else {
          scopeLabel = '在当前目录及子目录中搜索';
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 标题
                Text(
                  '搜索设置',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  scopeLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),

                // ===== 搜索框行为 =====
                _settingsSectionHeader(cs, '搜索框行为'),
                const SizedBox(height: 8),
                _settingsChoiceGroup<SearchBoxMode>(
                  context: context,
                  cs: cs,
                  value: boxMode,
                  onChanged: (v) => ref
                      .read(searchBoxModeProvider.notifier)
                      .update(v),
                  options: const [
                    (
                      value: SearchBoxMode.search,
                      label: '搜索',
                      hint: '回车或点搜索按钮才执行，扫子目录',
                    ),
                    (
                      value: SearchBoxMode.filter,
                      label: '过滤',
                      hint: '边打字边筛，只当前目录',
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // ===== 搜索模式：范围 + 排序 =====
                if (!isFilter) ...[
                  _settingsSectionHeader(cs, '搜索范围'),
                  const SizedBox(height: 8),
                  _settingsChoiceGroup<SearchScope>(
                    context: context,
                    cs: cs,
                    value: scope,
                    onChanged: (v) {
                      ref.read(searchScopeProvider.notifier).update(v);
                      if (_searchActive && _searchCtrl.text.isNotEmpty) {
                        _startSearch();
                      }
                    },
                    options: const [
                      (
                        value: SearchScope.currentRecursive,
                        label: '当前目录及子目录',
                        hint: null,
                      ),
                      (
                        value: SearchScope.custom,
                        label: '自定义的搜索范围',
                        hint: null,
                      ),
                    ],
                  ),
                  if (scope == SearchScope.custom) ...[
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: cs.primary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.folder_special, size: 16),
                        label: Text(
                          customFolders.isEmpty
                              ? '选择搜索目录'
                              : '管理搜索目录（${customFolders.length}）',
                          style: const TextStyle(fontSize: 13),
                        ),
                        onPressed: () => _showSearchFolderPicker(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),

                  _settingsSectionHeader(cs, '结果排序'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _settingsSortChip(
                        cs: cs,
                        label: '名称',
                        selected: searchSortField == SortField.name,
                        onTap: () {
                          ref
                              .read(searchSortFieldProvider.notifier)
                              .update(SortField.name);
                          _resortSearchResults();
                        },
                      ),
                      _settingsSortChip(
                        cs: cs,
                        label: '修改时间',
                        selected: searchSortField == SortField.modified,
                        onTap: () {
                          ref
                              .read(searchSortFieldProvider.notifier)
                              .update(SortField.modified);
                          _resortSearchResults();
                        },
                      ),
                      _settingsSortChip(
                        cs: cs,
                        label: '大小',
                        selected: searchSortField == SortField.size,
                        onTap: () {
                          ref
                              .read(searchSortFieldProvider.notifier)
                              .update(SortField.size);
                          _resortSearchResults();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _settingsSortChip(
                        cs: cs,
                        label: '升序',
                        selected: searchSortAsc,
                        onTap: () {
                          ref
                              .read(searchSortAscProvider.notifier)
                              .update(true);
                          _resortSearchResults();
                        },
                      ),
                      _settingsSortChip(
                        cs: cs,
                        label: '降序',
                        selected: !searchSortAsc,
                        onTap: () {
                          ref
                              .read(searchSortAscProvider.notifier)
                              .update(false);
                          _resortSearchResults();
                        },
                      ),
                    ],
                  ),
                ] else ...[
                  // ===== 过滤模式：说明条 =====
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '过滤只在当前目录内生效。\n'
                      '想跨目录查找，请切回"搜索"模式。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),

                // ===== 完成按钮 =====
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text(
                      '完成',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

// ==================== 搜索设置弹窗 · 小部件 ====================

/// 设置弹窗里的小节标题。13px，主题色，字重 600。
Widget _settingsSectionHeader(ColorScheme cs, String text) {
  return Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: cs.primary,
      letterSpacing: 0.3,
    ),
  );
}

/// 一组单选项，卡片式。第一个和最后一个圆角，中间直角。
/// 每一项：圆点 + 标题 + 可选副标题。
Widget _settingsChoiceGroup<T>({
  required BuildContext context,
  required ColorScheme cs,
  required T value,
  required ValueChanged<T> onChanged,
  required List<({T value, String label, String? hint})> options,
}) {
  return Container(
    decoration: BoxDecoration(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              indent: 44,
              endIndent: 16,
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
          InkWell(
            onTap: () => onChanged(options[i].value),
            borderRadius: i == 0
                ? const BorderRadius.vertical(top: Radius.circular(10))
                : i == options.length - 1
                    ? const BorderRadius.vertical(bottom: Radius.circular(10))
                    : BorderRadius.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      value == options[i].value
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 20,
                      color: value == options[i].value
                          ? cs.primary
                          : cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          options[i].label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: value == options[i].value
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: value == options[i].value
                                ? cs.primary
                                : cs.onSurface,
                          ),
                        ),
                        if (options[i].hint != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            options[i].hint!,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.4,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// 排序胶囊。选中：主题色底 + 主题色边框；未选中：浅灰底。
Widget _settingsSortChip({
  required ColorScheme cs,
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? cs.secondaryContainer : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          color: selected ? cs.onSecondaryContainer : cs.onSurface,
        ),
      ),
    ),
  );
}

void _resortSearchResults() {
  if (_searchResults.isEmpty) return;
  final sortField = ref.read(searchSortFieldProvider);
final sortAsc = ref.read(searchSortAscProvider);
_searchResults.sort((a, b) {
 
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
  setState(() {});
}
/// 有压缩包展开时，在搜索栏下方固定显示一条提示条。
Widget _buildExpandedZipBar() {
  final topLevelCount =
      _expandedZipKeys.where((k) => !_isZipInnerKey(k)).length;
  if (topLevelCount == 0) return const SizedBox.shrink();

  final cs = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    color: cs.secondaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: Row(
      children: [
    Icon(
      Icons.folder_zip_outlined,
      size: 16,
      color: cs.onSecondaryContainer,
    ),
              const SizedBox(width: 8),
        Expanded(
          child: Text(
            '已展开 $topLevelCount 个压缩包',
            style: TextStyle(
              fontSize: 12,
              color: cs.onSecondaryContainer,
            ),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            foregroundColor: cs.onSecondaryContainer,
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
              width: 16,
              height: 16,
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
    // 与提示条同一套判定：文件夹 / 压缩包本体不能对比，按钮置灰。
    final selItems = _resolveSelectedItems();
    bool isComparable(_DisplayItem it) =>
        !it.isDir && !(it.isZip && !it.isZipInner);
    final allComparable =
        selItems.isNotEmpty && selItems.every(isComparable);
    final canCompare = n == 2 && allComparable;
    final canMd5 = n == 2 && allComparable;
    final canProps = n == 1;
    final canOpenWith = n == 1;
    final canShare = n >= 1;
    final allDisk = _selectionAllDisk;

    final canCopyPath = n == 1;
    final canRename = n == 1 && allDisk;
    final canMove = n >= 1 && allDisk;
    final canCopy = n >= 1 && allDisk;
    final canDelete = n >= 1 && allDisk;

    final s = Theme.of(context).colorScheme;

    final outlineStyle = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      foregroundColor: s.onSurface,
      side: BorderSide(color: s.outline),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
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
            SizedBox(
              height: 38,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
child: Row(
  children: [
    SizedBox(
      width: 110,
      height: 38,
      child: FilledButton.icon(
        icon: const Icon(Icons.compare_arrows, size: 16),
        label: const Text(
          '对比',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        onPressed: canCompare ? _startCompare : null,
      ),
    ),
    const SizedBox(width: 4),
    SizedBox(
      width: 76,
      child: OutlinedButton(
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
      width: 76,
      child: OutlinedButton(
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
      width: 76,
      child: OutlinedButton(
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
      width: 76,
      child: OutlinedButton(
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
  ],
),
              ),
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
                    color: canDelete ? s.error : null,
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
    return AnimatedSwitcher(
      key: ValueKey('switcher_$_bodyRevision'),
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: _buildBodyState(),
    );
  }

  // ==================== 列表之上的覆盖层（滚动条 / 悬浮翻页按钮） ====================
  //
  // 不改文件浏览器本身的滚动实现，只在外面盖一层：
  //   · 可拖动滚动条（默认关）
  //   · 上下悬浮翻页按钮（默认关）

  Widget _buildBodyWithOverlays() {
    final scrollbarOn = ref.watch(browserScrollbarEnabledProvider);
    final floatingOn = ref.watch(browserFloatingPageEnabledProvider);
    final body = _buildBody();
    if (!scrollbarOn && !floatingOn) return body;
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        if (scrollbarOn) _buildBrowserScrollbar(),
        if (floatingOn) _buildFloatingPageOverlay(),
      ],
    );
  }

  Widget _buildBrowserScrollbar() {
    final track = ref.watch(browserScrollbarTrackColorProvider);
    final thumb = ref.watch(browserScrollbarThumbColorProvider);
    final opacity = (ref.watch(browserScrollbarOpacityProvider) / 100)
        .clamp(0.0, 1.0)
        .toDouble();
    final width = ref
        .watch(browserScrollbarWidthProvider)
        .clamp(2.0, 28.0)
        .toDouble();

    return Positioned(
      top: 2,
      bottom: 2,
      right: 0,
      width: math.max(width + 12, 24),
      child: _BrowserScrollbar(
        positions: _positionsListener.itemPositions,
        itemCount: () => _scrollItemCount,
        thumbWidth: width,
        trackColor: track.withValues(alpha: opacity * 0.35),
        thumbColor: thumb.withValues(alpha: opacity),
        onJump: _jumpToIndex,
      ),
    );
  }

  Widget _buildFloatingPageOverlay() {
    final color = ref.watch(browserFloatingPageColorProvider);
    final opacity = (ref.watch(browserFloatingPageOpacityProvider) / 100)
        .clamp(0.0, 1.0)
        .toDouble();
    final size = ref
        .watch(browserFloatingPageSizeProvider)
        .clamp(28.0, 88.0)
        .toDouble();
    final upX = ref.watch(browserFloatingPageUpXProvider);
    final upY = ref.watch(browserFloatingPageUpYProvider);
    final downX = ref.watch(browserFloatingPageDownXProvider);
    final downY = ref.watch(browserFloatingPageDownYProvider);

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (ctx, c) {
          Widget btn({
            required double x,
            required double y,
            required bool up,
          }) {
            final left =
                (c.maxWidth - size) * (x.clamp(0.0, 100.0).toDouble() / 100);
            final top =
                (c.maxHeight - size) * (y.clamp(0.0, 100.0).toDouble() / 100);
            return Positioned(
              left: left,
              top: top,
              width: size,
              height: size,
              child: _BrowserFloatingPageButton(
                size: size,
                color: color.withValues(alpha: opacity),
                up: up,
                onTap: up ? _pageUp : _pageDown,
              ),
            );
          }

          return Stack(
            children: [
              btn(x: upX, y: upY, up: true),
              btn(x: downX, y: downY, up: false),
            ],
          );
        },
      ),
    );
  }

  /// 跳到指定条目（顶部对齐）。
  void _jumpToIndex(int index) {
    if (!_itemScrollController.isAttached) return;
    final count = _scrollItemCount;
    if (count <= 0) return;
    try {
      _itemScrollController.jumpTo(
        index: index.clamp(0, count - 1).toInt(),
        alignment: 0,
      );
    } catch (_) {}
  }

  /// 当前可见区间的首/末条目索引与可见条目数。
  _VisibleRange _visibleRange() {
    var first = -1;
    var last = -1;
    var visible = 0;
    for (final p in _positionsListener.itemPositions.value) {
      if (p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1) {
        visible++;
        if (first < 0 || p.index < first) first = p.index;
        if (p.index > last) last = p.index;
      }
    }
    return _VisibleRange(first: first, last: last, visible: visible);
  }

  /// 向下翻一页：上一页最后一个文件仍显示在最上面。
  void _pageDown() {
    final r = _visibleRange();
    if (r.last < 0) return;
    _jumpToIndex(r.last);
  }

  /// 向上翻一页。
  void _pageUp() {
    final r = _visibleRange();
    if (r.first <= 0) return;
    final step = r.visible > 1 ? r.visible - 1 : 1;
    _jumpToIndex(r.first - step);
  }

  Widget _keyed(String k, Widget child) =>
      KeyedSubtree(key: ValueKey(k), child: child);

  Widget _buildBodyState() {
    // 先清零，下面各列表构建时再写入真实条目数。
    _scrollItemCount = 0;

    if (_searchActive) {
      return _keyed('search', _buildSearchResultsList());
    }

    if (_showSkeleton) {
      return const _LoadingSkeleton(key: ValueKey('skeleton'));
    }

    if (_loading) {
      // 180ms 延迟窗口内：什么都不显示，避免闪烁
      return const SizedBox.shrink(key: ValueKey('blank'));
    }

    if (_error != null) {
      return _keyed(
        'error',
        Center(
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
        ),
      );
    }

  final entries = _entries ?? const <EntryInfo>[];
    if (entries.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return _keyed(
        'empty',
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_open_outlined,
                size: 64,
                color: cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                '这里还没有文件',
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

  final mode = ref.read(searchBoxModeProvider);
  if (mode == SearchBoxMode.filter &&
      _searchCtrl.text.trim().isNotEmpty) {
    final items = _visibleItems ?? const <_DisplayItem>[];
    if (items.isEmpty) {
      return _keyed('nomatch', const Center(child: Text('无匹配')));
    }
  }

  return _keyed(
    'content',
    ref.watch(browserGridModeProvider)
        ? _buildGridBody(_filterEntries(entries))
        : _buildListBody(),
  );
}
  // ==================== 列表模式（无粘性头部） ====================

Widget _buildListBody() {
  final fontName = ref.watch(browserFontListNameProvider);
  final fontMeta = ref.watch(browserFontListMetaProvider);
  final colorScheme = Theme.of(context).colorScheme;

  final items = _visibleItems ?? const <_DisplayItem>[];
  // 选中模式下底栏是 Stack 覆盖层，不占布局；
  // 在列表末尾补一段滚动留白，让最后一个文件能滚出底栏遮挡。
  // 留白在滚动内容末尾，不改变可视区高度，进入/退出选中模式内容不跳。
  final extra = _selectionMode ? 1 : 0;
  _scrollItemCount = items.length + extra;
    return Scrollbar(child: ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: items.length + extra,
      itemBuilder: (ctx, i) {
        if (i >= items.length) {
          return SizedBox(
            height: MediaQuery.of(context).padding.bottom + 110,
          );
        }
        final item = items[i];
        return RepaintBoundary(
          key: ValueKey('rb_${item.key}'),
          child: _buildDisplayItemTile(item, fontName, fontMeta, colorScheme),
        );
      },
    ));
  }

  /// 渲染一个 display item。磁盘项、zip 头、zip 内项各有不同样式。
  ///
  /// ★ 改动点：整行用 Listener 记录点击的 x 坐标。
  ///   左侧图标区（宽度 48 + depth*18）点 = 选中/取消；
  ///   其它区点 = 打开（或选择模式下切换选中）。
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
            Icon(Icons.warning_amber,
                size: 16, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.displayName,
                style: TextStyle(fontSize: 12, color: colorScheme.error),
              ),
            ),
          ],
        ),
      );
    }

    final selected = _selectedPaths.contains(item.key);
    final compact = ref.watch(browserListCompactProvider);

    // 左侧图标区宽度（含缩进）。点这块 = 选中/取消。
    final iconZoneRight = (compact ? 36.0 : 48.0) + item.depth * 18.0;

    // zip 头（顶层或嵌套）：和普通文件一样的 ListTile，
    // 只用图标区分展开/折叠（折叠=空心蓝，展开=实心蓝）。
if (item.isZip) {
  final isExpanded = _expandedZipKeys.contains(item.key);
  final isTopLevel = item.ownerZipKey == null;
  final zipIcon = (isTopLevel && isExpanded)
    ? Icons.folder_zip_outlined
    : Icons.folder_zip;
  final metaLine = _buildItemMetaLine(item);

return Listener(
  onPointerDown: (e) => _lastTapX = e.localPosition.dx,
  child: Container(
    margin: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 0 : 2),
    decoration: BoxDecoration(
      color: selected
          ? colorScheme.primary.withValues(alpha: 0.14)
          : null,
      borderRadius: BorderRadius.circular(10),
    ),
  child: ListTile(
      dense: true,
  visualDensity: const VisualDensity(horizontal: 0, vertical: 0),
      contentPadding: EdgeInsets.only(
  left: item.depth * 18.0,
  right: 8,
  top: compact ? 1 : 4,
  bottom: compact ? 1 : 4,
),
leading: SizedBox(
  width: compact ? 36 : 48,
  child: Padding(
    padding: EdgeInsets.only(left: compact ? 4 : 8),
    child: Center(
      child: Icon(
        zipIcon,
        size: compact ? 20 : 24,
        color: colorScheme.onSurfaceVariant,
      ),
    ),
  ),
),
      title: Text(
        item.displayName,
        maxLines: compact ? 1 : 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontName,
          fontWeight: FontWeight.w500,
          height: compact ? 1.15 : 1.3,
        ),
      ),
      subtitle: metaLine.isEmpty
          ? null
          : Text(
              metaLine,
              style: TextStyle(
                fontSize: fontMeta,
                color: colorScheme.onSurfaceVariant,
                height: 1.3,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      onTap: () {
        // ★ 左侧图标区点 = 选中/取消
        if (_lastTapX < iconZoneRight) {
          _toggleSelectionByKey(item.key);
          return;
        }
        if (_selectionMode) {
          _toggleSelectionByKey(item.key);
          return;
        }
        _handleTapItem(item);
      },
      onLongPress: () => _onLongPressItem(item),
    ),
  ),
);
}

    // zip 内目录
    if (item.isZipInner && item.isDir) {
      return Padding(
        padding: EdgeInsets.only(
          left: 8.0 + item.depth * 18.0,
          right: 12,
          top: compact ? 4 : 7,
          bottom: compact ? 4 : 7,
        ),
        child: Row(
          children: [
            const SizedBox(width: 22),
            Icon(Icons.folder,
                size: 18, color: _fileIconColor(context, isDir: true)),
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

return Listener(
  onPointerDown: (e) => _lastTapX = e.localPosition.dx,
  child: Container(
    margin: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 0 : 2),
    decoration: BoxDecoration(
      color: selected
          ? colorScheme.primary.withValues(alpha: 0.14)
          : null,
      borderRadius: BorderRadius.circular(10),
    ),
  child: ListTile(
  dense: true,
  visualDensity: const VisualDensity(horizontal: 0, vertical: 0),

  contentPadding: EdgeInsets.only(
        left: item.depth * 18.0,
        right: 8,
        top: compact ? 1 : 4,
        bottom: compact ? 1 : 4,
      ),
      leading: SizedBox(
        width: compact ? 36 : 48,
        child: Padding(
          padding: EdgeInsets.only(left: compact ? 4 : 8),
          child: Center(
            child: Icon(
              isZipInner
                  ? Icons.insert_drive_file_outlined
                  : (item.isDir
                      ? Icons.folder
                      : Icons.insert_drive_file_outlined),
              size: compact ? 20 : 24,
              color: isZipInner
                  ? colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
                  : _fileIconColor(context, isDir: item.isDir),
            ),
          ),
        ),
      ),
        title: Text(
          item.displayName,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: fontName,
            fontWeight: item.isDir
                ? FontWeight.bold
                : FontWeight.w500,
            height: compact ? 1.15 : 1.3,
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
                  height: 1.3,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        onTap: () {
          // ★ 左侧图标区点 = 选中/取消
          if (_lastTapX < iconZoneRight) {
            _toggleSelectionByKey(item.key);
            return;
          }
          if (_selectionMode) {
            _toggleSelectionByKey(item.key);
            return;
          }
          _handleTapItem(item);
        },
        onLongPress: () => _onLongPressItem(item),
      ),
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
    // 选中模式下底栏是覆盖层，网格末尾同样补一段滚动留白。
    final extraRow = _selectionMode ? 1 : 0;
    _scrollItemCount = rowCount + extraRow;

    return Scrollbar(child: ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: rowCount + extraRow,
      itemBuilder: (ctx, rowIdx) {
        if (rowIdx >= rowCount) {
          return SizedBox(
            height: MediaQuery.of(context).padding.bottom + 110,
          );
        }
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
                  color: _gridDividerColorOf(context),
                ),
                Expanded(child: rightWidget),
              ],
            ),
          ),
        );
      },
    ));
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

    final displayItem = _displayItemForEntry(info);

    return GestureDetector(
      onTap: () {
        if (_selectionMode) {
          _toggleSelectionByKey(e.path);
          return;
        }
        if (info.isDir) {
          _navigateTo(e.path);
        } else {
          _openFile(e.path, info.name, info.size, allowExpand: false);
        }
      },
      onLongPress: () => _onLongPressItem(displayItem),
      child: Container(
        decoration: BoxDecoration(
          // 背景只保留选中态，和列表模式一致；
          // 文本/二进制靠图标颜色区分，灰底属于隐式规则。
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.14)
              : null,
        ),
        foregroundDecoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: _gridDividerColorOf(context),
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _toggleSelectionByKey(e.path),
                  onLongPress: () => _onLongPressItem(displayItem),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: Center(
                        child: Icon(
                          info.isDir
                              ? Icons.folder
                              : Icons.insert_drive_file_outlined,
                          size: 15,
                          color: _fileIconColor(context,
                              isDir: info.isDir),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(child: _buildGridName(info, fontName)),
              ],
            ),
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

  /// 网格长按需要的 item 解析逻辑，图标/整格手势共用一份。
  _DisplayItem _displayItemForEntry(EntryInfo info) {
    final all = _cachedDisplayItems ?? const <_DisplayItem>[];
    return all.firstWhere(
      (x) => x.key == info.entity.path,
      orElse: () => _DisplayItem(
        key: info.entity.path,
        displayName: info.name,
        depth: 0,
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
          height: 1.3,
        ),
      );
    }
    // 粗细与列表模式对齐：文件夹 bold、文件 w500。
    // 不再按大小拆扩展名，避免"有的名字粗有的不粗"的随机感。
    return Text(
      info.name,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w500,
        height: 1.3,
      ),
    );
  }

  // ==================== 搜索结果列表（无粘性头部） ====================

  Widget _buildSearchResultsList() {
    if (_searchResults.isEmpty) {
  return Center(
    child: Text(
      _searchCtrl.text.trim().isEmpty
          ? '请输入关键词后搜索'
          : (_searching ? '正在扫描...' : '未找到匹配'),
    ),
  );
}
    final colorScheme = Theme.of(context).colorScheme;
    final fontName = ref.watch(browserFontListNameProvider);
    final fontMeta = ref.watch(browserFontListMetaProvider);

    final items = _cachedDisplayItems ?? const <_DisplayItem>[];
    // 选中模式下底栏是覆盖层，搜索结果列表末尾同样补滚动留白。
    final extra = _selectionMode ? 1 : 0;
    _scrollItemCount = items.length + extra;

    return Scrollbar(child: ScrollablePositionedList.builder(
      itemScrollController: _itemScrollController,
      itemPositionsListener: _positionsListener,
      itemCount: items.length + extra,
      itemBuilder: (ctx, i) {
        if (i >= items.length) {
          return SizedBox(
            height: MediaQuery.of(context).padding.bottom + 110,
          );
        }
        final item = items[i];
        return RepaintBoundary(
          key: ValueKey('rb_search_${item.key}'),
          child: _buildSearchResultTile(item, fontName, fontMeta, colorScheme),
        );
      },
    ));
  }

  /// 搜索结果模式的列表项渲染（跟普通列表不同：显示路径副标题）。
  ///
  /// ★ 改动点：整行用 Listener 记录点击的 x 坐标。
  ///   左侧图标区（宽度 48 + depth*18）点 = 选中/取消；
  ///   其它区点 = 打开（或选择模式下切换选中）。
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

    if (item.isZipInner && item.isDir) {
      return _buildDisplayItemTile(item, fontName, fontMeta, colorScheme);
    }

    final selected = _selectedPaths.contains(item.key);
    final isZipInner = item.isZipInner;
    final metaLine = _buildItemMetaLine(item);
    final pathLine = isZipInner
        ? item.fullDisplayPath
        : (item.diskPath ?? '');

    final compact = ref.watch(browserListCompactProvider);

    // 左侧图标区宽度（含缩进）。点这块 = 选中/取消。
    final iconZoneRight = (compact ? 36.0 : 48.0) + item.depth * 18.0;

    return Listener(
      onPointerDown: (e) => _lastTapX = e.localPosition.dx,
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 6, vertical: compact ? 0 : 2),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.14)
              : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: ListTile(
          dense: true,
          isThreeLine: true,
          visualDensity: const VisualDensity(horizontal: 0, vertical: 0),
          contentPadding: EdgeInsets.only(
            left: item.depth * 18.0,
            right: 8,
            top: compact ? 1 : 4,
            bottom: compact ? 1 : 4,
          ),
          leading: SizedBox(
            width: compact ? 36 : 48,
            child: Padding(
              padding: EdgeInsets.only(left: compact ? 4 : 8, top: compact ? 2 : 4),
              child: Align(
                alignment: Alignment.topCenter,
                child: Icon(
                  item.isZip
                      ? Icons.folder_zip
                      : (item.isDir
                          ? Icons.folder
                          : Icons.insert_drive_file_outlined),
                  size: compact ? 20 : 24,
                  color: isZipInner
                      ? colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
                      : _fileIconColor(context, isDir: item.isDir),
                ),
              ),
            ),
          ),
          title: Text(
            item.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontName,
              fontWeight: item.isDir
                  ? FontWeight.bold
                  : FontWeight.w500,
              height: 1.3,
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
                    height: 1.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              Text(
                pathLine,
                style: TextStyle(
                  fontSize: fontMeta,
                  color: colorScheme.onSurfaceVariant,
                  height: 1.3,
                ),
                softWrap: true,
              ),
            ],
          ),
          onTap: () {
            // ★ 左侧图标区点 = 选中/取消
            if (_lastTapX < iconZoneRight) {
              _toggleSelectionByKey(item.key);
              return;
            }
            if (_selectionMode) {
              _toggleSelectionByKey(item.key);
              return;
            }
            _handleTapItem(item);
          },
          onLongPress: () => _onLongPressItem(item),
        ),
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
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 32,
        vertical: 24,
      ),
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: cs.primary, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
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

  // 7.4：区间高亮色改读主题 token（原为 static const 硬编码）
  Color get _rangeBlue => Theme.of(context).colorScheme.primary;
  Color get _rangeHighlight =>
      Theme.of(context).colorScheme.primary.withValues(alpha: 0.2);

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
  var target = _normalizePath(path.trim());
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
                      cursorColor: Theme.of(context).colorScheme.primary,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '粘贴路径跳转',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      onSubmitted: (v) => _jumpToPath(v.trim()),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    color: Theme.of(context).colorScheme.primary,
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
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant
                                                    .withValues(alpha: 0.3)
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
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: Icon(Icons.folder,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary),
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
                    backgroundColor:
                        Theme.of(context).colorScheme.surface,
                    selectedColor: Theme.of(context).colorScheme.surface,
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    checkmarkColor: Theme.of(context).colorScheme.primary,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: _allVisibleSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
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
                    backgroundColor:
                        Theme.of(context).colorScheme.surface,
                    selectedColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    checkmarkColor: _rangeBlue,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: _rangeMode
                          ? _rangeBlue
                          : Theme.of(context).colorScheme.outlineVariant,
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
      insetPadding: const EdgeInsets.all(16),
      title: const Text('属性'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: SizedBox(
          width: 360,
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
      return Text(
        '文件夹不支持计算 MD5',
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
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
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
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

// ==================== 删除确认弹窗（异步统计） ====================

typedef _PathStat = ({int files, int bytes, bool truncated, bool done});

class _DeleteConfirmDialog extends StatefulWidget {
  const _DeleteConfirmDialog({required this.paths});
  final List<String> paths;

  @override
  State<_DeleteConfirmDialog> createState() => _DeleteConfirmDialogState();
}

class _DeleteConfirmDialogState extends State<_DeleteConfirmDialog> {
  static const int _limit = 10000;

  final Map<String, _PathStat> _stats = {};
  final Map<String, bool> _isDir = {};
  bool _allDone = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
  for (final p in widget.paths) {
    try {
      if (!Directory(p).existsSync()) {
        _isDir[p] = false;
        final st = File(p).statSync();
        _stats[p] = (files: 1, bytes: st.size, truncated: false, done: true);
      }
    } catch (_) {
      _stats[p] = (files: 0, bytes: 0, truncated: true, done: true);
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
      _stats[p] = (files: 0, bytes: 0, truncated: true, done: true);
    }
    if (mounted) setState(() {});
  }
  if (mounted) setState(() => _allDone = true);
}

  Future<_PathStat> _scanDir(String rootPath) async {
    var fileCount = 0;
    var dirCount = 0;
    var bytes = 0;
    final stack = <String>[rootPath];
    var lastYield = DateTime.now();
    while (stack.isNotEmpty) {
      if (fileCount + dirCount > _limit) {
        return (files: fileCount, bytes: bytes, truncated: true, done: true);
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
    return (files: fileCount, bytes: bytes, truncated: false, done: true);
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

  @override
  Widget build(BuildContext context) {
    final n = widget.paths.length;

    final totalFiles = _stats.values.fold<int>(0, (s, e) => s + e.files);
    final totalBytes = _stats.values.fold<int>(0, (s, e) => s + e.bytes);
    final anyTruncated = _stats.values.any((e) => e.truncated);

    final lines = <Widget>[];
    for (final p in widget.paths) {
      final name = p.split('/').last;
      final stat = _stats[p];
      final isDir = _isDir[p] ?? false;

      String text;
      if (stat == null) {
        text = '· ${isDir ? "$name/" : name} —— 正在统计…';
      } else if (stat.truncated) {
        text = '· $name/ —— 文件超过 $_limit 个，未完全统计';
      } else if (isDir) {
        text = '· $name/ —— ${stat.files} 个文件，${_fmt(stat.bytes)}';
      } else {
        text = '· $name —— ${_fmt(stat.bytes)}';
      }

      lines.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
      ));
    }

    String totalStr;
    if (!_allDone) {
      totalStr = '正在统计…';
    } else if (anyTruncated) {
      totalStr = '总计约 ${_fmt(totalBytes)}（部分未统计）';
    } else {
      totalStr = '共 $totalFiles 个文件，${_fmt(totalBytes)}';
    }

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      title: Text('删除 $n 项？'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ...lines,
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Text(
                totalStr,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '选中的 $n 项将从磁盘删除，无法恢复。',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

// ==================== 加载骨架屏（Shimmer 流光） ====================

class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform(this.slidePercent);
  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(
      bounds.width * (slidePercent * 2 - 1),
      0,
      0,
    );
  }
}

class _LoadingSkeleton extends StatefulWidget {
  const _LoadingSkeleton({super.key, this.rows = 16});
  final int rows;

  @override
  State<_LoadingSkeleton> createState() => _LoadingSkeletonState();
}

class _LoadingSkeletonState extends State<_LoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, _) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final cs = Theme.of(context).colorScheme;
            return LinearGradient(
              colors: [
                cs.surfaceVariant,
                cs.surfaceVariant.withValues(alpha: 0.4),
                cs.surfaceVariant,
              ],
              stops: const [0.35, 0.5, 0.65],
              transform: _SlidingGradientTransform(_ctrl.value),
            ).createShader(bounds);
          },
          child: _buildStatic(),
        );
      },
    );
  }

  Widget _buildStatic() {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.rows,
      itemBuilder: (ctx, i) {
        // 每行宽度略有变化，看起来不像机器排的
        final nameW = 120.0 + (i * 37) % 80;
        final metaW = 70.0 + (i * 23) % 60;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: nameW,
                      height: 11,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: metaW,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ==================== 可拖动滚动条（外包在列表之上） ====================

/// ScrollablePositionedList 不暴露 ScrollController，
/// 所以用 ItemPositionsListener 的可见项信息推算滚动位置，
/// 拖动时换算成目标条目索引再 jumpTo。
class _BrowserScrollbar extends StatefulWidget {
  const _BrowserScrollbar({
    required this.positions,
    required this.itemCount,
    required this.thumbWidth,
    required this.trackColor,
    required this.thumbColor,
    required this.onJump,
  });

  final ValueListenable<Iterable<ItemPosition>> positions;
  final int Function() itemCount;
  final double thumbWidth;
  final Color trackColor;
  final Color thumbColor;
  final void Function(int index) onJump;

  @override
  State<_BrowserScrollbar> createState() => _BrowserScrollbarState();
}

class _BrowserScrollbarState extends State<_BrowserScrollbar> {
  static const double _minThumb = 36;

  /// 拖动中的拇指顶部位置；null 表示跟随列表实际位置。
  double? _dragTop;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final h = c.maxHeight;
        return ValueListenableBuilder<Iterable<ItemPosition>>(
          valueListenable: widget.positions,
          builder: (ctx, positions, _) {
            final m = _metrics(h, positions);
            final top =
                (_dragTop ?? m.top).clamp(0.0, m.maxTop).toDouble();

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                // 点轨道直接跳到对应位置（拖动时不会误触发）。
                final t = (d.localPosition.dy - m.thumbH / 2)
                    .clamp(0.0, m.maxTop)
                    .toDouble();
                _apply(m, t);
              },
              onVerticalDragStart: (d) {
                final inThumb = d.localPosition.dy >= top &&
                    d.localPosition.dy <= top + m.thumbH;
                if (inThumb) {
                  setState(() => _dragTop = top);
                } else {
                  final t = (d.localPosition.dy - m.thumbH / 2)
                      .clamp(0.0, m.maxTop)
                      .toDouble();
                  setState(() => _dragTop = t);
                  _apply(m, t);
                }
              },
              onVerticalDragUpdate: (d) {
                final t = ((_dragTop ?? top) + d.delta.dy)
                    .clamp(0.0, m.maxTop)
                    .toDouble();
                setState(() => _dragTop = t);
                _apply(m, t);
              },
              onVerticalDragEnd: (_) => setState(() => _dragTop = null),
              onVerticalDragCancel: () => setState(() => _dragTop = null),
              child: CustomPaint(
                size: Size(c.maxWidth, h),
                painter: _BrowserScrollbarPainter(
                  top: top,
                  thumbHeight: m.thumbH,
                  thumbWidth: widget.thumbWidth,
                  trackColor: widget.trackColor,
                  thumbColor: widget.thumbColor,
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _apply(_ScrollMetrics m, double top) {
    if (m.maxTop <= 0) return;
    final f = top / m.maxTop;
    widget.onJump((f * m.maxScroll).round());
  }

  _ScrollMetrics _metrics(
    double h,
    Iterable<ItemPosition> positions,
  ) {
    final count = widget.itemCount();
    var visible = 0;
    var first = 0;
    var leading = 0.0;
    var found = false;

    for (final p in positions) {
      if (p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1) {
        visible++;
        if (!found || p.index < first) {
          found = true;
          first = p.index;
          leading = p.itemLeadingEdge;
        }
      }
    }

    if (!found || count <= 0) {
      return _ScrollMetrics(thumbH: h, top: 0, maxTop: 0, maxScroll: 1);
    }

    final thumbH = math.min(h, math.max(_minThumb, h * visible / count));
    final maxTop = math.max(0.0, h - thumbH);
    final maxScroll = math.max(1, count - visible);
    final raw = first + leading.clamp(-1.0, 0.0).toDouble();
    final top =
        (raw / maxScroll).clamp(0.0, 1.0).toDouble() * maxTop;
    return _ScrollMetrics(
      thumbH: thumbH,
      top: top,
      maxTop: maxTop,
      maxScroll: maxScroll,
    );
  }
}

class _ScrollMetrics {
  const _ScrollMetrics({
    required this.thumbH,
    required this.top,
    required this.maxTop,
    required this.maxScroll,
  });

  final double thumbH;
  final double top;
  final double maxTop;
  final int maxScroll;
}

class _BrowserScrollbarPainter extends CustomPainter {
  const _BrowserScrollbarPainter({
    required this.top,
    required this.thumbHeight,
    required this.thumbWidth,
    required this.trackColor,
    required this.thumbColor,
  });

  final double top;
  final double thumbHeight;
  final double thumbWidth;
  final Color trackColor;
  final Color thumbColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0 || size.width <= 0) return;
    final w = thumbWidth.clamp(2.0, size.width).toDouble();
    final left = size.width - w;

    // 轨道
    final trackRect = Rect.fromLTWH(left, 0, w, size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, Radius.circular(w / 2)),
      Paint()..color = trackColor,
    );

    // 拖动块
    final thumbRect = Rect.fromLTWH(left, top, w, thumbHeight);
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumbRect, Radius.circular(w / 2)),
      Paint()..color = thumbColor,
    );
  }

  @override
  bool shouldRepaint(covariant _BrowserScrollbarPainter old) =>
      old.top != top ||
      old.thumbHeight != thumbHeight ||
      old.thumbWidth != thumbWidth ||
      old.trackColor != trackColor ||
      old.thumbColor != thumbColor;
}

// ==================== 悬浮翻页按钮 ====================

class _BrowserFloatingPageButton extends StatelessWidget {
  const _BrowserFloatingPageButton({
    required this.size,
    required this.color,
    required this.up,
    required this.onTap,
  });

  final double size;
  final Color color;
  final bool up;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg =
        color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
    return Material(
      color: color,
      shape: const CircleBorder(),
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Icon(
          up ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
          size: size * 0.62,
          color: fg,
        ),
      ),
    );
  }
}

class _VisibleRange {
  const _VisibleRange({
    required this.first,
    required this.last,
    required this.visible,
  });

  final int first;
  final int last;
  final int visible;
}
