import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:charset/charset.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../viewer/presentation/viewer_widgets.dart' show pickColorDialog;

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
    required this.isFilterMode,
    required this.hasMainText,
    required this.submitBg,
    required this.submitFg,
    required this.accentColor,
    required this.tapGroup,
    required this.onChanged,
    required this.onSubmit,
    required this.onClearAll,
    required this.onClose,
  });

  final double panelTop;
  final double panelLeft;
  final double panelWidth;
  final List<_SearchCondition> conditions;
  final bool isFilterMode;
  final bool Function() hasMainText;
  final Color submitBg;
  final Color submitFg;
  final Color accentColor;
  final Object tapGroup;
  final VoidCallback onChanged;
  final VoidCallback onSubmit;
  final VoidCallback onClearAll;
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
    return TapRegion(
      groupId: widget.tapGroup,
      onTapOutside: (_) {
        if (_openMenuIndex != null) {
          setState(() => _openMenuIndex = null);
        } else {
          widget.onClose();
        }
      },
      child: Stack(
        children: [
          Positioned(
            left: widget.panelLeft,
            top: widget.panelTop,
            width: widget.panelWidth,
            child: _buildPanel(),
          ),
          if (_openMenuIndex != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => setState(() => _openMenuIndex = null),
              ),
            ),
          if (_openMenuIndex != null) _buildMenu(),
        ],
      ),
    );
  }

  Widget _buildPanel() {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: Colors.white,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
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
            _addClearRow(),
            _submitButton(),
          ],
        ),
      ),
    );
  }

  Widget _row(int i) {
    final cond = widget.conditions[i];
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 6, top: 3, bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 36, child: _operatorBtn(i, cond)),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: cond.controller,
              onChanged: (_) => widget.onChanged(),
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(fontSize: 14),
              cursorColor: widget.accentColor,
              decoration: InputDecoration(
                isDense: true,
                hintText: '输入文字',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: widget.accentColor, width: 2),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 40,
            height: 36,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 40, minHeight: 40),
              icon: const Icon(Icons.close, size: 22, color: Colors.black54),
              tooltip: '删除此条件',
              onPressed: () => _remove(i),
            ),
          ),
        ],
      ),
    );
  }

  Widget _operatorBtn(int i, _SearchCondition cond) {
    return SizedBox(
      key: _keyFor(i),
      width: 80,
      height: 36,
      child: Material(
        color: const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _toggleMenu(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _label(cond.operator),
                  style: const TextStyle(fontSize: 13, color: Colors.black),
                ),
                const Icon(Icons.arrow_drop_down,
                    size: 18, color: Colors.black),
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
        elevation: 8,
        borderRadius: BorderRadius.circular(6),
        color: Colors.white,
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

  Widget _menuItem(int i, _SearchOperator op, String label, String hint) {
    final selected = widget.conditions[i].operator == op;
    return InkWell(
      onTap: () => _selectOperator(i, op),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: selected
                  ? const Icon(Icons.check, size: 16, color: Colors.black)
                  : null,
            ),
            Text(label,
                style: const TextStyle(fontSize: 14, color: Colors.black)),
            const SizedBox(width: 12),
            Text(hint,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
      ),
    );
  }

  Widget _addClearRow() {
    final hasAny = widget.conditions.isNotEmpty;
    final borderColor = hasAny ? Colors.black : Colors.black38;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 6, 0),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 42,
              child: OutlinedButton(
                onPressed: _add,
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: Colors.black, width: 1.2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: const Text(
                  '＋ 添加条件',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.black,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 42,
              child: OutlinedButton(
                onPressed: hasAny ? widget.onClearAll : null,
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  side: BorderSide(color: borderColor, width: 1.2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: Text(
                  '🗑 清空条件',
                  style: TextStyle(
                    fontSize: 14,
                    color: hasAny ? Colors.black : Colors.black38,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _submitButton() {
    final enabled = widget.conditions.any((c) => c.text.trim().isNotEmpty)
        || widget.hasMainText();
    final label = widget.isFilterMode ? '筛选' : '搜索';

    final bg =
        enabled ? widget.submitBg : widget.submitBg.withValues(alpha: 0.4);
    final fg =
        enabled ? widget.submitFg : widget.submitFg.withValues(alpha: 0.4);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 6, 10),
      child: SizedBox(
        width: double.infinity,
        height: 46,
        child: OutlinedButton(
          onPressed: enabled ? widget.onSubmit : null,
          style: OutlinedButton.styleFrom(
            backgroundColor: bg,
            side: BorderSide.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(23),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: fg,
            ),
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
  static const Color _gridDividerColor = Color(0xFFE0E0E0);
  static const Color _gridSelectedBg = Color(0xFFFFF3FB);

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

  // ★ 新增：最近一次整行点击的 x 坐标（相对行左边）。
  // 用来判断点的是不是左侧图标区（图标区点=选中，其它=打开）。
  double _lastTapX = double.infinity;
// ==================== 高级搜索条件状态 ====================
bool _advancedOpen = false;
final List<_SearchCondition> _searchConditions = [];
final GlobalKey _searchInputKey = GlobalKey();
OverlayEntry? _advancedOverlay;


  // ==================== zip 展开状态 ====================

  final Set<String> _expandedZipKeys = <String>{};
  final Map<String, Archive> _zipArchives = <String, Archive>{};
  final Set<String> _loadingZipKeys = <String>{};
  final Map<String, String> _zipErrors = <String, String>{};

  /// ★ 粘性头部已停用，此字段保留但始终为 null。
String? _stickyZipKey;

  // ==================== 标记（临时标记，进程结束清空） ====================

  /// 已标记：路径 → 最终颜色（已含透明度）。
  final Map<String, Color> _markColors = <String, Color>{};

  /// 是否在标记模式。
  _MarkerMode _markerMode = _MarkerMode.off;

  /// 用户在设置里选的默认激活模式（模式1 或 模式2）。
  /// 画笔图标点一下时，从 off 激活到这个模式。
  _MarkerMode _selectedMarkerMode = _MarkerMode.exitAfterMark;

  /// 跳转中的目标路径。加载完目录后消费一次。
  String? _pendingJumpPath;

  /// 正在闪烁高亮的目标路径。null = 没有。
  String? _flashingPath;

  /// 每次跳转递增，用来强制 TweenAnimationBuilder 重新开始动画。
  int _flashSeq = 0;

  /// 当前显示的顶部提示。null = 没有。
  OverlayEntry? _toastEntry;
static final Object _searchPanelTapGroup = Object();

// ==================== 过滤状态 ====================

List<_SearchHit> _filterDeepResults = const [];
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
  _load();
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
  _positionsListener.itemPositions.removeListener(_onPositionsChanged);
  _toastEntry?.remove();
  _toastEntry = null;
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
          _error = null;
        });
        if (anchor.isNotEmpty) {
          _restoreScrollAnchor(anchor);
        } else {
          _restoreDirScroll();
        }
        _tryConsumePendingJump();
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
      _tryConsumePendingJump();
      return;
    }

   if (!silent) {
  setState(() {
    _loading = true;
    _error = null;
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
          _tryConsumePendingJump();
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

  void _navigateTo(String path, {bool preservePendingJump = false}) {
    if (!preservePendingJump) _pendingJumpPath = null;
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
_filterDeepResults = const [];
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

bool get _hasActiveConditions =>
    _searchConditions.any((c) => c.text.trim().isNotEmpty);

/// 只要以下任意一条成立，搜索框必须显示，且顶栏按钮不出现。
bool get _forceShowSearchBar =>
    _searchActive ||
    _searchCtrl.text.trim().isNotEmpty ||
    _hasActiveConditions ||
    _advancedOpen;




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

void _closeAdvanced({bool runRealtimeIfNeeded = true}) {
  _advancedOverlay?.remove();
  _advancedOverlay = null;
  final wasOpen = _advancedOpen;
  if (mounted && _advancedOpen) {
    setState(() => _advancedOpen = false);
  }
  if (wasOpen && runRealtimeIfNeeded) {
    final isFilter =
        ref.read(searchBoxModeProvider) == SearchBoxMode.filter;
    if (isFilter &&
        !_hasActiveConditions &&
        _searchCtrl.text.trim().isNotEmpty) {
      _onFilterTextChanged(_searchCtrl.text);
    }
  }
}

void _showAdvancedOverlay() {
  _advancedOverlay?.remove();
  _advancedOverlay = null;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final box =
        _searchInputKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screenWidth = MediaQuery.of(context).size.width;

    final submitColors = _submitButtonColors();
    final mode = ref.read(searchBoxModeProvider);
    final scope = ref.read(searchScopeProvider);
    final accent = mode == SearchBoxMode.filter
        ? const Color(0xFFE53935)
        : (scope == SearchScope.custom
            ? const Color(0xFF009EDD)
            : const Color(0xFFB79800));

    _advancedOverlay = OverlayEntry(
      builder: (ctx) => _AdvancedOverlayContent(
        panelTop: pos.dy + size.height + 2,
        panelLeft: 8,
        panelWidth: screenWidth - 16,
        conditions: _searchConditions,
        isFilterMode:
            ref.read(searchBoxModeProvider) == SearchBoxMode.filter,
        hasMainText: () => _searchCtrl.text.trim().isNotEmpty,
        submitBg: submitColors.bg,
        submitFg: submitColors.fg,
        accentColor: accent,
        tapGroup: _searchPanelTapGroup,
        onChanged: () {
          if (!mounted) return;
          setState(() {});
          _advancedOverlay?.markNeedsBuild();
        },
        onSubmit: () {
          final isFilter =
              ref.read(searchBoxModeProvider) == SearchBoxMode.filter;
          _closeAdvanced(runRealtimeIfNeeded: false);
          if (isFilter) {
            _runFilterNow();
          } else {
            _doSearch();
          }
        },
        onClearAll: _clearConditionsInPanel,
        onClose: _closeAdvanced,
      ),
    );
    Overlay.of(context).insert(_advancedOverlay!);
  });
}

// ==================== 高级搜索条件 · UI ====================






({Color bg, Color fg}) _submitButtonColors() {
  final mode = ref.read(searchBoxModeProvider);
  if (mode == SearchBoxMode.filter) {
    return (bg: const Color(0xFFFFCDD2), fg: Colors.black);
  }
  final scope = ref.read(searchScopeProvider);
  if (scope == SearchScope.custom) {
    return (bg: const Color(0xFFE4FAFF), fg: const Color(0xFF009EDD));
  }
  return (bg: const Color(0xFFFFF7D2), fg: const Color(0xFFB79800));
}

Color _advancedToggleColor() {
  final mode = ref.read(searchBoxModeProvider);
  if (mode == SearchBoxMode.filter) return Colors.black;
  final scope = ref.read(searchScopeProvider);
  return scope == SearchScope.custom
      ? const Color(0xFF009EDD)
      : const Color(0xFFB79800);
}

Widget _buildAdvancedToggle() {
  final hasConds = _hasActiveConditions;
  final open = _advancedOpen;
  final color = _advancedToggleColor();

  return SizedBox(
    width: 40,
    height: 44,
    child: InkWell(
      customBorder: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      onTap: _toggleAdvanced,
      child: Center(
        child: _TriangleIcon(
          filled: hasConds,
          direction: open ? 'down' : 'left',
          size: 20,
          color: color,
        ),
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
void _jumpToTop() {
  if (!_itemScrollController.isAttached) return;
  _itemScrollController.jumpTo(index: 0);
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
  final mode = ref.read(searchBoxModeProvider);
  if (mode == SearchBoxMode.filter) {
    if (_advancedOpen || _hasActiveConditions) {
      setState(() {});
      if (_advancedOpen) _advancedOverlay?.markNeedsBuild();
    } else {
      _onFilterTextChanged(v);
    }
  } else {
    setState(() {});
  }
}
// ==================== 过滤 ====================

void _onFilterTextChanged(String q) {
  _filterTaskId++;
  final taskId = _filterTaskId;
  _filterDeepResults = const [];
  setState(() {});

  if (q.trim().isEmpty && !_hasActiveConditions) return;

  final depth = ref.read(filterDepthProvider);
  if (depth <= 0) return;

  Future<void>.delayed(const Duration(milliseconds: 200), () async {
    if (!mounted || taskId != _filterTaskId) return;
    await _scanFilterDepth(_currentPath, taskId, depth);
  });
}

Future<void> _scanFilterDepth(
  String rootPath,
  int taskId,
  int depth,
) async {
  final out = <_SearchHit>[];

  // 层序（广度优先）扫描：
  //   level=1 → 当前目录的直接子项（由 _computeVisibleItems 的 matchedTop 处理，这里跳过）
  //   level=2 → 第 1 层子目录里的内容
  //   level=3 → 第 2 层子目录里的内容
  //   ...
  //   level=N+1 → 第 N 层子目录里的内容
  // 所以 depth=5 时，能扫到第 5 层子目录里的直接子项。
  var currentDirs = <String>[rootPath];
  var level = 0;

  while (currentDirs.isNotEmpty && level <= depth) {
    level++;
    final nextDirs = <String>[];
    for (final dirPath in currentDirs) {
      if (taskId != _filterTaskId) return;
      if (out.length >= 500) break;
      try {
        await for (final e in Directory(dirPath).list(followLinks: false)) {
          if (taskId != _filterTaskId) return;
          if (out.length >= 500) break;

          final name = e.path.split('/').last;
          if (name.startsWith('.')) continue;

          final lowerPath = e.path.toLowerCase();
          if (lowerPath.contains('/android/data') ||
              lowerPath.contains('/android/obb')) {
            continue;
          }

          // level=1 是当前目录的直接子项，已经由 matchedTop 处理过；
          // 这里只负责 level>=2 的深层项。
          if (level >= 2 && _matchNameForSearch(name)) {
            final isDir = e is Directory;
            int? size;
            DateTime? modified;
            try {
              final st = await e.stat();
              if (!isDir) size = st.size;
              modified = st.modified;
            } catch (_) {}
            out.add(_SearchHit(
              path: e.path,
              name: name,
              isDir: isDir,
              size: size,
              modified: modified,
            ));

            // 渐进显示：每 100ms 刷一次，边扫边出现
            final now = DateTime.now();
            if (mounted &&
                now.difference(_lastUiRefresh).inMilliseconds > 100) {
              _lastUiRefresh = now;
              setState(() => _filterDeepResults = List.from(out));
            }
          }

          if (e is Directory) nextDirs.add(e.path);
        }
      } catch (_) {}
    }
    currentDirs = nextDirs;
    if (out.length >= 500) break;
  }

  if (!mounted || taskId != _filterTaskId) return;
  setState(() => _filterDeepResults = List.from(out));
}

List<_DisplayItem> _computeVisibleItems(List<_DisplayItem> all) {
  if (_searchActive) return all;
  if (ref.read(searchBoxModeProvider) != SearchBoxMode.filter) return all;

  final hasQuery = _searchCtrl.text.trim().isNotEmpty;
  if (!hasQuery && !_hasActiveConditions) return all;

  final out = <_DisplayItem>[];

  final matchedTop = <String>{};
  for (final it in all) {
    if (it.depth != 0) continue;
    if (_matchNameForSearch(it.displayName)) {
      matchedTop.add(it.key);
    }
  }
  for (final it in all) {
    if (it.depth == 0) {
      if (matchedTop.contains(it.key)) out.add(it);
    } else if (it.ownerZipKey != null &&
        matchedTop.contains(it.ownerZipKey)) {
      out.add(it);
    }
  }

  for (final hit in _filterDeepResults) {
  out.add(_DisplayItem(
    key: hit.path,
    displayName: hit.name,
    depth: 0,
    isDir: hit.isDir,
    size: hit.size,
    modified: hit.modified,
    searchHit: hit,
  ));
}

  return out;
}

List<EntryInfo> _filterEntries(List<EntryInfo> entries) {
  if (ref.read(searchBoxModeProvider) != SearchBoxMode.filter) {
    return entries;
  }
  if (_searchCtrl.text.trim().isEmpty && !_hasActiveConditions) {
    return entries;
  }
  final matched = entries
      .where((e) => _matchNameForSearch(e.name))
      .toList();

  // 网格模式下也把深层过滤结果并进来（原来只有列表模式会合并）
  final deep = <EntryInfo>[];
  for (final hit in _filterDeepResults) {
    final isDir = hit.isDir;
    final entity = isDir ? Directory(hit.path) : File(hit.path);
    deep.add(EntryInfo(
      entity: entity,
      name: hit.name,
      isDir: isDir,
      size: hit.size,
      modified: hit.modified,
    ));
  }
  return [...matched, ...deep];
}

void _runFilterNow() {
  FocusManager.instance.primaryFocus?.unfocus();
  _onFilterTextChanged(_searchCtrl.text);
}

void _clearConditionsInPanel() {
  final oldConds = List<_SearchCondition>.from(_searchConditions);
  setState(() {
    _searchConditions.clear();
    _filterTaskId++;
    _filterDeepResults = const [];
  });
  _advancedOverlay?.markNeedsBuild();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    for (final c in oldConds) {
      c.dispose();
    }
  });
}

void _clearConditionsAndRealtime() {
  _clearConditionsInPanel();
  _closeAdvanced(runRealtimeIfNeeded: false);
  final isFilter =
      ref.read(searchBoxModeProvider) == SearchBoxMode.filter;
  if (isFilter && _searchCtrl.text.trim().isNotEmpty) {
    _onFilterTextChanged(_searchCtrl.text);
  }
}

void _clearFilter() {
  _searchTaskId++;
  _filterTaskId++;
  _searchCtrl.clear();
  _filterDeepResults = const [];
  _selectionMode = false;
  _selectedPaths.clear();
  _anchorPath = null;
  _advancedOverlay?.markNeedsBuild();
  setState(() {});
}
  void _doSearch() {
  final q = _searchCtrl.text.trim();
  if (q.isEmpty && !_hasActiveConditions) return;
  if (q.isNotEmpty) {
    ref.read(browserSearchHistoryProvider.notifier).add(q);
  }
  setState(() => _searchActive = true);
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
  _advancedOverlay?.markNeedsBuild();
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
      final leftParsed = await compute(
        _parseInWorker,
        (fileName: items[0].displayName, bytes: leftBytes),
      );
      leftText = leftParsed.plainText;
      leftName = leftParsed.fileName;
      leftPath = items[0].isDiskItem ? items[0].diskPath : null;

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
        insetPadding: _dlgInset,
        titlePadding: _dlgTitlePad,
        contentPadding: _dlgContentPad,
        actionsPadding: _dlgActionsPad,
        title: const Text('当前目录信息'),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.7,
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
        leading: Icon(Icons.folder,
            color: Colors.amber.shade300),
        title: Text(
  p,
  style: const TextStyle(
    fontSize: 12,
    color: Colors.black,
  ),
),
        onTap: () => Navigator.pop(c, p),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline,
              size: 20),
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
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
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

  void _toast(String msg) {
  if (!mounted) return;
  final ms = msg.length <= 10 ? 1500 : 2000;

  // 连续调用时只留最新一条
  _toastEntry?.remove();
  _toastEntry = null;

  final overlay = Overlay.of(context);
  final topPadding = MediaQuery.of(context).padding.top;

  final entry = OverlayEntry(
    builder: (ctx) => Positioned(
      top: topPadding + 8,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                msg,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  _toastEntry = entry;
  overlay.insert(entry);

  Future<void>.delayed(Duration(milliseconds: ms), () {
    if (!mounted) return;
    if (_toastEntry == entry) {
      _toastEntry?.remove();
      _toastEntry = null;
    }
  });
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

  List<String> _selectedDiskPaths() {
    final out = <String>[];
    for (final p in _selectedPaths) {
      if (_isZipInnerKey(p)) continue;
      out.add(p);
    }
    return out;
  }

  void _bookmarkSelected() {
    final paths = _selectedDiskPaths();
    if (paths.isEmpty) {
      _toast('压缩包内的文件不支持收藏');
      return;
    }
    final notifier = ref.read(fileBookmarksProvider.notifier);
    final existing = ref.read(fileBookmarksProvider);

    // 全部已收藏 → 取消；否则 → 收藏
    final allMarked = paths.every((p) => existing.contains(p));
    if (allMarked) {
      for (final p in paths) {
        notifier.remove(p);
      }
      _toast('已取消收藏 ${paths.length} 项');
    } else {
      notifier.addAll(paths);
      _toast('已收藏 ${paths.length} 项');
    }
    setState(_clearSelection);
  }

  /// 顶栏「收藏文件」：不用先选中，直接收藏屏幕上可见的第一个文件。
  /// 从可见列表顶部往下找，跳过文件夹和占位行，遇到第一个文件就收藏。
  /// 只收藏不取消——已收藏时再点也只弹提示，避免误触删掉收藏。
  void _bookmarkFirstVisibleFile() {
    for (final key in _snapshotVisiblePaths()) {
      if (key.startsWith('__loading__') || key.startsWith('__error__')) {
        continue;
      }
      if (_isZipInnerKey(key)) {
        _toast('压缩包内的文件不支持收藏');
        return;
      }
      _DisplayItem? it;
      for (final c in (_cachedDisplayItems ?? const <_DisplayItem>[])) {
        if (c.key == key) {
          it = c;
          break;
        }
      }
      if (it == null) {
        for (final c in (_visibleItems ?? const <_DisplayItem>[])) {
          if (c.key == key) {
            it = c;
            break;
          }
        }
      }
      if (it == null) {
        for (final h in _filterDeepResults) {
          if (h.path == key) {
            it = _DisplayItem(
              key: h.path,
              displayName: h.name,
              depth: 0,
              isDir: h.isDir,
              size: h.size,
              modified: h.modified,
              searchHit: h,
            );
            break;
          }
        }
      }
      if (it == null || it.isDir) continue;
      if (!ref.read(fileBookmarksProvider).contains(key)) {
        ref.read(fileBookmarksProvider.notifier).addAll([key]);
      }
      _toast('已收藏 ${it.displayName}');
      return;
    }
    _toast('屏幕上没有可见的文件');
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
          style: TextButton.styleFrom(foregroundColor: Colors.red),
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
    _markerMode == _MarkerMode.off &&
    _expandedZipKeys.isEmpty,
                onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_markerMode != _MarkerMode.off) {
            setState(() => _markerMode = _MarkerMode.off);
          } else if (_selectionMode) {
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
  child: Column(
    children: [
      _buildBreadcrumbs(),
            if (!ref.watch(browserSearchBarCollapsedProvider) ||
                _forceShowSearchBar)
              IgnorePointer(
                ignoring: _selectionMode,
                child: _buildSearchBar(),
              ),
        if (_searchActive) _buildSearchStatusBar(),
        if (!_searchActive &&
            !_selectionMode &&
            _expandedZipKeys.isNotEmpty)
          _buildExpandedZipBar(),
      Expanded(
  child: Stack(
    children: [
      Positioned.fill(child: _buildBody()),
      if (!_selectionMode)
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: ref.watch(browserScrollbarWidthProvider),
          child: _BrowserScrollbar(
            positionsListenable: _positionsListener.itemPositions,
            itemScrollController: _itemScrollController,
            totalRows: _currentTotalRows,
          ),
        ),
      if (!_selectionMode) ...[
        // 上翻页按钮
        if (ref.watch(browserPageUpEnabledProvider))
          Positioned(
            left: MediaQuery.of(context).size.width *
                    ref.watch(browserPageUpXProvider) /
                    100 -
                ref.watch(browserPageUpSizeProvider) / 2,
            top: MediaQuery.of(context).size.height *
                    ref.watch(browserPageUpYProvider) /
                    100 -
                ref.watch(browserPageUpSizeProvider) / 2,
            child: _BrowserPageButton(
              icon: Icons.keyboard_arrow_up,
              size: ref.watch(browserPageUpSizeProvider),
              color: ref.watch(browserPageUpColorProvider),
              opacity: ref.watch(browserPageUpOpacityProvider),
              isSquare: ref.watch(browserPageUpSquareProvider),
              onPressed: _pageUp,
            ),
          ),
        // 下翻页按钮
        if (ref.watch(browserPageDownEnabledProvider))
          Positioned(
            left: MediaQuery.of(context).size.width *
                    ref.watch(browserPageDownXProvider) /
                    100 -
                ref.watch(browserPageDownSizeProvider) / 2,
            top: MediaQuery.of(context).size.height *
                    ref.watch(browserPageDownYProvider) /
                    100 -
                ref.watch(browserPageDownSizeProvider) / 2,
            child: _BrowserPageButton(
              icon: Icons.keyboard_arrow_down,
              size: ref.watch(browserPageDownSizeProvider),
              color: ref.watch(browserPageDownColorProvider),
              opacity: ref.watch(browserPageDownOpacityProvider),
              isSquare: ref.watch(browserPageDownSquareProvider),
              onPressed: _pageDown,
            ),
          ),
      ],
    ],
  ),
),
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
    final inMarkerMode = _markerMode != _MarkerMode.off;
    return AppBar(
      title: inMarkerMode
          ? TextButton(
              onPressed: () => setState(() => _markerMode = _MarkerMode.off),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text(
                '退出标记',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            )
          : GestureDetector(
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
        // ========== 搜索框收起/显示 ==========
        if (!_searchActive && !_forceShowSearchBar)
          IconButton(
            icon: CustomPaint(
              size: const Size(24, 24),
              painter: _SearchToggleIconPainter(
                collapsed: ref.watch(browserSearchBarCollapsedProvider),
                color: IconTheme.of(context).color ??
                    Theme.of(context).colorScheme.onSurface,
              ),
            ),
            tooltip: ref.watch(browserSearchBarCollapsedProvider)
                ? '显示搜索框'
                : '收起搜索框',
            onPressed: () {
              final cur = ref.read(browserSearchBarCollapsedProvider);
              ref
                  .read(browserSearchBarCollapsedProvider.notifier)
                  .update(!cur);
            },
          ),
        // ========== 收藏屏幕可见第一个文件 ==========
        IconButton(
          icon: const _BookmarkGemIcon(size: 24),
          tooltip: '收藏屏幕上第一个可见文件',
          onPressed: _bookmarkFirstVisibleFile,
        ),
        // ========== 标记模式按钮（点击进入/退出，长按打开设置） ==========
        GestureDetector(
          onLongPress: _showMarkerSettings,
          child: IconButton(
            icon: _MarkerBrushIcon(mode: _markerMode),
            onPressed: _toggleMarkerMode,
          ),
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
    case 'toggleFavorite':
      _toggleFavorite();
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
    case 'exportConfig':
      _exportConfig();
    case 'importConfig':
      _importConfig();
   case 'refresh':
  DirCache.instance.invalidate(_currentPath);
  _load(skipCache: true, restoreScroll: true, silent: true);
case 'jumpToPath':
  _showJumpToPathDialog();
case 'jumpToTop':
  _jumpToTop();
case 'dirInfo':
  _showDirInfoDialog();
case 'favorites':
  _showFavorites();
case 'fileBookmarks':
  _showFileBookmarks();
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
              value: 'toggleFavorite',
              child: Row(
                children: [
                  Icon(
                    isFav ? Icons.star : Icons.star_border,
                    color: isFav ? const Color(0xFFACF500) : null,
                  ),
                  const SizedBox(width: 10),
                  Text(isFav ? '取消收藏此目录' : '收藏此目录'),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'favorites',
              child: Row(
                children: [
   
      const Icon(Icons.folder_special),  
                  const SizedBox(width: 10),
                  Text('已收藏目录 (${favorites.length})'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
            value: 'fileBookmarks',
            child: Row(
              children: [
                const Icon(Icons.bookmark),
                const SizedBox(width: 10),
                Text(
                    '文件收藏 (${ref.read(fileBookmarksProvider).length})'),
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

  // ==================== 标记 · 模式切换 / 设置 / 处理点击 ====================

  void _toggleMarkerMode() {
    if (_markerMode != _MarkerMode.off) {
      setState(() => _markerMode = _MarkerMode.off);
      return;
    }
    setState(() {
      _markerMode = _selectedMarkerMode;
      // 模式1(标后退出)跟选择模式互斥，模式2(常驻)不互斥
      if (_selectedMarkerMode == _MarkerMode.exitAfterMark && _selectionMode) {
        _selectionMode = false;
        _selectedPaths.clear();
        _anchorPath = null;
      }
    });
  }

  Future<void> _showMarkerSettings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _MarkerSettingsDialog(
        selectedMode: _selectedMarkerMode,
        onModeChanged: (m) {
          if (!mounted) return;
          setState(() {
            _selectedMarkerMode = m;
            // 若当前正开着标记，实时切换到新选的模式
            if (_markerMode != _MarkerMode.off) _markerMode = m;
          });
        },
      ),
    );
  }

  Future<void> _handleMarkerTap(String path) async {
    // zip 内文件不支持标记（虚拟 key 不稳定）
    if (_isZipInnerKey(path)) {
      _toast('压缩包内的文件不支持标记');
      return;
    }

    final alreadyMarked = _markColors.containsKey(path);
    final showPicker = ref.read(browserMarkShowPickerProvider);
    final autoExit = _markerMode == _MarkerMode.exitAfterMark;

    // 未标记 + 开关关闭：直接用默认色标记
    if (!alreadyMarked && !showPicker) {
      final base = ref.read(browserMarkDefaultColorProvider);
      final alpha = ref.read(browserMarkDefaultOpacityProvider);
      setState(() {
        _markColors[path] = base.withValues(alpha: alpha);
        if (autoExit) _markerMode = _MarkerMode.off;
      });
      return;
    }

    // 弹色板（已标记的必弹；未标记的看开关）
    final initial = alreadyMarked
        ? _markColors[path]!
        : ref.read(browserMarkDefaultColorProvider);
    final initialBase =
        alreadyMarked ? initial.withValues(alpha: 1.0) : initial;
    final initialAlpha = alreadyMarked
        ? ((initial.toARGB32() >> 24) & 0xFF) / 255.0
        : ref.read(browserMarkDefaultOpacityProvider);

    final result = await showDialog<({String action, Color color})>(
      context: context,
      builder: (_) => _MarkerPaletteDialog(
        initialBaseColor: initialBase,
        initialOpacity: initialAlpha,
        isMarked: alreadyMarked,
      ),
    );

    if (!mounted) return;

    if (result == null) {
      // 用户取消：只在模式1时退出，模式2保持
      if (autoExit) setState(() => _markerMode = _MarkerMode.off);
      return;
    }

    if (result.action == 'unmark') {
      setState(() {
        _markColors.remove(path);
        if (autoExit) _markerMode = _MarkerMode.off;
      });
      return;
    }

    setState(() {
      _markColors[path] = result.color;
      if (autoExit) _markerMode = _MarkerMode.off;
    });
  }

  /// 模式2(常驻)下左图标区单击：标记 toggle。
  /// 未标记 → 用当前默认色标记；已标记 → 取消。
  /// 不弹色板，快速标记/取消；长按左图标区才弹色板精调。
  void _toggleMarkerQuick(String path) {
    if (_isZipInnerKey(path)) {
      _toast('压缩包内的文件不支持标记');
      return;
    }
    if (_markColors.containsKey(path)) {
      setState(() => _markColors.remove(path));
      _toast('已取消标记');
      return;
    }
    final base = ref.read(browserMarkDefaultColorProvider);
    final alpha = ref.read(browserMarkDefaultOpacityProvider);
    setState(() {
      _markColors[path] = base.withValues(alpha: alpha);
    });
  }

  /// 加载完成后，如果还有待消费的跳转，等一帧（让 build 重算 _cachedDisplayItems）再滚。
  void _tryConsumePendingJump() {
    final p = _pendingJumpPath;
    if (p == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 期间被覆盖/清掉：放弃这次
      if (_pendingJumpPath != p) return;
      _pendingJumpPath = null;

      final allItems = _cachedDisplayItems ?? const <_DisplayItem>[];
      final index = allItems.indexWhere((it) => it.key == p);
      if (index < 0) {
        _toast('文件已不存在，已跳到所在目录');
        return;
      }
      _scrollToPath(p);
      _startFlash(p);
    });
  }

  /// 跳转后让目标行渐隐高亮 900ms，方便一眼找到刚跳过来的行。
  void _startFlash(String path) {
    setState(() {
      _flashingPath = path;
      _flashSeq++;
    });
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (mounted && _flashingPath == path) {
        setState(() => _flashingPath = null);
      }
    });
  }

  /// 给目标行套一层渐隐高亮。非目标行原样返回，零开销。
  Widget _wrapWithFlash(Widget child, String key) {
    if (_flashingPath != key) return child;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: TweenAnimationBuilder<double>(
              key: ValueKey('flash_$_flashSeq'),
              tween: Tween(begin: 1.0, end: 0.0),
              duration: const Duration(milliseconds: 900),
              builder: (ctx, v, _) {
                if (v <= 0.01) return const SizedBox.shrink();
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.yellow.withValues(alpha: 0.35 * v),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: v),
                      width: 3,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 跳转到某个收藏的文件（跨目录 / 同目录都走这里）。
  void _jumpToBookmark(String path) {
    if (_isZipInnerKey(path)) {
      _toast('压缩包内的文件不支持跳转');
      return;
    }

    // 父目录
    final slash = path.lastIndexOf('/');
    if (slash <= 0) return;
    final parent = path.substring(0, slash);

    // 同目录：直接滚，天然兜底
    if (parent == _currentPath) {
      final allItems = _cachedDisplayItems ?? const <_DisplayItem>[];
      final index = allItems.indexWhere((it) => it.key == path);
      if (index < 0) {
        _toast('文件已不存在');
        return;
      }
      _scrollToPath(path);
      _startFlash(path);
      return;
    }

    // 跨目录：设 pending + 跳目录
    if (!Directory(parent).existsSync()) {
      _toast('目录不存在：$parent');
      return;
    }
    _pendingJumpPath = path;
    _navigateTo(parent, preservePendingJump: true);
  }

  /// 收藏列表弹窗。
  Future<void> _showFileBookmarks() async {
    final bookmarks = ref.read(fileBookmarksProvider);
    if (bookmarks.isEmpty) {
      _toast('还没有收藏任何文件');
      return;
    }

    final picked = await showDialog<String>(
      context: context,
      builder: (c) => _FileBookmarksDialog(bookmarks: bookmarks),
    );
    if (picked != null && mounted) _jumpToBookmark(picked);
  }

  Widget _buildMarkerModeBar() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFEB3B),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.brush, size: 16, color: Colors.black87),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '标记模式：点击一个文件完成标记，标记后自动退出',
              style: TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Colors.black87,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () => setState(() => _markerMode = _MarkerMode.off),
            child: const Text('退出'),
          ),
        ],
      ),
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
        .where((it) => !it.key.startsWith('__loading__') &&
            !it.key.startsWith('__error__'))
        .map((it) => it.key)
        .toList();
    final allSelected = selectable.isNotEmpty &&
        selectable.every((k) => _selectedPaths.contains(k));
    return AppBar(
      // 选择模式顶栏：浅绿底（用户指定 D9FFC5 再调浅），呼应列表选中项的淡绿
      backgroundColor: const Color(0xFFE2FFD3),
      foregroundColor: Colors.black,
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
  final scope = ref.watch(searchScopeProvider);
  final mode = ref.watch(searchBoxModeProvider);
  final isFilter = mode == SearchBoxMode.filter;
  final isCustom = scope == SearchScope.custom;
  final customFolders = ref.watch(customSearchFoldersProvider);
  final hasText = _searchCtrl.text.isNotEmpty;
  final noTextButHasConds = !hasText && _hasActiveConditions;

  const currentText = Color(0xFFB79800);
  const currentBtnBg = Color(0xFFFFF7D2);
  const customText = Color(0xFF009EDD);
  const customBtnBg = Color(0xFFE4FAFF);

  const filterAccent = Color(0xFFE53935);
  const filterBtnBg = Color(0xFFFFCDD2);
  const filterInputBg = Color(0xFFFFF0F0);

  final Color accent;
  final Color btnBg;
  final Color btnIconColor;
  final Color inputBg;
  final Color inputFg;
  final Color suffixBg;
  final Color suffixFg;
  final IconData btnIcon;
  final String hintText;

  if (isFilter) {
    accent = filterAccent;
    btnBg = filterBtnBg;
    btnIconColor = Colors.black87;
    inputBg = filterInputBg;
    inputFg = Colors.black;
    suffixBg = const Color(0x33FFF0F0);
    suffixFg = Colors.black87;
    btnIcon = Icons.filter_alt;
    hintText = _selectionMode
        ? '选择模式下禁止点击'
        : (noTextButHasConds
            ? '已启用高级条件，点「筛选」生效'
            : '输入关键词过滤文件');
  } else {
    accent = isCustom ? customText : currentText;
    btnBg = isCustom ? customBtnBg : currentBtnBg;
    btnIconColor =
        (hasText || _hasActiveConditions) ? accent : Colors.black54;
    inputBg = Colors.transparent;
    inputFg = Colors.black;
    suffixBg = Colors.transparent;
    suffixFg = accent;
    btnIcon = Icons.search;
    hintText = _selectionMode
        ? '选择模式下禁止点击'
        : (noTextButHasConds
            ? '已启用高级条件，点「搜索」生效'
            : (isCustom && customFolders.isEmpty
                ? '点左侧"搜索设置"配置范围'
                : '输入关键词'));
  }

  return TapRegion(
    groupId: _searchPanelTapGroup,
    onTapOutside: (_) {
      FocusManager.instance.primaryFocus?.unfocus();
    },
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _selectionMode ? null : _showSearchSettings,
                  borderRadius: BorderRadius.circular(8),
            
					
					
					
					
					
					
					child: Container(
  height: 46,
  padding: const EdgeInsets.symmetric(horizontal: 4),
  alignment: Alignment.center,
  decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(8),
    border: isFilter
        ? Border.all(
            color: _selectionMode
                ? Colors.grey.shade300
                : filterBtnBg,
            width: 1,
          )
        : null,
  ),
  child: Text(
    '搜索设置',
    style: TextStyle(
      fontSize: 12,
      color: _selectionMode
          ? Colors.grey
          : (isFilter ? Colors.black : accent),
      fontWeight: (isFilter || hasText)
          ? FontWeight.bold
          : FontWeight.normal,
    ),
  ),
),





					
                ),
              ),
              const SizedBox(width: 2),





				
              InkWell(
  onTap: _selectionMode
      ? null
      : (isFilter
          ? null
          : (hasText ? _doSearch : null)),
  borderRadius: BorderRadius.circular(8),
  child: Container(
    padding: const EdgeInsets.symmetric(
      horizontal: 9,
      vertical: 11,
    ),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      color: _selectionMode ? Colors.grey.shade200 : btnBg,
    ),
    child: Icon(btnIcon, color: btnIconColor),
  ),
),






				
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  key: _searchInputKey,
                  controller: _searchCtrl,
                  enabled: !_selectionMode,
                  cursorColor: accent,
                  style: TextStyle(
                    color: inputFg,
                    fontWeight:
                        isFilter ? FontWeight.bold : FontWeight.normal,
                  ),
                  decoration: InputDecoration(
                    hintText: hintText,
                    hintStyle: noTextButHasConds
                        ? TextStyle(
                            fontSize: 14,
                            color: accent.withValues(alpha: 0.8),
                          )
                        : null,
                    filled: isFilter,
                    fillColor: isFilter ? inputBg : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 9,
                    ),
                    suffixIcon: _selectionMode
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildAdvancedToggle(),
                              hasText
                                  ? _suffixButton(
                                      icon: Icons.backspace_outlined,
                                      tooltip: '清空输入',
                                      fg: suffixFg,
                                      bg: suffixBg,
                                      onTap: isFilter
                                          ? _clearFilter
                                          : _clearSearchInput,
                                    )
                                  : _suffixButton(
                                      icon: Icons.history,
                                      tooltip: '搜索历史',
                                      fg: suffixFg,
                                      bg: suffixBg,
                                      onTap: _showSearchHistory,
                                    ),
                            ],
                          ),
                    suffixIconConstraints: _selectionMode
                        ? null
                        : const BoxConstraints(minWidth: 84, minHeight: 44),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: accent, width: 2),
                    ),
                  ),
                  onChanged: _onSearchChanged,
                  onSubmitted: (_) {
                    if (_selectionMode) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      return;
                    }
                    if (isFilter) {
                      if (_advancedOpen || _hasActiveConditions) {
                        _runFilterNow();
                      } else {
                        FocusManager.instance.primaryFocus?.unfocus();
                      }
                    } else {
                      _doSearch();
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        if (!_advancedOpen && _hasActiveConditions && !_selectionMode)
          _buildActionChips(),
      ],
    ),
  );
}


Widget _buildActionChips() {
  final isFilter =
      ref.read(searchBoxModeProvider) == SearchBoxMode.filter;
  final colors = _submitButtonColors();

  return Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
    child: Row(
      children: [
        Expanded(
          child: _actionChip(
            label: isFilter ? '筛选' : '搜索',
            onTap: isFilter ? _runFilterNow : _doSearch,
            bg: colors.bg,
            fg: colors.fg,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _actionChip(
            label: '清空',
            onTap: _clearConditionsAndRealtime,
          ),
        ),
      ],
    ),
  );
}

Widget _actionChip({
  required String label,
  required VoidCallback onTap,
  Color? bg,
  Color? fg,
}) {
  return SizedBox(
    height: 38,
    child: OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: bg ?? Colors.white,
        side: BorderSide(color: fg ?? Colors.black, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(19),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: fg ?? Colors.black,
        ),
      ),
    ),
  );
}

Widget _suffixButton({
  required IconData icon,
  required String tooltip,
  required Color fg,
  required Color bg,
  required VoidCallback onTap,
}) {
  return SizedBox(
    width: 40,
    height: 44,
    child: Material(
      color: bg,
      child: InkWell(
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Icon(icon, size: 22, color: fg),
        ),
      ),
    ),
  );
}
Future<void> _showSearchSettings() async {
    FocusManager.instance.primaryFocus?.unfocus();
  _closeAdvanced(runRealtimeIfNeeded: false);

    
  await showDialog<void>(
    context: context,
    builder: (c) => Consumer(
      builder: (c, ref, _) {
        final scope = ref.watch(searchScopeProvider);
        final customFolders = ref.watch(customSearchFoldersProvider);
        final searchSortField = ref.watch(searchSortFieldProvider);
        final searchSortAsc = ref.watch(searchSortAscProvider);
        final boxMode = ref.watch(searchBoxModeProvider);
        final depth = ref.watch(filterDepthProvider);
        final isFilter = boxMode == SearchBoxMode.filter;

        const currentColor = Color(0xFFB79800);
        const customColor = Color(0xFF009EDD);
        const filterColor = Color(0xFFE53935);

        Widget scopeRow({
          required SearchScope value,
          required String label,
          required Color activeColor,
        }) {
          final selected = scope == value;
          return InkWell(
            onTap: () {
              ref.read(searchScopeProvider.notifier).update(value);
              if (_searchActive && _searchCtrl.text.isNotEmpty) {
    _startSearch();
              }
            },
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              child: Row(
                children: [
                  _RadioDot(selected: selected, color: activeColor),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        
  fontSize: selected ? 15 : 14,
                        color: selected ? activeColor : Colors.grey,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        Widget modeRow({
          required SearchBoxMode value,
          required String title,
          required String subtitle,
          required Color activeColor,
        }) {
          final selected = boxMode == value;
          return InkWell(
            onTap: () => ref
                .read(searchBoxModeProvider.notifier)
                .update(value),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: _RadioDot(
                      selected: selected,
                      color: activeColor,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                     
						  
						  
						  
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: selected ? 15 : 14,
                            color: selected ? activeColor : Colors.grey,
                            fontWeight: selected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        const SizedBox(height: 2),
Text(
  subtitle,
  style: TextStyle(
    fontSize: selected ? 12 : 11,
    height: 1.4,
    color: selected ? activeColor : Colors.grey,
    fontWeight: selected
        ? FontWeight.bold
        : FontWeight.normal,
  ),
),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return AlertDialog(
          insetPadding: _dlgInset,
          titlePadding: _dlgTitlePad,
          contentPadding: _dlgContentPad,
          actionsPadding: _dlgActionsPad,
          title: const Text('搜索相关设置'),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(c).size.height * 0.7,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _SearchSettingsSectionTitle('搜索框行为'),
                  modeRow(
  value: SearchBoxMode.search,
  title: '搜索',
  subtitle:
      '打字不响应，点按钮或回车才开始；'
      '递归搜索子目录（切页显示结果）',
  activeColor: Colors.black,   
),
modeRow(
  value: SearchBoxMode.filter,
  title: '过滤',
  subtitle: '边输入边筛文件，页面不跳转；回车无动作',
  activeColor: const Color(0xFFA74848),
),

                  const SizedBox(height: 4),
                  const Divider(height: 1),
                  const SizedBox(height: 8),

                  if (isFilter) ...[
                    const _SearchSettingsSectionTitle('过滤深度'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        children: [
                          const Text('深度：',
                              style: TextStyle(fontSize: 14)),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 64,
                            child: TextFormField(
                              key: ValueKey('fd_$depth'),
                              initialValue: depth.toString(),
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 14),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 8,
                                ),
                              ),
                              onFieldSubmitted: (v) {
                                final n = int.tryParse(v.trim());
                                if (n == null) return;
                                ref
                                    .read(filterDepthProvider.notifier)
                                    .set(n);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 10, 4, 4),
                      child: Text(
                        '0 = 只过滤当前目录\n'
                        '1 = 包含一级子目录\n'
                        '2 = 包含二级子目录\n'
                        '……\n'
                        '9 = 包含九级子目录',
                        style: TextStyle(fontSize: 12, height: 1.6),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
                      child: Text(
                        'ⓘ 过滤固定作用于"当前目录 + 子目录"，'
                        '不能像搜索那样自定义范围。',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.4,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  ] else ...[
                    const _SearchSettingsSectionTitle('搜索范围'),
                    scopeRow(
                      value: SearchScope.currentRecursive,
                      label: '当前目录及子目录',
                      activeColor: currentColor,
                    ),
                    scopeRow(
                      value: SearchScope.custom,
                      label:
                          '自定义的搜索范围（${customFolders.length}）',
                      activeColor: customColor,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 38,
                        top: 4,
                        bottom: 8,
                      ),
                      child: FilledButton.tonalIcon(
  style: FilledButton.styleFrom(
    backgroundColor: scope == SearchScope.custom
        ? const Color(0xFF93E6F0)   // 自定义范围：现状色
        : const Color(0xFFD9F3F0),  // 子目录：更浅的蓝
    foregroundColor: Colors.black87,
  ),
  icon: const Icon(Icons.folder_special, size: 20),
  label: const Text('管理搜索范围'),
  onPressed: () => _showSearchFolderPicker(),
),
                    ),
                    const SizedBox(height: 4),
                    const Divider(height: 1),
                    const SizedBox(height: 8),

                const _SearchSettingsSectionTitle('搜索结果排序'),
for (final f in SortField.values)
  RadioListTile<SortField>(
    dense: true,
    contentPadding: EdgeInsets.zero,
	  title: Text(
  _sortLabel(f),
  style: TextStyle(
    fontSize: searchSortField == f ? 15 : 14,
    color: searchSortField == f
        ? Colors.black
        : Colors.grey,
    fontWeight: searchSortField == f
        ? FontWeight.bold
        : FontWeight.normal,
  ),
),
value: f,
groupValue: searchSortField,
activeColor: Colors.black,
    onChanged: (v) {
      if (v == null) return;
      ref
          .read(searchSortFieldProvider.notifier)
          .update(v);
      _resortSearchResults();
    },
  ),
                 const Divider(height: 1),
RadioListTile<bool>(
  dense: true,
  contentPadding: EdgeInsets.zero,
  title: Text(
    '升序',
    style: TextStyle(
      fontSize: searchSortAsc ? 15 : 14,
      color: searchSortAsc
          ? Colors.black
          : Colors.grey,
      fontWeight: searchSortAsc
          ? FontWeight.bold
          : FontWeight.normal,
    ),
  ),
  value: true,
  groupValue: searchSortAsc,
  activeColor: Colors.black,
  onChanged: (_) {
    ref
        .read(searchSortAscProvider.notifier)
        .update(true);
    _resortSearchResults();
  },
),
RadioListTile<bool>(
  dense: true,
  contentPadding: EdgeInsets.zero,
  title: Text(
    '降序',
    style: TextStyle(
      fontSize: !searchSortAsc ? 15 : 14,
      color: !searchSortAsc
          ? Colors.black
          : Colors.grey,
      fontWeight: !searchSortAsc
          ? FontWeight.bold
          : FontWeight.normal,
    ),
  ),
  value: false,
  groupValue: searchSortAsc,
  activeColor: Colors.black,
  onChanged: (_) {
    ref
        .read(searchSortAscProvider.notifier)
        .update(false);
    _resortSearchResults();
  },
),
                    
                    
                  ],
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
        onPressed: _bookmarkSelected,
        child: const Text(
          '收藏',
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

  final mode = ref.read(searchBoxModeProvider);
  if (mode == SearchBoxMode.filter &&
      _searchCtrl.text.trim().isNotEmpty) {
    final items = _visibleItems ?? const <_DisplayItem>[];
    if (items.isEmpty) {
      return const Center(child: Text('无匹配'));
    }
  }

  return ref.watch(browserGridModeProvider)
      ? _buildGridBody(_filterEntries(entries))
      : _buildListBody();
}

/// 当前列表的总行数（网格两列 = 行数）。
int _currentTotalRows() {
  if (_searchActive) {
    return _cachedDisplayItems?.length ?? 0;
  }
  if (ref.read(browserGridModeProvider)) {
    final entries = _filterEntries(_entries ?? const <EntryInfo>[]);
    return (entries.length + 1) ~/ 2;
  }
  return _visibleItems?.length ?? 0;
}

void _pageDown() {
  if (!_itemScrollController.isAttached) return;
  final positions = _positionsListener.itemPositions.value;
  if (positions.isEmpty) return;
  var minIdx = 1 << 30;
  var maxIdx = -1;
  for (final p in positions) {
    if (p.index < minIdx) minIdx = p.index;
    if (p.index > maxIdx) maxIdx = p.index;
  }
  final total = _currentTotalRows();
  if (total <= 1) return;
  final pageSize = maxIdx - minIdx + 1;
  // 保留 1 个重叠文件，避免最后一个只显示一半的文件被跳过
  final target = (minIdx + pageSize - 1).clamp(0, total - 1);
  if (target <= minIdx) return;
  _itemScrollController.jumpTo(index: target);
}

void _pageUp() {
  if (!_itemScrollController.isAttached) return;
  final positions = _positionsListener.itemPositions.value;
  if (positions.isEmpty) return;
  var minIdx = 1 << 30;
  var maxIdx = -1;
  for (final p in positions) {
    if (p.index < minIdx) minIdx = p.index;
    if (p.index > maxIdx) maxIdx = p.index;
  }
  final total = _currentTotalRows();
  if (total <= 1) return;
  final pageSize = maxIdx - minIdx + 1;
  // 保留 1 个重叠文件，上一页最后一项在本页顶部也能看到
  final target = (minIdx - pageSize + 1).clamp(0, total - 1);
  if (target >= minIdx) return;
  _itemScrollController.jumpTo(index: target);
}

  // ==================== 列表模式（无粘性头部） ====================

Widget _buildListBody() {
  final fontName = ref.watch(browserFontListNameProvider);
  final fontMeta = ref.watch(browserFontListMetaProvider);
  final colorScheme = Theme.of(context).colorScheme;

  final items = _visibleItems ?? const <_DisplayItem>[];
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

    // 左侧图标区宽度（含缩进）。点这块 = 选中/取消。
    final iconZoneRight = 48.0 + item.depth * 18.0;

    // zip 头（顶层或嵌套）：和普通文件一样的 ListTile，
    // 只用图标区分展开/折叠（折叠=空心蓝，展开=实心蓝）。
if (item.isZip) {
  final isExpanded = _expandedZipKeys.contains(item.key);
  final isTopLevel = item.ownerZipKey == null;
  final zipIcon = (isTopLevel && isExpanded)
    ? Icons.folder_zip_outlined
    : Icons.folder_zip;
  final metaLine = _buildItemMetaLine(item);

return _wrapWithFlash(
  Listener(
  onPointerDown: (e) => _lastTapX = e.localPosition.dx,
  child: Container(
  color: _markColors[item.key],
  foregroundDecoration: selected
      ? BoxDecoration(
          border: Border(
            top: BorderSide(
              color: const Color(0xFFB000FF),
              width: 1,
            ),
            bottom: BorderSide(
              color: const Color(0xFFB000FF),
              width: 1,
            ),
            left: BorderSide(
              color: const Color(0xFFB000FF),
              width: 2,
            ),
            right: BorderSide(
              color: const Color(0xFFB000FF),
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
  left: item.depth * 18.0,
  right: 8,
),
selected: selected,
selectedTileColor: const Color(0xFFF4FFF5),
leading: SizedBox(
  width: 48,
  child: Padding(
    padding: const EdgeInsets.only(left: 8),
    child: Center(
      child: Icon(
        zipIcon,
        size: 28,
        color: Colors.blue.shade600,
      ),
    ),
  ),
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
        // 模式1：整行点击都标记（原逻辑）
        if (_markerMode == _MarkerMode.exitAfterMark) {
          _handleMarkerTap(item.key);
          return;
        }
        // 模式2：左图标区点击 = 标记 toggle（只标不弹色板）
        if (_markerMode == _MarkerMode.alwaysOn &&
            _lastTapX < iconZoneRight &&
            !_selectionMode) {
          _toggleMarkerQuick(item.key);
          return;
        }
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
      onLongPress: _markerMode == _MarkerMode.exitAfterMark
          ? null
          : () {
              // 模式2：长按左图标区 = 弹色板改色，其他区域 = 选择模式
              if (_markerMode == _MarkerMode.alwaysOn &&
                  _lastTapX < iconZoneRight &&
                  !_selectionMode) {
                _handleMarkerTap(item.key);
                return;
              }
              _onLongPressItem(item);
            },
    ),
  ),
  ),
  item.key,
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
            Icon(Icons.folder, size: 18, color: Colors.black87),
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

return _wrapWithFlash(
  Listener(
  onPointerDown: (e) => _lastTapX = e.localPosition.dx,
  child: Container(
  color: _markColors[item.key],
  foregroundDecoration: selected
      ? BoxDecoration(
          border: Border(
            top: BorderSide(
              color: const Color(0xFFB000FF),
              width: 1,
            ),
            bottom: BorderSide(
              color: const Color(0xFFB000FF),
              width: 1,
            ),
            left: BorderSide(
              color: const Color(0xFFB000FF),
              width: 2,
            ),
            right: BorderSide(
              color: const Color(0xFFB000FF),
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
        left: item.depth * 18.0,
        right: 8,
      ),
      selected: selected,
      selectedTileColor: const Color(0xFFF4FFF5),
      leading: SizedBox(
        width: 48,
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Center(
            child: Icon(
              isZipInner
                  ? Icons.insert_drive_file_outlined
                  : (item.isDir
                      ? Icons.folder
                      : Icons.insert_drive_file_outlined),
              size: 28,
              color: isZipInner
                  ? Colors.blueGrey.shade300
                  : (item.isDir
                      ? Colors.black87
                      : _fileColor(item.displayName)),
            ),
          ),
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
          if (_markerMode == _MarkerMode.exitAfterMark) {
            _handleMarkerTap(item.key);
            return;
          }
          // 模式2：左图标区点击 = 标记 toggle
          if (_markerMode == _MarkerMode.alwaysOn &&
              _lastTapX < iconZoneRight &&
              !_selectionMode) {
            _toggleMarkerQuick(item.key);
            return;
          }
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
        onLongPress: _markerMode == _MarkerMode.exitAfterMark
            ? null
            : () {
                // 模式2：长按左图标区 = 弹色板改色，其他区域 = 选择模式
                if (_markerMode == _MarkerMode.alwaysOn &&
                    _lastTapX < iconZoneRight &&
                    !_selectionMode) {
                  _handleMarkerTap(item.key);
                  return;
                }
                _onLongPressItem(item);
              },
    ),
    ),
  ),
  item.key,
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

// 标记色：选中优先，其次标记色，最后默认（非文本灰底）
final markColor = _markColors[e.path];
final baseColor = info.isDir
    ? null
    : (_textExts.contains(_extOf(info.name))
        ? null
        : const Color(0xFFF0F0F0));
final bgColor = selected ? _gridSelectedBg : (markColor ?? baseColor);

return _wrapWithFlash(
  GestureDetector(
      onTap: () {
        if (_markerMode == _MarkerMode.exitAfterMark) {
          _handleMarkerTap(e.path);
          return;
        }
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
      onLongPress: _markerMode == _MarkerMode.exitAfterMark
          ? null
          : () {
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
        decoration: BoxDecoration(color: bgColor),
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
    ),
  e.path,
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

    // 左侧图标区宽度（含缩进）。点这块 = 选中/取消。
    final iconZoneRight = 48.0 + item.depth * 18.0;

    return Listener(
      onPointerDown: (e) => _lastTapX = e.localPosition.dx,
      child: Container(
        foregroundDecoration: selected
            ? BoxDecoration(
                border: Border.all(
                  color: const Color(0xFFFF00C3),
                  width: 1,
                ),
              )
            : null,
        child: ListTile(
          dense: true,
          isThreeLine: true,
          minVerticalPadding: 0,
          visualDensity: const VisualDensity(horizontal: 0, vertical: -4),
          contentPadding: EdgeInsets.only(
            left: item.depth * 18.0,
            right: 8,
          ),
          selected: selected,
          selectedTileColor: const Color(0xFFF4FFF5),
          leading: SizedBox(
            width: 48,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, top: 4),
              child: Align(
                alignment: Alignment.topCenter,
           
				  
				  child: Icon(
  item.isZip
      ? Icons.folder_zip
      : (item.isDir
          ? Icons.folder
          : Icons.insert_drive_file_outlined),
  size: 28,
  color: isZipInner
      ? Colors.blueGrey.shade300
      : (item.isDir
          ? Colors.black87
          : _fileColor(item.displayName)),
),
              ),
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
            if (_markerMode == _MarkerMode.exitAfterMark) {
              _handleMarkerTap(item.key);
              return;
            }
            // 模式2：左图标区点击 = 标记 toggle
            if (_markerMode == _MarkerMode.alwaysOn &&
                _lastTapX < iconZoneRight &&
                !_selectionMode) {
              _toggleMarkerQuick(item.key);
              return;
            }
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
          onLongPress: _markerMode == _MarkerMode.exitAfterMark
              ? null
              : () {
                  // 模式2：长按左图标区 = 弹色板改色，其他区域 = 选择模式
                  if (_markerMode == _MarkerMode.alwaysOn &&
                      _lastTapX < iconZoneRight &&
                      !_selectionMode) {
                    _handleMarkerTap(item.key);
                    return;
                  }
                  _onLongPressItem(item);
                },
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
  static const EdgeInsets _dlgInset = EdgeInsets.all(4);
  static const EdgeInsets _dlgTitlePad = EdgeInsets.fromLTRB(12, 8, 12, 0);
  static const EdgeInsets _dlgContentPad = EdgeInsets.fromLTRB(8, 4, 8, 4);
  static const EdgeInsets _dlgActionsPad = EdgeInsets.fromLTRB(4, 0, 4, 4);

  String? _md5;
  bool _md5Loading = false;
  String? _md5Error;
  int? _fileCount;
  int? _dirCount;
  bool _countLoading = false;
  bool _countTruncated = false;
  String? _countError;

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

  Future<void> _countFolder() async {
    if (!widget.isDir) return;
    setState(() {
      _countLoading = true;
      _countError = null;
      _fileCount = null;
      _dirCount = null;
      _countTruncated = false;
    });
    try {
      final result = await compute(
        _PropertiesDialogState._countFolderWorker,
        widget.path,
      );
      if (!mounted) return;
      setState(() {
        _fileCount = result[0];
        _dirCount = result[1];
        _countTruncated = result[2] == 1;
        _countLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _countError = e.toString();
        _countLoading = false;
      });
    }
  }

  /// 在独立 isolate 里跑的目录统计。不 stat 文件，只遍历目录。
  /// 返回 [文件数, 子目录数, 是否截断(1/0)]
  static List<int> _countFolderWorker(String rootPath) {
    var files = 0;
    var dirs = 0;
    const limit = 500000;
    const timeLimitMs = 15000;
    final startTime = DateTime.now();
    final stack = <String>[rootPath];
    while (stack.isNotEmpty) {
      if (files + dirs > limit) return [files, dirs, 1];
      if (DateTime.now().difference(startTime).inMilliseconds > timeLimitMs) {
        return [files, dirs, 1];
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
          files++;
        } else if (e is Directory) {
          dirs++;
          stack.add(e.path);
        }
      }
    }
    return [files, dirs, 0];
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
              if (widget.isDir)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '文件夹内容',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(height: 4),
                      _buildFolderCountArea(),
                    ],
                  ),
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

  Widget _buildFolderCountArea() {
    if (!widget.isDir) return const SizedBox.shrink();

    if (_countLoading) {
      return const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('统计中…（文件多时需几秒）', style: TextStyle(fontSize: 13)),
        ],
      );
    }

    if (_countError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '统计失败：$_countError',
            style: const TextStyle(color: Colors.red, fontSize: 12),
          ),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: _countFolder,
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('重试'),
          ),
        ],
      );
    }

    if (_fileCount != null) {
      final str = _countTruncated
          ? '超过 50 万项或耗时超过 15 秒，未完全统计（已数到 ${_fileCount!} 个文件）'
          : '${_fileCount!} 个文件 · ${_dirCount!} 个子文件夹';
      return Row(
        children: [
          Expanded(
            child: SelectableText(str, style: const TextStyle(fontSize: 13)),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: '重新统计',
            visualDensity: VisualDensity.compact,
            onPressed: _countFolder,
          ),
        ],
      );
    }

    return OutlinedButton.icon(
      onPressed: _countFolder,
      icon: const Icon(Icons.folder_open, size: 16),
      label: const Text('点击统计文件数量'),
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

class _TriangleIcon extends StatelessWidget {
  const _TriangleIcon({
    required this.filled,
    required this.direction,
    this.size = 20,
    this.color = Colors.black,
  });

  final bool filled;
  final String direction; // 'down' 或 'left'
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _TrianglePainter(
          filled: filled,
          direction: direction,
          color: color,
        ),
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  _TrianglePainter({
    required this.filled,
    required this.direction,
    required this.color,
  });

  final bool filled;
  final String direction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke;

    final w = size.width;
    final h = size.height;
    final path = Path();

    if (direction == 'down') {
      path.moveTo(w * 0.18, h * 0.30);
      path.lineTo(w * 0.82, h * 0.30);
      path.lineTo(w * 0.50, h * 0.78);
      path.close();
    } else {
      path.moveTo(w * 0.72, h * 0.18);
      path.lineTo(w * 0.72, h * 0.82);
      path.lineTo(w * 0.26, h * 0.50);
      path.close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter oldDelegate) {
    return oldDelegate.filled != filled ||
        oldDelegate.direction != direction ||
        oldDelegate.color != color;
  }
}

// ==================== 标记 · 色板弹窗 ====================

class _MarkerPaletteDialog extends ConsumerStatefulWidget {
  const _MarkerPaletteDialog({
    required this.initialBaseColor,
    required this.initialOpacity,
    required this.isMarked,
  });

  final Color initialBaseColor;
  final double initialOpacity;
  final bool isMarked;

  @override
  ConsumerState<_MarkerPaletteDialog> createState() =>
      _MarkerPaletteDialogState();
}

class _MarkerPaletteDialogState
    extends ConsumerState<_MarkerPaletteDialog> {
  late Color _baseColor;
  late double _opacity;

  @override
  void initState() {
    super.initState();
    _baseColor = widget.initialBaseColor;
    _opacity = widget.initialOpacity.clamp(0.01, 1.0);
  }

  Color get _finalColor => _baseColor.withValues(alpha: _opacity);

  @override
  Widget build(BuildContext context) {
    final presets = ref.watch(browserMarkPresetColorsProvider);
    final s = Theme.of(context).colorScheme;

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: const Text('选择标记颜色'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('预设色（长按可改）',
                  style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < presets.length; i++)
                    _swatch(context, i, presets[i]),
                ],
              ),
              const SizedBox(height: 12),
              Text('当前颜色',
                  style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    _markColorToHex(_baseColor),
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: _pickCustom,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: _baseColor,
                        border: Border.all(color: s.outline),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _pickCustom,
                    child: const Text('自定义'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '不透明度：${(_opacity * 100).round()}%',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Slider(
                min: 0.01,
                max: 1.0,
                divisions: 99,
                value: _opacity,
                label: '${(_opacity * 100).round()}%',
                onChanged: (v) => setState(() => _opacity = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.isMarked)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(
                context, (action: 'unmark', color: _finalColor)),
            child: const Text('取消标记'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, (action: 'apply', color: _finalColor)),
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _swatch(BuildContext context, int index, Color color) {
    final selected = color.toARGB32() == _baseColor.toARGB32();
    return GestureDetector(
      onTap: () => setState(() => _baseColor = color),
      onLongPress: () => _editPreset(index, color),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  Future<void> _editPreset(int index, Color current) async {
    final picked = await pickColorDialog(context, current);
    if (picked == null || !mounted) return;
    ref.read(browserMarkPresetColorsProvider.notifier).setAt(index, picked);
  }

  Future<void> _pickCustom() async {
    final picked = await pickColorDialog(context, _baseColor);
    if (picked == null || !mounted) return;
    setState(() => _baseColor = picked);
  }
}

String _markColorToHex(Color c) {
  final v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

// ==================== 标记 · 设置弹窗 ====================

class _MarkerSettingsDialog extends ConsumerStatefulWidget {
  const _MarkerSettingsDialog({
    required this.selectedMode,
    required this.onModeChanged,
  });
  final _MarkerMode selectedMode;
  final ValueChanged<_MarkerMode> onModeChanged;

  @override
  ConsumerState<_MarkerSettingsDialog> createState() =>
      _MarkerSettingsDialogState();
}

class _MarkerSettingsDialogState extends ConsumerState<_MarkerSettingsDialog> {
  late _MarkerMode _localMode;

  @override
  void initState() {
    super.initState();
    _localMode = widget.selectedMode;
  }

  @override
  Widget build(BuildContext context) {
    final showPicker = ref.watch(browserMarkShowPickerProvider);
    final defaultColor = ref.watch(browserMarkDefaultColorProvider);
    final opacity = ref.watch(browserMarkDefaultOpacityProvider);
    final presets = ref.watch(browserMarkPresetColorsProvider);
    final s = Theme.of(context).colorScheme;

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: const Text('标记设置'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('标记模式',
                  style: Theme.of(context).textTheme.labelSmall),
              RadioGroup<_MarkerMode>(
                groupValue: _localMode,
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _localMode = v);
                  widget.onModeChanged(v);
                },
                child: Column(
                  children: [
                    RadioListTile<_MarkerMode>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _MarkerMode.exitAfterMark,
                      title: const Text('模式1 · 标后退出'),
                      subtitle: const Text(
                        '点文件标记一个，自动退出标记模式。',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    RadioListTile<_MarkerMode>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _MarkerMode.alwaysOn,
                      title: const Text('模式2 · 常驻标记'),
                      subtitle: const Text(
                        '浏览时点行左侧图标即标记/取消，长按左图标改色；点文件仍正常打开。',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('点击文件时弹颜色面板'),
                subtitle: const Text(
                  '关闭后，未标记的文件点击直接用下面的默认色标记。\n'
                  '已标记的文件始终弹面板，可改色或取消。',
                  style: TextStyle(fontSize: 11),
                ),
                value: showPicker,
                onChanged: (v) => ref
                    .read(browserMarkShowPickerProvider.notifier)
                    .update(v),
              ),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Text('默认颜色',
                  style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    _markColorToHex(defaultColor),
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () async {
                      final picked =
                          await pickColorDialog(context, defaultColor);
                      if (picked != null) {
                        ref
                            .read(browserMarkDefaultColorProvider.notifier)
                            .set(picked);
                      }
                    },
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: defaultColor,
                        border: Border.all(color: s.outline),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '默认不透明度：${(opacity * 100).round()}%',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Slider(
                min: 0.01,
                max: 1.0,
                divisions: 99,
                value: opacity.clamp(0.01, 1.0),
                label: '${(opacity * 100).round()}%',
                onChanged: (v) => ref
                    .read(browserMarkDefaultOpacityProvider.notifier)
                    .set(v),
              ),
              const Divider(height: 24),
              Text('预设色（长按色块修改）',
                  style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < presets.length; i++)
                    GestureDetector(
                      onLongPress: () async {
                        final picked =
                            await pickColorDialog(context, presets[i]);
                        if (picked != null) {
                          ref
                              .read(browserMarkPresetColorsProvider.notifier)
                              .setAt(i, picked);
                        }
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: presets[i],
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black26),
                        ),
                      ),
                    ),
                ],
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
}

// ==================== 文件收藏 · 列表弹窗 ====================

class _FileBookmarksDialog extends ConsumerStatefulWidget {
  const _FileBookmarksDialog({required this.bookmarks});

  final List<String> bookmarks;

  @override
  ConsumerState<_FileBookmarksDialog> createState() =>
      _FileBookmarksDialogState();
}

class _FileBookmarksDialogState
    extends ConsumerState<_FileBookmarksDialog> {
  @override
  Widget build(BuildContext context) {
    final bookmarks = ref.watch(fileBookmarksProvider);
    final mode = ref.watch(browserBookmarkDisplayModeProvider);

    return AlertDialog(
      insetPadding: const EdgeInsets.all(4),
      titlePadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      title: Row(
        children: [
          Expanded(child: Text('文件收藏 (${bookmarks.length})')),
          IconButton(
            icon: const Icon(Icons.tune, size: 20),
            tooltip: '路径显示模式',
            onPressed: () {
              final current = ref.read(browserBookmarkDisplayModeProvider);
              String labelFor(BrowserBookmarkDisplayMode m) {
                switch (m) {
                  case BrowserBookmarkDisplayMode.filenameOnly:
                    return '只显示文件名';
                  case BrowserBookmarkDisplayMode.oneLinePath:
                    return '单行路径（截断）';
                  case BrowserBookmarkDisplayMode.fullPath:
                    return '完整路径（换行）';
                }
              }

              showDialog<void>(
                context: context,
                builder: (c) => SimpleDialog(
                  title: const Text('路径显示模式'),
                  children: BrowserBookmarkDisplayMode.values.map((m) {
                    final sel = m == current;
                    return SimpleDialogOption(
                      onPressed: () {
                        ref
                            .read(browserBookmarkDisplayModeProvider.notifier)
                            .update(m);
                        Navigator.pop(c);
                      },
                      child: Row(
                        children: [
                          Expanded(child: Text(labelFor(m))),
                          if (sel)
                            const Icon(Icons.check, size: 18),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.9,
        child: bookmarks.isEmpty
            ? const Center(child: Text('还没有收藏'))
            : ListView.builder(
                itemCount: bookmarks.length,
                itemBuilder: (ctx, i) {
                  final p = bookmarks[i];
                  final name = p.split('/').last;
                  final exists =
                      FileSystemEntity.typeSync(p) !=
                          FileSystemEntityType.notFound;
                  Widget? subtitle;
                  switch (mode) {
                    case BrowserBookmarkDisplayMode.filenameOnly:
                      subtitle = null;
                    case BrowserBookmarkDisplayMode.oneLinePath:
                      subtitle = Text(
                        p,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      );
                    case BrowserBookmarkDisplayMode.fullPath:
                      subtitle = Text(
                        p,
                        style: const TextStyle(fontSize: 11),
                      );
                  }
                  return ListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: exists ? null : Colors.grey,
                      ),
                    ),
                    subtitle: subtitle,
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: '移除收藏',
                      onPressed: () {
                        ref
                            .read(fileBookmarksProvider.notifier)
                            .remove(p);
                      },
                    ),
                    onTap: exists
                        ? () => Navigator.pop(ctx, p)
                        : () {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(
                                content: Text('文件已不存在'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                  );
                },
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
}

// ==================== 休眠式滚动条 ====================

/// 休眠式滚动条：平时不监听任何东西，只在手指按下时醒一次，
/// 拖完松手立刻睡回去。
///
/// 稳态滚动时：0 次监听、0 次重建、0 次重绘。
/// 按下时：读一次 .value，显示滑块。
/// 拖动时：靠手势位移自己算，jumpTo 节流 30ms。
class _BrowserScrollbar extends ConsumerStatefulWidget {
  const _BrowserScrollbar({
    required this.positionsListenable,
    required this.itemScrollController,
    required this.totalRows,
  });

  final ValueListenable<Iterable<ItemPosition>> positionsListenable;
  final ItemScrollController itemScrollController;
  final int Function() totalRows;

  @override
  ConsumerState<_BrowserScrollbar> createState() =>
      _BrowserScrollbarState();
}

class _BrowserScrollbarState extends ConsumerState<_BrowserScrollbar> {
  /// 拖动中的滑块位置（0~1）。null = 休眠。
  double? _dragFraction;

  double _dragStartY = 0;
  double _dragStartFraction = 0;
  double _dragVisibleRatio = 0.2;

  DateTime _lastJumpTime = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastJumpedIndex = -1;

  /// 只在下按时调用一次。读一次 .value，不订阅。
  ({double fraction, double visibleRatio})? _readSnapshot(int total) {
    if (total <= 1) return null;
    final positions = widget.positionsListenable.value;
    if (positions.isEmpty) return null;
    var minIdx = 1 << 30;
    var maxIdx = -1;
    for (final p in positions) {
      if (p.index < minIdx) minIdx = p.index;
      if (p.index > maxIdx) maxIdx = p.index;
    }
    if (minIdx > maxIdx) return null;
    return (
      fraction: (minIdx / (total - 1)).clamp(0.0, 1.0),
      visibleRatio: ((maxIdx - minIdx + 1) / total).clamp(0.05, 1.0),
    );
  }

  void _onDragStart(DragStartDetails d, int total, double trackHeight) {
    final snap = _readSnapshot(total);
    if (snap == null) return;

    final thumbH =
        (trackHeight * snap.visibleRatio).clamp(24.0, trackHeight);
    final usable = trackHeight - thumbH;
    if (usable <= 0) return;

    final localY = d.localPosition.dy;
    final currentThumbTop = usable * snap.fraction;
    final tolerance = thumbH * 0.5;
    final onThumb = localY >= currentThumbTop - tolerance &&
        localY <= currentThumbTop + thumbH + tolerance;

    double startFraction;
    if (onThumb) {
      startFraction = snap.fraction;
    } else {
      startFraction =
          ((localY - thumbH / 2) / usable).clamp(0.0, 1.0);
    }

    _dragStartY = localY;
    _dragStartFraction = startFraction;
    _dragVisibleRatio = snap.visibleRatio;
    _lastJumpedIndex = -1;

    setState(() => _dragFraction = startFraction);

    if (!onThumb) {
      _jumpToFraction(startFraction, total);
    }
  }

  void _onDragUpdate(
      DragUpdateDetails d, int total, double trackHeight) {
    if (_dragFraction == null) return;
    final thumbH =
        (trackHeight * _dragVisibleRatio).clamp(24.0, trackHeight);
    final usable = trackHeight - thumbH;
    if (usable <= 0) return;

    final dy = d.localPosition.dy - _dragStartY;
    final next =
        (_dragStartFraction + dy / usable).clamp(0.0, 1.0);
    if ((next - _dragFraction!).abs() < 0.0005) return;
    setState(() => _dragFraction = next);
    _jumpToFraction(next, total);
  }

  void _onDragEnd(int total) {
    if (_dragFraction == null) return;
    final fraction = _dragFraction!;
    setState(() => _dragFraction = null);
    _jumpToFraction(fraction, total);
  }

  void _jumpToFraction(double fraction, int total) {
    final now = DateTime.now();
    if (now.difference(_lastJumpTime).inMilliseconds < 30) return;
    _lastJumpTime = now;

    final idx = (fraction * (total - 1)).round().clamp(0, total - 1);
    if (idx == _lastJumpedIndex) return;
    _lastJumpedIndex = idx;
    if (widget.itemScrollController.isAttached) {
      widget.itemScrollController.jumpTo(index: idx);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trackColor = ref.watch(browserScrollbarTrackColorProvider);
    final trackOpacity = ref.watch(browserScrollbarTrackOpacityProvider);
    final thumbColor = ref.watch(browserScrollbarThumbColorProvider);
    final thumbOpacity = ref.watch(browserScrollbarThumbOpacityProvider);
    final total = widget.totalRows();
    if (total <= 1) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final trackHeight = constraints.maxHeight;
        if (trackHeight <= 0) return const SizedBox.shrink();

        final dragging = _dragFraction != null;
        final thumbH =
            (trackHeight * _dragVisibleRatio).clamp(24.0, trackHeight);
        final thumbTop = dragging
            ? ((trackHeight - thumbH) * _dragFraction!)
                .clamp(0.0, trackHeight - thumbH)
            : 0.0;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) => _onDragStart(d, total, trackHeight),
          onVerticalDragUpdate: (d) =>
              _onDragUpdate(d, total, trackHeight),
          onVerticalDragEnd: (_) => _onDragEnd(total),
          onVerticalDragCancel: () => _onDragEnd(total),
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: trackColor.withValues(alpha: trackOpacity),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
              if (dragging)
                Positioned(
                  top: thumbTop,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: thumbH,
                    decoration: BoxDecoration(
                      color: thumbColor.withValues(alpha: thumbOpacity),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ==================== 文件浏览器翻页按钮 ====================

class _BrowserPageButton extends StatelessWidget {
  const _BrowserPageButton({
    required this.icon,
    required this.size,
    required this.color,
    required this.opacity,
    required this.isSquare,
    required this.onPressed,
  });

  final IconData icon;
  final double size;
  final Color color;
  final double opacity;
  final bool isSquare;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color.withValues(alpha: opacity.clamp(0.0, 1.0));
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Material(
        color: effectiveColor,
        shape: isSquare
            ? const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)))
            : const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: isSquare
              ? const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8)))
              : const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              color: Colors.black87,
              size: size * 0.55,
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 搜索设置弹窗用的小部件 ====================

class _SearchSettingsSectionTitle extends StatelessWidget {
  const _SearchSettingsSectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// "圆圈里带圆点"的单选标记。
class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected, required this.color});

  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? color : Colors.grey,
          width: 2,
        ),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
            )
          : null,
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
      insetPadding: const EdgeInsets.all(4),
      titlePadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      actionsPadding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      title: Text('删除 $n 项？'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 各项统计：最多占 40% 屏幕高度，超出滚动
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.4,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: lines,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            // 底部统计：固定，永远可见
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
              style: const TextStyle(fontSize: 13, color: Colors.red),
            ),
          ],
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

/// 收藏按钮：空心纸 + 右上角三角护套 + 左上角实心钻石（单态不变）。
class _BookmarkGemIcon extends StatelessWidget {
  const _BookmarkGemIcon({this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconTheme(
      data: IconTheme.of(context),
      child: CustomPaint(
        size: Size(size, size),
        painter: _BookmarkGemPainter(
          color: IconTheme.of(context).color ??
              Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _BookmarkGemPainter extends CustomPainter {
  _BookmarkGemPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillGem = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // 空心纸（近似书签形状，顶部微斜）
    final paper = Path()
      ..moveTo(5.5, 4)
      ..lineTo(17.5, 4)
      ..lineTo(17.5, 20.5)
      ..lineTo(11.5, 16)
      ..lineTo(5.5, 20.5)
      ..close();
    canvas.drawPath(paper, stroke);

    // 右上角三角护套（装饰）
    final cap = Path()
      ..moveTo(13.5, 4)
      ..lineTo(17.5, 4)
      ..lineTo(17.5, 9)
      ..close();
    canvas.drawPath(cap, stroke);

    // 左上角实心钻石
    final gem = Path()
      ..moveTo(8.5, 5.5)
      ..lineTo(10.5, 8.0)
      ..lineTo(8.5, 10.5)
      ..lineTo(6.5, 8.0)
      ..close();
    canvas.drawPath(gem, fillGem);
  }

  @override
  bool shouldRepaint(_BookmarkGemPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 标记模式三态。
enum _MarkerMode {
  /// 未激活任何标记功能。
  off,

  /// 标后退出模式：点文件标记一个，自动退出。
  /// 顶栏浅黄，画笔实心+烟花+❶。
  exitAfterMark,

  /// 常驻标记模式：左图标区点一下=标记/取消，长按=改色；浏览正常。
  /// 顶栏不变色，画笔实心+星尘+❷。
  alwaysOn,
}

/// 标记画笔图标。
///
/// 三态共用同一支 Material 画笔（Icons.brush / brush_outlined），
/// 通过装饰（烟花/星尘）和角标❶❷区分状态。
class _MarkerBrushIcon extends StatelessWidget {
  const _MarkerBrushIcon({required this.mode});
  final _MarkerMode mode;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    final isActivated = mode != _MarkerMode.off;
    final painter = mode == _MarkerMode.off
        ? null
        : _FireworkPainter(color: color);
    final badge = mode == _MarkerMode.exitAfterMark
        ? const _MarkerBadge('1')
        : mode == _MarkerMode.alwaysOn
            ? const _MarkerBadge('2')
            : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(
              isActivated ? Icons.brush : Icons.brush_outlined,
              size: 21,
              color: color,
            ),
            if (painter != null)
              Positioned(
                left: -2,
                top: -1,
                child: CustomPaint(
                  size: const Size(12, 12),
                  painter: painter,
                ),
              ),
            if (badge != null)
              Positioned(
                right: -4,
                top: -2,
                child: badge,
              ),
          ],
        ),
        const SizedBox(height: 1.5),
        Container(
          width: 20,
          height: isActivated ? 3.0 : 1.5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
      ],
    );
  }
}

/// 角标：左下角的 ❶ 或 ❷。
class _MarkerBadge extends StatelessWidget {
  const _MarkerBadge(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    // 角标底色反色，保证在任何顶栏上都清晰
    final bg = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final fg = bg == Colors.white ? Colors.black : Colors.white;
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          color: fg,
          height: 1.0,
        ),
      ),
    );
  }
}

/// 未激活 / 常驻模式用：三颗渐小圆点（星辰尾迹）。
class _StardustPainter extends CustomPainter {
  _StardustPainter({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    // 按 12×12 画布，star 位置大致对应原坐标
    final scale = size.width / 12;
    canvas.save();
    canvas.translate(0, 0);
    canvas.scale(scale);
    // 中心 + 右下两颗渐小
    canvas.drawCircle(const Offset(6, 7), 1.0, paint);
    canvas.drawCircle(const Offset(8.5, 4.5), 0.7, paint);
    canvas.drawCircle(const Offset(4, 4.5), 0.5, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StardustPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 模式1 激活用：中心点 + 八向放射线（迷你烟花）。
class _FireworkPainter extends CustomPainter {
  _FireworkPainter({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    const cx = 6.0, cy = 6.0;
    canvas.drawCircle(const Offset(cx, cy), 1.2, fill);
    for (final a in [0, 45, 90, 135, 180, 225, 270, 315]) {
      final rad = a * 3.14159265 / 180;
      canvas.drawLine(
        Offset(cx + 2.0 * math.cos(rad), cy + 2.0 * math.sin(rad)),
        Offset(cx + 4.5 * math.cos(rad), cy + 4.5 * math.sin(rad)),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_FireworkPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 搜索框收起/显示的自定义图标（双层折叠放大镜 + 镜内箭头尖）。
///
/// [collapsed] = true：双层镜片叠在一起（大镜片 + 斜下方半透明小镜片），
///   镜内箭头尖朝上 —— 表示搜索框收起来了，点击可展开。
/// [collapsed] = false：标准放大镜轮廓，镜内箭头尖朝下 ——
///   表示搜索框正展开着，点击可收起。
class _SearchToggleIconPainter extends CustomPainter {
  _SearchToggleIconPainter({required this.collapsed, required this.color});

  final bool collapsed;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 按 24×24 设计稿等比缩放
    canvas.scale(size.width / 24);

    if (collapsed) {
      // ---- 收起态：两层镜片叠在一起 ----
      // 上层大镜片
      canvas.drawCircle(const Offset(9.5, 9.5), 5.0, paint);

      // 下层小镜片：向右下偏移且半透明，形成「折叠的层级感」
      final lower = Paint()
        ..color = color.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawCircle(const Offset(14.2, 14.2), 3.4, lower);

      // 镜柄
      canvas.drawLine(
          const Offset(17.2, 17.2), const Offset(20.4, 20.4), paint);

      // 镜内箭头尖：朝上（点击展开）
      canvas.drawPath(
        Path()
          ..moveTo(8.2, 10.6)
          ..lineTo(9.5, 8.8)
          ..lineTo(10.8, 10.6),
        paint,
      );
    } else {
      // ---- 展开态：标准放大镜轮廓 + 镜内箭头尖朝下 ----
      canvas.drawCircle(const Offset(10.5, 10.5), 6.0, paint);
      canvas.drawLine(
          const Offset(14.8, 14.8), const Offset(18.2, 18.2), paint);
      canvas.drawPath(
        Path()
          ..moveTo(8.0, 9.5)
          ..lineTo(10.5, 12.0)
          ..lineTo(13.0, 9.5),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SearchToggleIconPainter oldDelegate) =>
      oldDelegate.collapsed != collapsed || oldDelegate.color != color;
}
