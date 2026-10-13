import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

// ==================== 词库管理 ====================

class TranslationTable {
  TranslationTable._();
  static final TranslationTable instance = TranslationTable._();

  static const String _assetPath = 'assets/t2s.txt';
  static const String _userFileName = 'opencc_t2s.txt';

  File? _file;
  bool _initialized = false;

  Map<String, String> _dict = const {};
  Map<String, String> get dict => _dict;

  int _maxKeyLen = 1;
  int get maxKeyLen => _maxKeyLen;

  List<String> _lines = const [];
  List<String> get lines => _lines;

  /// 首次：把 assets 里的 t2s.txt 复制到应用文档目录。
  /// 之后所有读写都在那个文件上，assets 不再动。
  ///
  /// 注意：如果手机里已有文件但太小（<100 字节），视为空文件，重新复制。
  /// 目的：防止旧版本遗留的空文件挡住新词库。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/$_userFileName');

    bool needCopy = true;
    if (await _file!.exists()) {
      final len = await _file!.length();
      if (len > 100) needCopy = false;
    }

    if (needCopy) {
      try {
        final raw = await rootBundle.loadString(_assetPath);
        await _file!.writeAsString(raw, flush: true);
      } catch (e) {
        debugPrint('加载内置词库失败：$e');
        return;
      }
    }

    await reload();
  }

  Future<void> reload() async {
    if (_file == null) return;
    try {
      final raw = await _file!.readAsString();
      _lines = raw.split('\n');
      _parse();
    } catch (e) {
      debugPrint('重载词库失败：$e');
    }
  }

  Future<void> saveLines(List<String> lines) async {
    if (_file == null) return;
    _lines = List<String>.from(lines);
    _parse();
    await _file!.writeAsString(_lines.join('\n'), flush: true);
  }

  void _parse() {
    final dict = <String, String>{};
    var maxLen = 1;
    for (final line in _lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final eq = t.indexOf('=');
      if (eq <= 0) continue;
      final key = t.substring(0, eq).trim();
      final val = t.substring(eq + 1).trim();
      if (key.isEmpty) continue;
      dict[key] = val;
      if (key.length > maxLen) maxLen = key.length;
    }
    _dict = dict;
    _maxKeyLen = maxLen;
  }

  Future<void> resetToDefault() async {
    if (_file == null) return;
    try {
      if (await _file!.exists()) await _file!.delete();
      final raw = await rootBundle.loadString(_assetPath);
      await _file!.writeAsString(raw, flush: true);
      await reload();
    } catch (e) {
      debugPrint('恢复默认失败：$e');
    }
  }

  /// 找重复的 key。返回 key → 行索引列表。
  /// 空行跳过、没有 `=` 的行跳过、`=` 在开头的行跳过。
  static Map<String, List<int>> findConflictsIn(List<String> lines) {
    final byKey = <String, List<int>>{};
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty) continue;
      final eq = t.indexOf('=');
      if (eq <= 0) continue;
      final key = t.substring(0, eq).trim();
      if (key.isEmpty) continue;
      (byKey[key] ??= []).add(i);
    }
    return {
      for (final e in byKey.entries)
        if (e.value.length > 1) e.key: e.value,
    };
  }
}

// ==================== 转换 ====================

/// 最长匹配替换。
String convertTranslation(
  String text,
  Map<String, String> dict,
  int maxKeyLen,
) {
  if (text.isEmpty || dict.isEmpty) return text;

  final buf = StringBuffer();
  final n = text.length;
  var i = 0;

  while (i < n) {
    String? matched;
    String? replaced;
    final maxLen = (i + maxKeyLen > n) ? n - i : maxKeyLen;
    for (var len = maxLen; len >= 1; len--) {
      final key = text.substring(i, i + len);
      final v = dict[key];
      if (v != null) {
        matched = key;
        replaced = v;
        break;
      }
    }
    if (matched != null) {
      buf.write(replaced);
      i += matched.length;
    } else {
      buf.write(text[i]);
      i++;
    }
  }
  return buf.toString();
}

// ==================== 转换表编辑页 ====================

class TranslationTableScreen extends StatefulWidget {
  const TranslationTableScreen({super.key});

  @override
  State<TranslationTableScreen> createState() =>
      _TranslationTableScreenState();
}

class _TranslationTableScreenState extends State<TranslationTableScreen> {
  static const int _controllerCacheCap = 600;
  static const double _rowHeight = 44.0;

  List<String> _lines = [];
  final Map<int, TextEditingController> _controllers = {};
  bool _loading = true;
  bool _dirty = false;

