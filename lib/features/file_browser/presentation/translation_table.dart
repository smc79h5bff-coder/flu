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
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/$_userFileName');

    if (!await _file!.exists()) {
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

  List<String> _lines = [];
  final Map<int, TextEditingController> _controllers = {};
  bool _loading = true;
  bool _dirty = false;

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
    super.dispose();
  }

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

    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();

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

    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();

    setState(() {
      _lines = List<String>.from(TranslationTable.instance.lines);
      _dirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已恢复默认')),
    );
  }

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
                  Expanded(child: _buildList()),
                  _buildStatusBar(),
                ],
              ),
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      itemCount: _lines.length,
      itemBuilder: (ctx, i) {
        final ctrl = _controllerFor(i);
        return _TableLineRow(
          lineNumber: i + 1,
          controller: ctrl,
        );
      },
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

class _TableLineRow extends StatelessWidget {
  const _TableLineRow({
    required this.lineNumber,
    required this.controller,
  });

  final int lineNumber;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
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
      ],
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
