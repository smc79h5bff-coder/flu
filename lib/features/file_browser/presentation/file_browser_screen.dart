import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../parser/application/document_parser.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../viewer/presentation/diff_viewer_screen.dart';
import 'role_confirm_dialog.dart';
import 'text_preview_screen.dart';

/// 文件浏览器：首页。
///
/// 交互：
///   - 点击文件夹 → 进入
///   - 点击文件 → 预览（TextPreviewScreen）
///   - 长按文件 → 进入多选
///   - 多选模式下单击 → 勾选/取消
///   - 选中 2 个文件 → 底部"对比"按钮
class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

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

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen> {
  static const String _rootPath = '/storage/emulated/0';

  late String _currentPath;
  List<_EntryInfo>? _entries;
  bool _loading = false;
  String? _error;

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  bool _selectionMode = false;
  final Set<String> _selectedPaths = <String>{};

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
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
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
    setState(() {
      _currentPath = path;
      _query = '';
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

  Future<void> _startCompare() async {
    if (_selectedPaths.length != 2) return;
    final paths = _selectedPaths.toList();
    final f1 = File(paths[0]);
    final f2 = File(paths[1]);

    final result = await showDialog<({File original, File modified})>(
      context: context,
      builder: (_) => RoleConfirmDialog(fileA: f1, fileB: f2),
    );
    if (result == null || !mounted) return;

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
      ref.read(originalEncodingProvider.notifier).state = origParsed.encodingLabel;
      ref.read(modifiedEncodingProvider.notifier).state = modParsed.encodingLabel;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取文件失败：$e')),
      );
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
                fontSize: 13,
                color: isLast ? s.onSurface : s.primary,
                fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      color: s.surfaceVariant.withOpacity(0.4),
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

  List<_EntryInfo> get _filteredEntries {
    final all = _entries ?? const <_EntryInfo>[];
    if (_query.isEmpty) return all;
    final q = _query.toLowerCase();
    return all.where((e) => e.name.toLowerCase().contains(q)).toList();
  }

  /// 用于副标题第三行的相对路径。根目录 -> `~/`，其它 -> `~/Download/...`。
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
      canPop: !_canGoUp && !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectionMode) {
          setState(_clearSelection);
        } else if (_canGoUp) {
          _goUp();
        }
      },
      child: Scaffold(
        appBar: _selectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
        body: Column(
          children: [
            if (!_selectionMode) _buildBreadcrumbs(),
            if (!_selectionMode) _buildSearchBar(),
            Expanded(child: _buildBody()),
          ],
        ),
        bottomNavigationBar: _selectionMode ? _buildBottomBar() : null,
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar() {
    return AppBar(
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
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => setState(_clearSelection),
      ),
      title: Text('已选 ${_selectedPaths.length} 个'),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchCtrl,
        decoration: InputDecoration(
          hintText: '搜索当前目录下的文件',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
    );
  }

  Widget _buildBottomBar() {
    final canCompare = _selectedPaths.length == 2;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.compare_arrows),
                label: Text(
                  canCompare ? '对比' : '选择两个文件后对比（已选 ${_selectedPaths.length}）',
                ),
                onPressed: canCompare ? _startCompare : null,
              ),
            ),
          ],
        ),
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
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final entries = _filteredEntries;
    if (entries.isEmpty) {
      return Center(
        child: Text(_query.isEmpty ? '空目录' : '没有匹配的文件'),
      );
    }

    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (ctx, i) {
        final info = entries[i];
        final e = info.entity;
        final selected = _selectedPaths.contains(e.path);

        // 三行布局：
        //   标题：文件名
        //   副标题1：大小 · 时间（文件夹则只显示时间）
        //   副标题2：完整相对路径
        final String metaLine;
        if (info.isDir) {
          metaLine = _formatTime(info.modified);
        } else {
          final size = _formatSize(info.size);
          final time = _formatTime(info.modified);
          metaLine = [size, time].where((s) => s.isNotEmpty).join(' · ');
        }
        final relPath = _relPath(e.path);

        return ListTile(
          isThreeLine: true,
          dense: false,
          selected: selected,
          selectedTileColor:
              Theme.of(context).colorScheme.primary.withOpacity(0.12),
          leading: _selectionMode && !info.isDir
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => _toggleSelection(e),
                )
              : Icon(
                  info.isDir
                      ? Icons.folder
                      : Icons.insert_drive_file_outlined,
                  color: info.isDir ? Colors.amber.shade600 : null,
                ),
          title: Text(
            info.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
              Text(
                relPath,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          onTap: () {
            if (_selectionMode) {
              if (!info.isDir) _toggleSelection(e);
              return;
            }
            if (info.isDir) {
              _navigateTo(e.path);
            } else {
              _openPreview(info);
            }
          },
          onLongPress: () {
            if (!info.isDir) _toggleSelection(e);
          },
        );
      },
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