  // ---- 滚动 ----
  final ScrollController _scrollCtrl = ScrollController();

  // ---- 搜索 ----
  final TextEditingController _searchCtrl = TextEditingController();
  bool _showSearch = false;
  String _searchQuery = '';
  List<int> _searchHits = [];
  int _searchPos = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await TranslationTable.instance.init();
    if (!mounted) return;
    setState(() {
      _lines = List<String>.from(TranslationTable.instance.lines);
      _loading = false;
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ==================== controller 缓存 ====================

  TextEditingController _controllerFor(int i) {
    var c = _controllers[i];
    if (c == null) {
      c = TextEditingController(text: _lines[i]);
      final cc = c;
      c.addListener(() => _onLineChanged(i, cc.text));
      _controllers[i] = c;
      _maybeEvict();
    } else if (c.text != _lines[i]) {
      c.text = _lines[i];
    }
    return c;
  }

  void _maybeEvict() {
    if (_controllers.length <= _controllerCacheCap) return;
    final keys = _controllers.keys.take(_controllers.length ~/ 2).toList();
    for (final k in keys) {
      _controllers.remove(k)?.dispose();
    }
  }

  void _onLineChanged(int i, String text) {
    if (i < 0 || i >= _lines.length) return;
    if (_lines[i] == text) return;
    _lines[i] = text;
    if (!_dirty) setState(() => _dirty = true);
  }

  /// 行列表变了（插入/删除），所有 index 都会错位，必须清空 controller 缓存。
  void _clearAllControllers() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
  }

  // ==================== 插入 / 删除行 ====================

  /// 在 index 位置插入一个空行。
  /// index = _lines.length 时，追加到末尾。
  void _insertLineAt(int index) {
    setState(() {
      _lines.insert(index, '');
      _clearAllControllers();
      _dirty = true;
    });
    // 等一下帧完成布局，再滚到刚插入的位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToLineRaw(index);
    });
  }

  void _deleteLineAt(int index) {
    setState(() {
      _lines.removeAt(index);
      _clearAllControllers();
      _dirty = true;
    });
  }

  Future<void> _confirmDeleteLine(int index) async {
    final content = _lines[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除第 ${index + 1} 行？'),
        content: content.isEmpty
            ? const Text('（空行）')
            : Text(
                content,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) _deleteLineAt(index);
  }

  // ==================== 滚动 ====================

  void _jumpToLineRaw(int index) {
    if (!_scrollCtrl.hasClients) return;
    // 目标行往上偏 100px，让它出现在视口上半部，不贴顶
    final offset = index * _rowHeight - 100;
    final max = _scrollCtrl.position.maxScrollExtent;
    _scrollCtrl.jumpTo(offset.clamp(0.0, max));
  }

  // ==================== 搜索 ====================

  void _onSearchChanged(String q) {
    setState(() {
      _searchQuery = q;
      _recomputeSearchHits();
    });
  }

  void _recomputeSearchHits() {
    final q = _searchQuery;
    if (q.isEmpty) {
      _searchHits = [];
      _searchPos = -1;
      return;
    }
    final hits = <int>[];
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].contains(q)) hits.add(i);
    }
    _searchHits = hits;
    _searchPos = hits.isEmpty ? -1 : 0;
    if (hits.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpToLineRaw(hits[0]);
      });
    }
  }

  void _findNext() {
    if (_searchHits.isEmpty) return;
    setState(() {
      _searchPos = (_searchPos + 1) % _searchHits.length;
    });
    _jumpToLineRaw(_searchHits[_searchPos]);
  }

  void _findPrev() {
    if (_searchHits.isEmpty) return;
    setState(() {
      _searchPos =
          (_searchPos - 1 + _searchHits.length) % _searchHits.length;
    });
    _jumpToLineRaw(_searchHits[_searchPos]);
  }

  void _closeSearch() {
    setState(() {
      _showSearch = false;
      _searchCtrl.clear();
      _searchQuery = '';
      _searchHits = [];
      _searchPos = -1;
    });
  }

  // ==================== 保存 / 导出 / 恢复 ====================

  Future<void> _save() async {
    var lines = _lines;
    final conflicts = TranslationTable.findConflictsIn(lines);

    if (conflicts.isNotEmpty) {
      final result = await showDialog<List<String>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ConflictResolverDialog(
          allLines: lines,
          conflicts: conflicts,
        ),
      );
      if (result == null || !mounted) return;
      lines = result;
    }

    await TranslationTable.instance.saveLines(lines);
    if (!mounted) return;

    _clearAllControllers();

    setState(() {
      _lines = List<String>.from(lines);
      _dirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
  }

  Future<void> _export() async {
    final raw = _lines.join('\n');
    final bytes = Uint8List.fromList(utf8.encode(raw));
    final out = await FilePicker.saveFile(
      fileName: 't2s.txt',
      bytes: bytes,
      mimeType: 'text/plain',
      dialogTitle: '导出词库',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (out != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已导出')),
      );
    }
  }

  Future<void> _resetToDefault() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('恢复默认词库？'),
        content: const Text('你所有的修改会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await TranslationTable.instance.resetToDefault();
    if (!mounted) return;

    _clearAllControllers();

    setState(() {
      _lines = List<String>.from(TranslationTable.instance.lines);
      _dirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复默认')),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('有未保存的修改'),
            content: const Text('返回将丢失改动。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('放弃'),
              ),
            ],
          ),
        );
        if (ok == true && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('简繁转换表'),
          actions: [
            IconButton(
              icon: Icon(_showSearch ? Icons.search_off : Icons.search),
              tooltip: '搜索',
              onPressed: () {
                setState(() {
                  _showSearch = !_showSearch;
                  if (!_showSearch) {
                    _searchCtrl.clear();
                    _searchQuery = '';
                    _searchHits = [];
                    _searchPos = -1;
                  }
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.restore),
              tooltip: '恢复默认',
              onPressed: _resetToDefault,
            ),
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: '导出',
              onPressed: _export,
            ),
            TextButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('保存'),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  if (_showSearch) _buildSearchBar(),
                  Expanded(child: _buildList()),
                  _buildStatusBar(),
                ],
              ),
        floatingActionButton: _loading
            ? null
            : FloatingActionButton(
                onPressed: () => _insertLineAt(_lines.length),
                tooltip: '在末尾新增一行',
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  Widget _buildSearchBar() {
    final total = _searchHits.length;
    final cur = total == 0 ? 0 : _searchPos + 1;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索',
                  isDense: true,
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search, size: 18),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$cur/$total',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_upward),
              tooltip: '上一个',
              visualDensity: VisualDensity.compact,
              onPressed: _searchHits.isEmpty ? null : _findPrev,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_downward),
              tooltip: '下一个',
              visualDensity: VisualDensity.compact,
              onPressed: _searchHits.isEmpty ? null : _findNext,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '关闭搜索',
              visualDensity: VisualDensity.compact,
              onPressed: _closeSearch,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          const Color(0xFFD4D4DC).withValues(alpha: 0.40),
        ),
        thickness: const WidgetStatePropertyAll(12),
        radius: const Radius.circular(6),
        minThumbLength: 40,
        trackVisibility: const WidgetStatePropertyAll(false),
      ),
      child: Scrollbar(
        controller: _scrollCtrl,
        interactive: true,
        child: ListView.builder(
          controller: _scrollCtrl,
          itemExtent: _rowHeight,
          itemCount: _lines.length,
          itemBuilder: (ctx, i) {
            final ctrl = _controllerFor(i);
            final isHit = _showSearch &&
                _searchQuery.isNotEmpty &&
                _lines[i].contains(_searchQuery);
            final isCurrentHit = _showSearch &&
                _searchPos >= 0 &&
                _searchPos < _searchHits.length &&
                _searchHits[_searchPos] == i;
            return _TableLineRow(
              lineNumber: i + 1,
              controller: ctrl,
              isHit: isHit,
              isCurrentHit: isCurrentHit,
              onInsertAbove: () => _insertLineAt(i),
              onDelete: () => _confirmDeleteLine(i),
            );
          },
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        '共 ${_lines.length} 行${_dirty ? " · 未保存" : ""}',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

// ==================== 行 Widget ====================

class _TableLineRow extends StatelessWidget {
  const _TableLineRow({
    required this.lineNumber,
    required this.controller,
    required this.isHit,
    required this.isCurrentHit,
    required this.onInsertAbove,
    required this.onDelete,
  });

  final int lineNumber;
  final TextEditingController controller;
  final bool isHit;
  final bool isCurrentHit;
  final VoidCallback onInsertAbove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final bg = isCurrentHit
        ? const Color(0xFFFF4081).withValues(alpha: 0.20)
        : isHit
            ? const Color(0xFFFFF59D).withValues(alpha: 0.5)
            : null;

    return Container(
      color: bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 行号：长按删除
          GestureDetector(
            onLongPress: onDelete,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 56,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, right: 6),
                child: Text(
                  '$lineNumber',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
            ),
          ),
          // 编辑区
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: TextField(
                controller: controller,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                ),
              ),
            ),
          ),
          // 插入按钮：在当前行上方插一个空行
          SizedBox(
            width: 36,
            child: IconButton(
              icon: const Icon(Icons.add, size: 18),
              tooltip: '在此行上方插入',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              onPressed: onInsertAbove,
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 冲突处理弹窗 ====================

class ConflictResolverDialog extends StatefulWidget {
  const ConflictResolverDialog({
    super.key,
    required this.allLines,
    required this.conflicts,
  });

  final List<String> allLines;
  final Map<String, List<int>> conflicts;

  @override
  State<ConflictResolverDialog> createState() =>
      _ConflictResolverDialogState();
}

class _ConflictResolverDialogState extends State<ConflictResolverDialog> {
  late Map<String, List<_EditableLine>> _groups;
  late List<String> _initialKeys;
  final Map<int, String?> _edits = {};

  @override
  void initState() {
    super.initState();
    _groups = {};
    _initialKeys = widget.conflicts.keys.toList();

    for (final entry in widget.conflicts.entries) {
      final list = <_EditableLine>[];
      for (final idx in entry.value) {
        final ctrl = TextEditingController(text: widget.allLines[idx]);
        ctrl.addListener(() => _onLineChanged(idx, ctrl.text));
        list.add(_EditableLine(
          lineIndex: idx,
          lineNumber: idx + 1,
          controller: ctrl,
        ));
      }
      _groups[entry.key] = list;
    }
  }

  void _onLineChanged(int idx, String text) {
    if (text == widget.allLines[idx]) {
      _edits.remove(idx);
    } else {
      _edits[idx] = text;
    }
  }

  @override
  void dispose() {
    for (final lines in _groups.values) {
      for (final l in lines) {
        l.controller.dispose();
      }
    }
    super.dispose();
  }

  int get _remainingGroups {
    var n = 0;
    for (final lines in _groups.values) {
      if (lines.length > 1) n++;
    }
    return n;
  }

  Future<void> _deleteLine(String key, _EditableLine line) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除第 ${line.lineNumber} 行？'),
        content: Text(
          line.controller.text,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _groups[key]!.remove(line);
      _edits[line.lineIndex] = null;
      line.controller.dispose();
      if (_groups[key]!.length <= 1) {
        _groups.remove(key);
      }
    });
  }

  void _confirm() {
    final remaining = _remainingGroups;
    if (remaining > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('还有 $remaining 个词有重复，请先处理完'),
          duration: const Duration(milliseconds: 1500),
        ),
      );
      return;
    }

    final result = <String>[];
    for (var i = 0; i < widget.allLines.length; i++) {
      if (_edits.containsKey(i)) {
        final v = _edits[i];
        if (v != null) result.add(v);
      } else {
        result.add(widget.allLines[i]);
      }
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final totalSlots = _initialKeys.length;
    final rowCount = (totalSlots + 1) ~/ 2;

    return Dialog(
      insetPadding: const EdgeInsets.all(8),
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _remainingGroups == 0
                          ? '所有冲突已处理完'
                          : '词库里有 $_remainingGroups 个词重复',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _remainingGroups == 0
                  ? const Center(
                      child: Text(
                        '点右下角"确定"应用修改',
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: rowCount,
                      itemBuilder: (ctx, rowIdx) {
                        final leftIdx = rowIdx * 2;
                        final rightIdx = leftIdx + 1;

                        final leftKey = leftIdx < totalSlots
                            ? _initialKeys[leftIdx]
                            : null;
                        final rightKey = rightIdx < totalSlots
                            ? _initialKeys[rightIdx]
                            : null;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _buildSlot(leftKey)),
                              const SizedBox(width: 8),
                              Expanded(child: _buildSlot(rightKey)),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _confirm,
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlot(String? key) {
    if (key == null) return const SizedBox.shrink();
    final lines = _groups[key];
    if (lines == null || lines.isEmpty) return const SizedBox.shrink();
    return _buildGroup(key, lines);
  }

  Widget _buildGroup(String key, List<_EditableLine> lines) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    '「$key」',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Container(height: 1, color: Colors.grey.shade400),
                ),
              ],
            ),
          ),
          for (final line in lines) _buildLine(key, line),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildLine(String key, _EditableLine line) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          GestureDetector(
            onLongPress: () => _deleteLine(key, line),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 56,
              alignment: Alignment.center,
              child: Text(
                '${line.lineNumber}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  color: Colors.grey,
                ),
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: line.controller,
              style: const TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditableLine {
  _EditableLine({
    required this.lineIndex,
    required this.lineNumber,
    required this.controller,
  });

  final int lineIndex;
  final int lineNumber;
  final TextEditingController controller;
}
