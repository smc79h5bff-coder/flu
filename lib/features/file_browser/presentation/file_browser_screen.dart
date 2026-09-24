import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../parser/application/document_parser.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../viewer/presentation/diff_viewer_screen.dart';
import 'comparison_settings_screen.dart';
import 'text_preview_screen.dart';

class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

enum _SortField { name, modified, size }

enum _SearchScope { currentRecursive, custom }

class _EntryInfo {
  _EntryInfo({
    required this.entity,
    required this.name,
    required this.isDir,
    this.size,
    this.modified,
  });

  final FileSystemEntity entity;
  final String name;
  final bool isDir;
  final int? size;
  final DateTime? modified;
}

class _SearchHit {
  const _SearchHit({required this.path, required this.name});
  final String path;
  final String name;
}

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen> {
  static const String _rootPath = '/storage/emulated/0';

  late String _currentPath;
  List<_EntryInfo>? _entries;
  bool _loading = false;
  String? _error;

  final TextEditingController _searchCtrl = TextEditingController();

  bool _selectionMode = false;
  final Set<String> _selectedPaths = <String>{};

  _SortField _sortField = _SortField.name;
  bool _sortAsc = true;

  final List<String> _favorites = <String>[];

  // ===== 搜索相关 =====
  _SearchScope _searchScope = _SearchScope.currentRecursive;
  final List<String> _customSearchFolders = <String>[];
  List<_SearchHit> _searchResults = <_SearchHit>[];
  bool _searching = false;
  int _searchTaskId = 0;
  DateTime _lastUiRefresh = DateTime.now();
  bool _searchActive = false;

  @override
  void initState() {
    super.initState();
    _currentPath = _rootPath;
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dir = Directory(_currentPath);
      final raw = await dir.list(followLinks: false).toList();

      raw.removeWhere((e) {
        final name = e.path.split('/').last;
        return name.startsWith('.');
      });

      final infos = await Future.wait(raw.map((e) async {
        final name = e.path.split('/').last;
        final isDir = e is Directory;
        int? size;
        DateTime? modified;
        try {
          final st = await e.stat();
          modified = st.modified;
          if (!isDir) size = st.size;
        } catch (_) {
          // 忽略
        }
        return _EntryInfo(
          entity: e,
          name: name,
          isDir: isDir,
          size: size,
          modified: modified,
        );
      }));

      infos.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        int cmp;
        switch (_sortField) {
          case _SortField.name:
            cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          case _SortField.modified:
            final at = a.modified?.millisecondsSinceEpoch ?? 0;
            final bt = b.modified?.millisecondsSinceEpoch ?? 0;
            cmp = at.compareTo(bt);
          case _SortField.size:
            final as = a.size ?? 0;
            final bs = b.size ?? 0;
            cmp = as.compareTo(bs);
        }
        return _sortAsc ? cmp : -cmp;
      });

      if (!mounted) return;
      setState(() {
        _entries = infos;
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

  void _navigateTo(String path) {
    if (path == _currentPath) return;
    _clearSelection();
    _searchCtrl.clear();
    _searchTaskId++; // 停掉正在跑的搜索
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
  }

  void _toggleSelection(FileSystemEntity e) {
    setState(() {
      _selectionMode = true;
      if (_selectedPaths.contains(e.path)) {
        _selectedPaths.remove(e.path);
        if (_selectedPaths.isEmpty) _selectionMode = false;
      } else {
        _selectedPaths.add(e.path);
      }
    });
  }

  void _openPreview(_EntryInfo info) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TextPreviewScreen(
          filePath: info.entity.path,
          fileName: info.name,
        ),
      ),
    );
  }

  // ==================== 搜索 ====================

  /// 输入变化：只刷新 UI（让清空按钮显隐），不启动搜索。
  void _onSearchChanged(String v) {
    setState(() {});
  }

  /// 用户点"搜索"按钮或回车时触发。
  void _doSearch() {
    final q = _searchCtrl.text;
    if (q.isEmpty) return;
    setState(() => _searchActive = true);
    _startSearch(q);
  }

  void _clearSearch() {
    _searchTaskId++;
    _searchCtrl.clear();
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

  /// 去掉被父目录覆盖的子目录。
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

    final roots = <String>[];
    if (_searchScope == _SearchScope.currentRecursive) {
      roots.add(_currentPath);
    } else {
      if (_customSearchFolders.isEmpty) {
        _toast('请先长按搜索图标设置搜索范围');
        if (mounted) setState(() => _searching = false);
        return;
      }
      roots.addAll(_dedupFolders(_customSearchFolders));
    }

    final lowerQuery = query.toLowerCase();
    final results = <_SearchHit>[];

    for (final root in roots) {
      if (taskId != _searchTaskId) return;
      await _scanDir(root, lowerQuery, results, taskId);
    }

    if (taskId != _searchTaskId) return;
    if (!mounted) return;
    setState(() => _searching = false);
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
            results.add(_SearchHit(path: e.path, name: name));
            final now = DateTime.now();
            if (mounted &&
                now.difference(_lastUiRefresh).inMilliseconds > 100) {
              _lastUiRefresh = now;
              setState(() => _searchResults = List.from(results));
            }
          }
        }
      }
    } catch (_) {
      // 权限不够或目录读取失败，忽略，继续
    }
  }

  Future<void> _showSearchFolderPicker() async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _SearchFolderPickerDialog(
        rootPath: _rootPath,
        initialPath: _currentPath,
        initialSelected: _customSearchFolders,
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _customSearchFolders
          ..clear()
          ..addAll(result);
      });
      if (_searchActive && _searchCtrl.text.isNotEmpty) {
        _startSearch(_searchCtrl.text);
      }
    }
  }

  /// 长按搜索图标：弹范围菜单。
  Future<void> _showSearchScopeMenu(BuildContext anchorContext) async {
    final box = anchorContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay =
        Overlay.of(anchorContext).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final isCustom = _searchScope == _SearchScope.custom;
    final result = await showMenu<String>(
      context: anchorContext,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(box.size.bottomRight(Offset.zero),
              ancestor: overlay),
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        CheckedPopupMenuItem<String>(
          value: 'current',
          checked: _searchScope == _SearchScope.currentRecursive,
          child: const Text('当前目录及子目录'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'custom',
          checked: _searchScope == _SearchScope.custom,
          child: Text('自定义范围（${_customSearchFolders.length}）'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'manage',
          enabled: isCustom,
          child: const Row(
            children: [
              Icon(Icons.edit_location_alt, size: 18),
              SizedBox(width: 8),
              Text('管理已勾选文件夹'),
            ],
          ),
        ),
      ],
    );

    if (result == null || !mounted) return;
    if (result == 'current') {
      setState(() => _searchScope = _SearchScope.currentRecursive);
      if (_searchActive && _searchCtrl.text.isNotEmpty) {
        _startSearch(_searchCtrl.text);
      }
    } else if (result == 'custom') {
      setState(() => _searchScope = _SearchScope.custom);
      if (_searchActive && _searchCtrl.text.isNotEmpty) {
        _startSearch(_searchCtrl.text);
      }
    } else if (result == 'manage') {
      _showSearchFolderPicker();
    }
  }

  // ==================== 对比 / MD5 / 属性 ====================

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

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const DiffViewerScreen(),
        ),
      );
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
          title: const Text('MD5 对比'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name1,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                SelectableText(
                  h1,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 14),
                Text(name2,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
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
    } catch (_) {
      // 忽略
    }

    if (!mounted) return;

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

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('属性'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row('名称', name),
              row('路径', path),
              row('类型', isDir ? '文件夹' : '文件'),
              row('大小',
                  isDir ? '—' : (size == null ? '—' : _formatSize(size))),
              if (modified != null) row('修改时间', _formatTimeFull(modified)),
              if (accessed != null) row('访问时间', _formatTimeFull(accessed)),
            ],
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

  static String _formatTimeFull(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // ==================== 排序 / 收藏 ====================

  String _sortLabel(_SortField f) {
    switch (f) {
      case _SortField.name:
        return '名称';
      case _SortField.modified:
        return '修改时间';
      case _SortField.size:
        return '大小';
    }
  }

  Future<void> _showSortDialog() async {
    var tmpField = _sortField
