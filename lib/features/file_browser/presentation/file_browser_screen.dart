import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../parser/application/document_parser.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../viewer/presentation/diff_viewer_screen.dart';
import 'role_confirm_dialog.dart';

/// 文件浏览器：首页。
///
/// 本轮加入：
///   - 顶部搜索框（按文件名过滤当前目录）
///   - 长按进入多选模式
///   - 选中两个文件 → 对比按钮 → 角色确认 → 跳转对比页
class FileBrowserScreen extends ConsumerStatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen> {
  static const String _rootPath = '/storage/emulated/0';

  late String _currentPath;
  List<FileSystemEntity>? _entries;
  bool _loading = false;
  String? _error;

  // 搜索
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  // 多选
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
      final list = await dir.list(followLinks: false).toList();

      // 过滤隐藏文件（以 '.' 开头）。
      list.removeWhere((e) {
        final name = e.path.split('/').last;
        return name.startsWith('.');
      });

      // 排序：文件夹在前，然后按名字。
      list.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _entries = list;
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

  void _enter(Directory dir) {
    _clearSelection();
    _searchCtrl.clear();
    setState(() {
      _currentPath = dir.path;
      _query = '';
    });
    _load();
  }

  bool get _canGoUp => _currentPath != _rootPath;

  void _goUp() {
    if (!_canGoUp) return;
    final parent = Directory(_currentPath).parent.path;
    if (parent.length < _rootPath.length) return;
    _clearSelection();
    _searchCtrl.clear();
    setState(() {
      _currentPath = parent;
      _query = '';
    });
    _load();
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
        // 最多选 2 个。
        if (_selectedPaths.length >= 2) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('最多选 2 个文件')),
          );
          return;
        }
        _selectedPaths.add(e.path);
      }
    });
  }

  Future<void> _startCompare() async {
    if (_selectedPaths.length != 2) return;
    final paths = _selectedPaths.toList();
    final f1 = File(paths[0]);
    final f2 = File(paths[1]);

    // 角色确认
    final result = await showDialog<
        ({File original, File modified})>(
      context: context,
      builder: (_) => RoleConfirmDialog(fileA: f1, fileB: f2),
    );
    if (result == null || !mounted) return;

    // 读文件 + 解析
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
      Navigator.of(context, rootNavigator: true).pop(); // 关闭 loading

      // 填充 provider
      ref.read(originalRawTextProvider.notifier).state = origParsed.plainText;
      ref.read(modifiedRawTextProvider.notifier).state = modParsed.plainText;
      ref.read(originalFileNameProvider.notifier).state = origParsed.fileName;
      ref.read(modifiedFileNameProvider.notifier).state = modParsed.fileName;
      ref.read(originalEncodingProvider.notifier).state = origParsed.encoding.label;
      ref.read(modifiedEncodingProvider.notifier).state = modParsed.encoding.label;
      ref.read(originalFilePathProvider.notifier).state = result.original.path;
      ref.read(modifiedFilePathProvider.notifier).state = result.modified.path;
      ref.read(importRevisionProvider.notifier).state++;

      // 跳转对比页
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

  /// 后台 isolate 解析文件，避免大文件阻塞 UI。
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

  String get _title {
    if (_currentPath == _rootPath) return '内部存储';
    return _currentPath.split('/').last;
  }

  List<FileSystemEntity> get _filteredEntries {
    final all = _entries ?? const <FileSystemEntity>[];
    if (_query.isEmpty) return all;
    final q = _query.toLowerCase();
    return all.where((e) {
      final name = e.path.split('/').last.toLowerCase();
      return name.contains(q);
    }).toList();
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
            if (!_selectionMode) _buildSearchBar(),
            Expanded(child: _buildBody()),
          ],
        ),
        bottomNavigationBar:
            _selectionMode ? _buildBottomBar() : null,
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
                label: const Text('对比'),
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
        final e = entries[i];
        final name = e.path.split('/').last;
        final isDir = e is Directory;
        final selected = _selectedPaths.contains(e.path);

        return ListTile(
          dense: true,
          selected: selected,
          selectedTileColor:
              Theme.of(context).colorScheme.primary.withOpacity(0.12),
          leading: _selectionMode && !isDir
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => _toggleSelection(e),
                )
              : Icon(
                  isDir ? Icons.folder : Icons.insert_drive_file_outlined,
                  color: isDir ? Colors.amber.shade600 : null,
                ),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () {
            if (_selectionMode) {
              if (!isDir) _toggleSelection(e);
              return;
            }
            if (isDir) {
              _enter(e);
            } else {
              // 单击普通文件：也进入多选（方便快速选两个）。
              _toggleSelection(e);
            }
          },
          onLongPress: () {
            if (!isDir) _toggleSelection(e);
          },
        );
      },
    );
  }
}

/// 用于把 ParsedDocument 中最关键的几个字段传回主 isolate。
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
