import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../parser/application/document_parser.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../viewer/presentation/diff_viewer_screen.dart';
import 'comparison_settings_screen.dart';

import 'text_preview_screen.dart';

/// 文件浏览器：首页。
///
/// 交互：
///   - 点击文件夹 → 进入
///   - 点击文件 → 预览
///   - 长按任意项 → 进入多选
///   - 多选模式下单击 → 勾选/取消
///   - 选中 2 个文件 → 底部"对比"主按钮
///   - 选中 1+ 项 → 底部"重命名/移动/复制/删除"按钮
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

  // ---------- 对比 ----------

  Future<void> _startCompare() async {
    if (_selectedPaths.length != 2) return;
    final paths = _selectedPaths.toList();

    // 检查两个都是文件（不是文件夹）。
    for (final p in paths) {
      if (Directory(p).existsSync()) {
        _toast('对比只支持文件，请勿选中文件夹');
        return;
      }
    }

    // 不再弹角色确认框，默认 paths[0] 是原文件、paths[1] 是修改版。
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

  // ---------- 文件操作 ----------

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
    if (newName == null || newName.isEmpty || newName == oldName) return;

    final parent = File(oldPath).parent.path;
    final newPath = '$parent/$newName';

    if (FileSystemEntity.typeSync(newPath) != FileSystemEntityType.notFound) {
      _toast('目标已存在：$newName');
      return;
    }

    try {
      if (Directory(oldPath).existsSync()) {
        await Directory(oldPath).rename(newPath);
      } else {
        await File(oldPath).rename(newPath);
      }
      _clearSelection();
      _load();
      _toast('已重命名为 $newName');
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
    _clearSelection();
    _load();
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
    _clearSelection();
    _load();
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

    var deleted = 0;
    var fail = 0;
    for (final p in _selectedPaths.toList()) {
      try {
        if (Directory(p).existsSync()) {
          await Directory(p).delete(recursive: true);
        } else {
          await File(p).delete();
        }
        deleted++;
      } catch (_) {
        fail++;
      }
    }
    _clearSelection();
    _load();
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
    if (name == null || name.trim().isEmpty) return;

    final path = '$_currentPath/${name.trim()}';
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      _toast('同名文件或文件夹已存在');
      return;
    }
    try {
      await Directory(path).create();
      _load();
      _toast('已新建 ${name.trim()}');
    } catch (e) {
      _toast('新建失败：$e');
    }
  }

  /// 弹一个只显示目录的选择器。用户选中一个目录，返回它的路径。
  Future<String?> _pickDirectory(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _DirectoryPickerDialog(
        title: title,
        rootPath: _rootPath,
        initialPath: _currentPath,
      ),
    );
  }

  // ---------- 面包屑 ----------

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
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton(
                tooltip: '新建文件夹',
                onPressed: _newFolder,
                child: const Icon(Icons.create_new_folder),
              ),
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

  /// 底部栏：根据选中数量动态显示按钮。
  /// - 选中 2 个 → 显示"对比"主按钮 + 操作按钮
  /// - 其它数量 → 只显示操作按钮
  Widget _buildBottomBar() {
    final n = _selectedPaths.length;
    final canCompare = n == 2;

    // 操作按钮（重命名只在单选时可用）
    final canRename = n == 1;

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
        child: Row(
          children: [
            if (canCompare)
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.compare_arrows),
                  label: const Text('对比'),
                  onPressed: _startCompare,
                ),
              )
            else
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    n == 1 ? '选中 2 个文件可对比' : '已选 $n 项',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            _actionButton(
              icon: Icons.drive_file_rename_outline,
              tooltip: '重命名',
              onPressed: canRename ? _rename : null,
            ),
            _actionButton(
              icon: Icons.drive_file_move_outline,
              tooltip: '移动',
              onPressed: n >= 1 ? _move : null,
            ),
            _actionButton(
              icon: Icons.copy_all_outlined,
              tooltip: '复制',
              onPressed: n >= 1 ? _copy : null,
            ),
            _actionButton(
              icon: Icons.delete_outline,
              tooltip: '删除',
              color: Colors.red,
              onPressed: n >= 1 ? _delete : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: tooltip,
      onPressed: onPressed,
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
          selected: selected,
          selectedTileColor:
              Theme.of(context).colorScheme.primary.withOpacity(0.12),
          leading: _selectionMode
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
              _toggleSelection(e);
              return;
            }
            if (info.isDir) {
              _navigateTo(e.path);
            } else {
              _openPreview(info);
            }
          },
          onLongPress: () => _toggleSelection(e),
        );
      },
    );
  }
}

// ---------- 辅助 Widget ----------

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

/// 只显示目录的路径选择器。用于"移动到 / 复制到"。
class _DirectoryPickerDialog extends StatefulWidget {
  const _DirectoryPickerDialog({
    required this.title,
    required this.rootPath,
    required this.initialPath,
  });

  final String title;
  final String rootPath;
  final String initialPath;

  @override
  State<_DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends State<_DirectoryPickerDialog> {
  late String _path;
  List<Directory> _dirs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
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

  @override
  Widget build(BuildContext context) {
    final relPath = _path == widget.rootPath
        ? '~/'
        : '~${_path.substring(widget.rootPath.length)}';

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: _canGoUp ? _goUp : null,
                  tooltip: '上一级',
                ),
                Expanded(
                  child: Text(
                    relPath,
                    style: Theme.of(context).textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
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
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.folder,
                                  color: Colors.amber),
                              title: Text(name),
                              onTap: () {
                                setState(() => _path = d.path);
                                _load();
                              },
                            );
                          },
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
          onPressed: () => Navigator.pop(context, _path),
          child: const Text('选这个目录'),
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
