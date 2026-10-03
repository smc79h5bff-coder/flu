import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/application/preprocessing_service.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';
import '../../viewer/presentation/viewer_widgets.dart'
    show pickColorDialog;
import 'comparison_settings_screen.dart' show RuleEditorDialog, ruleSubtitle;
import 'providers/line_editor_rules_provider.dart';

const int _lineEditorWarnSizeBytes = 5 * 1024 * 1024;
const int _lineEditorRejectSizeBytes = 100 * 1024 * 1024;

enum _LineSaveEncoding {
  utf8('UTF-8'),
  gbk('GBK');

  const _LineSaveEncoding(this.label);
  final String label;
}

/// 行编辑器：用 `ListView.builder` + 每行一个独立小 TextField 做虚拟化，
/// 一屏只渲染可见 ~20 行，敲字不触发全文 layout。
///
/// 与 [SingleFileEditorScreen]（旧编辑器）互不影响、共用同一文件。
class LineEditorScreen extends ConsumerStatefulWidget {
  const LineEditorScreen({
    super.key,
    required this.filePath,
    required this.fileName,
  });

  final String filePath;
  final String fileName;

  @override
  ConsumerState<LineEditorScreen> createState() => _LineEditorScreenState();
}

class _LineEditorScreenState extends ConsumerState<LineEditorScreen> {
  static const int _controllerCacheCap = 600;

  /// 事实来源：每行文本。controller 是这张表的镜像。
  List<String> _lines = const <String>[];

  /// 按行号缓存的 controller。
  final Map<int, _LineController> _controllers = {};

  bool _loading = true;
  bool _dirty = false;
  bool _saving = false;
  bool _processing = false;
  String _processingText = '';

  String _detectedEncoding = '';
  _LineSaveEncoding _saveEncoding = _LineSaveEncoding.utf8;

  double _fontSize = 14.0;
  bool _noWrap = false;

  final ScrollController _scrollCtrl = ScrollController();

  // ---- 查找 / 替换 ----
  bool _showFind = false;
  final TextEditingController _findCtrl = TextEditingController();
  final TextEditingController _replaceCtrl = TextEditingController();
  bool _useRegex = false;
  bool _caseSensitive = false;
  List<int> _findHits = const <int>[];
  int _findPos = -1;

  /// 查找词刷新的 debounce。避免每敲一个字都遍历所有 controller。
  Timer? _findDebounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _findDebounce?.cancel();
    _scrollCtrl.dispose();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ==================== 加载 / 保存 ====================

  Future<void> _load() async {
    try {
      final file = File(widget.filePath);
      final len = await file.length();

      if (len > _lineEditorRejectSizeBytes) {
        if (!mounted) return;
        setState(() => _loading = false);
        _toast(
            '文件超过 ${_lineEditorRejectSizeBytes ~/ 1024 ~/ 1024} MB，请用预览功能');
        return;
      }

      if (len > _lineEditorWarnSizeBytes && mounted) {
        final mb = (len / 1024 / 1024).toStringAsFixed(1);
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('文件较大'),
            content: Text(
              '此文件约 $mb MB。\n'
              '行编辑器只渲染可见行，超大文件仍可能卡顿。\n'
              '继续打开？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('打开'),
              ),
            ],
          ),
        );
        if (ok != true) {
          if (mounted) setState(() => _loading = false);
          return;
        }
      }

      final bytes = await file.readAsBytes();
      final enc = EncodingDetector.detect(bytes);
      final text = EncodingDetector.decodeChunked(bytes, enc);
      if (!mounted) return;
      setState(() {
        _lines = text.split('\n');
        _detectedEncoding = enc.label;
        _saveEncoding = _guessSaveEncoding(enc);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取失败：$e');
    }
  }

  _LineSaveEncoding _guessSaveEncoding(EncodingType enc) {
    switch (enc) {
      case EncodingType.gbk:
      case EncodingType.gb18030:
        return _LineSaveEncoding.gbk;
      default:
        return _LineSaveEncoding.utf8;
    }
  }

  Uint8List _encodeText(String text) {
    switch (_saveEncoding) {
      case _LineSaveEncoding.utf8:
        return Uint8List.fromList(utf8.encode(text));
      case _LineSaveEncoding.gbk:
        return Uint8List.fromList(gbk.encode(text));
    }
  }

  String _joinLines() => _lines.join('\n');

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = _encodeText(_joinLines());
      final file = File(widget.filePath);
      if (await file.exists()) {
        final bak = File('${widget.filePath}.bak');
        if (!await bak.exists()) {
          await bak.writeAsBytes(await file.readAsBytes(), flush: true);
        } else {
          final ts = DateTime.now().millisecondsSinceEpoch;
          await File('${widget.filePath}_$ts.bak')
              .writeAsBytes(await file.readAsBytes(), flush: true);
        }
      }
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _saving = false;
      });
      _toast('已保存（原文件已生成 .bak 备份）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e');
    }
  }

  Future<void> _saveAs() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = _encodeText(_joinLines());
      final out = await FilePicker.saveFile(
        fileName: widget.fileName,
        bytes: bytes,
        mimeType: 'text/plain',
        dialogTitle: '另存为',
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      if (!mounted) return;
      setState(() => _saving = false);
      if (out != null) _toast('已另存为 $out');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('另存失败：$e');
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('有未保存的修改'),
        content: const Text('返回将丢失改动，确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'discard'),
            child: const Text('放弃并返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'save'),
            child: const Text('保存并返回'),
          ),
        ],
      ),
    );
    if (r == 'save') {
      await _save();
      return !_dirty;
    }
    return r == 'discard';
  }

  // ==================== Controller 缓存 ====================

  _LineController _controllerFor(int i) {
    var c = _controllers[i];
    if (c == null) {
      c = _LineController(text: _lines[i], findQuery: _findCtrl.text);
      final cc = c;
      c.addListener(() => _onLineChanged(i, cc.text));
      _controllers[i] = c;
      _maybeEvict();
    } else if (c.text != _lines[i]) {
      // 行内容被外部改过（查找替换、按钮规则）→ 回灌。
      // setter 会触发 listener，_onLineChanged 短路返回。
      c.text = _lines[i];
    }
    return c;
  }

  void _maybeEvict() {
    if (_controllers.length <= _controllerCacheCap) return;
    final keys = _controllers.keys
        .take(_controllers.length ~/ 2)
        .toList(growable: false);
    for (final k in keys) {
      _controllers.remove(k)?.dispose();
    }
  }

  void _onLineChanged(int i, String text) {
    if (i < 0 || i >= _lines.length) return;
    if (_lines[i] == text) return;
    _lines[i] = text;
    // 底部状态栏有字符数，需要刷新。代价很小：只重建可见行。
    setState(() => _dirty = true);
  }

  // ==================== 查找 / 替换 ====================

  Pattern _buildPattern() {
    final q = _findCtrl.text;
    if (q.isEmpty) return RegExp(r'(?!)');
    try {
      return _useRegex
          ? RegExp(q, caseSensitive: _caseSensitive, multiLine: true)
          : RegExp(RegExp.escape(q), caseSensitive: _caseSensitive);
    } catch (_) {
      return RegExp(r'(?!)');
    }
  }

  /// 查找词输入变化 → 延时把可见行的 controller 里的 findQuery 刷一遍。
  /// 直接改字段不会重绘，必须 notifyListeners。
  void _onFindInputChanged(String _) {
    _findDebounce?.cancel();
    _findDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      final q = _findCtrl.text;
      for (final c in _controllers.values) {
        if (c.findQuery != q) {
          c.findQuery = q;
          c.notifyListeners();
        }
      }
    });
  }

  void _recomputeHits() {
    final q = _findCtrl.text;
    if (q.isEmpty) {
      setState(() {
        _findHits = const <int>[];
        _findPos = -1;
      });
      return;
    }
    final p = _buildPattern();
    final hits = <int>[];
    for (var i = 0; i < _lines.length; i++) {
      if (p.allMatches(_lines[i]).isNotEmpty) hits.add(i);
    }
    setState(() {
      _findHits = hits;
      _findPos = hits.isEmpty ? -1 : 0;
    });
    if (hits.isNotEmpty) _scrollToLine(hits[0]);
  }

  void _findNext() {
    if (_findHits.isEmpty) {
      _recomputeHits();
      return;
    }
    setState(() => _findPos = (_findPos + 1) % _findHits.length);
    _scrollToLine(_findHits[_findPos]);
  }

  void _findPrev() {
    if (_findHits.isEmpty) {
      _recomputeHits();
      return;
    }
    setState(() =>
        _findPos = (_findPos - 1 + _findHits.length) % _findHits.length);
    _scrollToLine(_findHits[_findPos]);
  }

  void _replaceCurrent() {
    if (_findHits.isEmpty || _findPos < 0) return;
    final lineNo = _findHits[_findPos];
    final line = _lines[lineNo];
    final p = _buildPattern();
    final newLine = line.replaceAllMapped(p, (_) => _replaceCtrl.text);
    if (newLine == line) return;
    _lines[lineNo] = newLine;
    final c = _controllers[lineNo];
    if (c != null) {
      c.text = newLine;
    }
    setState(() => _dirty = true);
    _recomputeHits();
  }

  void _replaceAll() {
    if (_findCtrl.text.isEmpty) {
      _toast('请输入要查找的内容');
      return;
    }
    final p = _buildPattern();
    var count = 0;
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      final newLine = line.replaceAllMapped(p, (_) => _replaceCtrl.text);
      if (newLine != line) {
        _lines[i] = newLine;
        final c = _controllers[i];
        if (c != null) c.text = newLine;
        count++;
      }
    }
    if (count == 0) {
      _toast('没有匹配');
      return;
    }
    setState(() => _dirty = true);
    _recomputeHits();
    _toast('已替换 $count 行');
  }

  // ==================== 滚动 / 跳转 ====================

  /// 估算滚动偏移。行高由 Flutter 定，这里只能估算。
  /// 偏差用户可以手动修正——目标行会先在视口附近，再滑一点就到。
  void _scrollToLine(int lineIdx) {
    if (!_scrollCtrl.hasClients) return;
    final est = lineIdx * (_fontSize * 1.4 + 18);
    final max = _scrollCtrl.position.maxScrollExtent;
    _scrollCtrl.jumpTo(est.clamp(0.0, max));
  }

  Future<void> _jumpToLine() async {
    final ctrl = TextEditingController();
    final line = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('跳到指定行'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入行号（从 1 开始）',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            final n = int.tryParse(v.trim());
            if (n != null && n >= 1) Navigator.pop(c, n);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n != null && n >= 1) Navigator.pop(c, n);
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (line == null) return;
    if (line < 1 || line > _lines.length) {
      _toast('行号超出范围');
      return;
    }
    _scrollToLine(line - 1);
  }

  void _jumpToTop() {
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
  }

  void _jumpToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
  }

  // ==================== 顶部按钮栏（独立于对比页） ====================

  Widget _buildToolbar() {
    final rules = ref.watch(lineEditorRulesOrderedProvider);
    final colors = ref.watch(lineEditorButtonColorsProvider);
    final s = Theme.of(context).colorScheme;

    return Container(
      height: 46,
      color: s.surfaceVariant.withOpacity(0.25),
      child: Row(
        children: [
          Expanded(
            child: rules.isEmpty
                ? Center(
                    child: Text(
                      '点 + 添加按钮（长按编辑）。这一栏和对比页按钮栏互不影响。',
                      style: TextStyle(
                        fontSize: 11,
                        color: s.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    itemCount: rules.length,
                    itemBuilder: (ctx, i) {
                      final r = rules[i];
                      final c = colors[r.id];
                      final bg = c?.bg ?? Colors.white;
                      final fg = c?.fg ?? Colors.black;
                      final border = c?.border ?? Colors.black.withOpacity(0.5);
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 7,
                        ),
                        child: GestureDetector(
                          onTap: () => _applyToolbarRule(r),
                          onLongPress: () => _editToolbarRule(r),
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: border),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: fg,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            tooltip: '新建按钮',
            visualDensity: VisualDensity.compact,
            onPressed: _addToolbarRule,
          ),
          IconButton(
            icon: const Icon(Icons.sort, size: 20),
            tooltip: '排序 / 颜色',
            visualDensity: VisualDensity.compact,
            onPressed: _showToolbarOrderDialog,
          ),
        ],
      ),
    );
  }

  Future<void> _applyToolbarRule(PreprocessingRule rule) async {
    setState(() {
      _processing = true;
      _processingText = '正在执行「${rule.name}」…';
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    try {
      final joined = _joinLines();
      final next = applyOneRule(joined, rule);
      final nextLines = next.split('\n');

      // 行数可能变了 → controller 全部作废。
      for (final c in _controllers.values) {
        c.dispose();
      }
      _controllers.clear();

      setState(() {
        _lines = nextLines;
        _dirty = true;
      });
      _toast('已应用「${rule.name}」');
    } catch (e) {
      _toast('执行失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _processingText = '';
        });
      }
    }
  }

  Future<void> _addToolbarRule() async {
    final rule = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => const RuleEditorDialog(showCopyToPreprocess: false),
    );
    if (rule == null || !mounted) return;
    ref.read(lineEditorRulesProvider.notifier).add(rule);
    _toast('已添加按钮「${rule.name}」');
  }

  Future<void> _editToolbarRule(PreprocessingRule rule) async {
    final updated = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => RuleEditorDialog(
        initial: rule,
        showCopyToPreprocess: true,
      ),
    );
    if (updated == null || !mounted) return;
    ref.read(lineEditorRulesProvider.notifier).updateRule(updated);
  }

  Future<void> _showToolbarOrderDialog() async {
    final rules = ref.read(lineEditorRulesOrderedProvider);
    if (rules.isEmpty) {
      _toast('还没有按钮');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => _LineEditorOrderDialog(rules: rules),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await _confirmLeave();
        if (ok && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.vertical_align_top),
              tooltip: '跳到开头',
              onPressed: _jumpToTop,
            ),
            IconButton(
              icon: const Icon(Icons.vertical_align_bottom),
              tooltip: '跳到结尾',
              onPressed: _jumpToBottom,
            ),
            IconButton(
              icon: const Icon(Icons.format_list_numbered),
              tooltip: '跳到指定行',
              onPressed: _jumpToLine,
            ),
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: '查找 / 替换',
              onPressed: () => setState(() => _showFind = !_showFind),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                switch (v) {
                  case 'saveAs':
                    _saveAs();
                    break;
                  case 'wrap':
                    setState(() => _noWrap = !_noWrap);
                    break;
                  case 'fontUp':
                    setState(() => _fontSize = (_fontSize + 1).clamp(8, 36));
                    break;
                  case 'fontDown':
                    setState(() => _fontSize = (_fontSize - 1).clamp(8, 36));
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'saveAs',
                  child: Row(
                    children: [
                      Icon(Icons.save_as),
                      SizedBox(width: 10),
                      Text('另存为'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'wrap',
                  child: Row(
                    children: [
                      Icon(_noWrap ? Icons.wrap_text : Icons.notes),
                      const SizedBox(width: 10),
                      Text(_noWrap ? '开启自动换行' : '关闭自动换行'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'fontUp',
                  child: Row(
                    children: [
                      Icon(Icons.text_increase),
                      SizedBox(width: 10),
                      Text('字号 +1'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'fontDown',
                  child: Row(
                    children: [
                      Icon(Icons.text_decrease),
                      SizedBox(width: 10),
                      Text('字号 -1'),
                    ],
                  ),
                ),
              ],
            ),
            TextButton.icon(
              onPressed: _saving || _loading ? null : _save,
              icon: Icon(_saving ? Icons.hourglass_top : Icons.save),
              label: const Text('保存'),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _buildToolbar(),
                  if (_processing) _buildProcessingBanner(),
                  if (_showFind) _buildFindBar(),
                  Expanded(child: _buildLineList()),
                  _buildStatusBar(),
                ],
              ),
      ),
    );
  }

  Widget _buildProcessingBanner() {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        _processingText,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onTertiaryContainer,
        ),
      ),
    );
  }

  Widget _buildLineList() {
    final s = Theme.of(context).colorScheme;
    final total = _lines.length;

    return ListView.builder(
      controller: _scrollCtrl,
      itemCount: total,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      cacheExtent: 500,
      itemBuilder: (ctx, i) {
        final ctrl = _controllerFor(i);
        return _LineRow(
          index: i,
          controller: ctrl,
          fontSize: _fontSize,
          noWrap: _noWrap,
          gutterColor: s.outline,
        );
      },
    );
  }

  Widget _buildStatusBar() {
    final s = Theme.of(context).colorScheme;
    final total = _lines.length;
    return Container(
      width: double.infinity,
      color: s.surfaceVariant.withOpacity(0.4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        '$total 行 · $_detectedEncoding → ${_saveEncoding.label}'
        '${_noWrap ? " · 不换行" : ""}'
        '${_dirty ? " · 未保存" : ""}',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }

  Widget _buildFindBar() {
    final s = Theme.of(context).colorScheme;
    final total = _findHits.length;
    final cur = total == 0 ? 0 : (_findPos + 1);

    return Material(
      color: s.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '关闭查找',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    _showFind = false;
                    _findCtrl.clear();
                    _findHits = const <int>[];
                    _findPos = -1;
                    for (final c in _controllers.values) {
                      if (c.findQuery.isNotEmpty) {
                        c.findQuery = '';
                        c.notifyListeners();
                      }
                    }
                  }),
                ),
                Expanded(
                  child: TextField(
                    controller: _findCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '查找',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: _onFindInputChanged,
                    onSubmitted: (_) => _findNext(),
                  ),
                ),
                Text(
                  '$cur/$total',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: '上一个',
                  visualDensity: VisualDensity.compact,
                  onPressed: _findPrev,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward),
                  tooltip: '下一个',
                  visualDensity: VisualDensity.compact,
                  onPressed: _findNext,
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 48),
                Expanded(
                  child: TextField(
                    controller: _replaceCtrl,
                    decoration: const InputDecoration(
                      hintText: '替换为（留空 = 删掉）',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _replaceCurrent,
                  child: const Text('替换当前'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _replaceAll,
                  child: const Text('全部替换'),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 8),
                _toggle(
                  label: '正则',
                  value: _useRegex,
                  onTap: () {
                    setState(() => _useRegex = !_useRegex);
                    _recomputeHits();
                  },
                ),
                _toggle(
                  label: '区分大小写',
                  value: _caseSensitive,
                  onTap: () {
                    setState(() => _caseSensitive = !_caseSensitive);
                    _recomputeHits();
                  },
                ),
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _recomputeHits,
                  child: const Text('搜索'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggle({
    required String label,
    required bool value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: value ? FontWeight.bold : FontWeight.normal,
            color: value
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }
}

// ==================== 行 Widget ====================

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.index,
    required this.controller,
    required this.fontSize,
    required this.noWrap,
    required this.gutterColor,
  });

  final int index;
  final _LineController controller;
  final double fontSize;
  final bool noWrap;
  final Color gutterColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 44,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, right: 6, left: 4),
            child: Text(
              '${index + 1}',
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: fontSize - 3,
                color: gutterColor,
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: TextField(
              controller: controller,
              maxLines: noWrap ? 1 : null,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              style: TextStyle(
                fontSize: fontSize,
                height: 1.4,
                fontFamily: 'monospace',
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ==================== 带查找高亮的 controller ====================

class _LineController extends TextEditingController {
  _LineController({super.text, this.findQuery = ''});

  /// 当前查找词。空 = 不高亮。
  String findQuery;

  static const Color _matchYellow = Color(0xFFFFF59D);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // 输入法组合输入时交给父类（组合下划线由系统画）。
    if (withComposing && value.composing.isValid) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final text = this.text;
    final q = findQuery;
    if (q.isEmpty || text.isEmpty) {
      return TextSpan(style: style, text: text.isEmpty ? ' ' : text);
    }

    // 字面量高亮。查找开了正则时，这里仍是"整段 q 在行里出现"的高亮，
    // 近似够用——精确高亮得先把正则的每个匹配位置都算出来，代价大。
    final spans = <InlineSpan>[];
    var start = 0;
    int idx;
    while (start <= text.length && (idx = text.indexOf(q, start)) != -1) {
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx)));
      }
      spans.add(TextSpan(
        text: q,
        style: const TextStyle(
          backgroundColor: _matchYellow,
          fontWeight: FontWeight.bold,
        ),
      ));
      start = idx + q.length;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }
    return TextSpan(style: style, children: spans.isEmpty ? null : spans);
  }
}

// ==================== 按钮排序 + 颜色对话框 ====================

class _LineEditorOrderDialog extends ConsumerStatefulWidget {
  const _LineEditorOrderDialog({required this.rules});

  final List<PreprocessingRule> rules;

  @override
  ConsumerState<_LineEditorOrderDialog> createState() =>
      _LineEditorOrderDialogState();
}

class _LineEditorOrderDialogState
    extends ConsumerState<_LineEditorOrderDialog> {
  late List<PreprocessingRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = List<PreprocessingRule>.from(widget.rules);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: const Text('按钮排序 / 颜色'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.7,
        child: ReorderableListView.builder(
          itemCount: _rules.length,
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final item = _rules.removeAt(oldIndex);
              _rules.insert(newIndex, item);
            });
          },
          itemBuilder: (ctx, i) {
            final r = _rules[i];
            return ListTile(
              key: ValueKey<String>('order:${r.id}'),
              leading: const Icon(Icons.drag_handle),
              title: Text(r.name),
              subtitle: Text(
                ruleSubtitle(r),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '设置颜色',
                    icon: const Icon(Icons.palette),
                    onPressed: () => _openColorPanel(r),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() => _rules.removeAt(i));
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _openColorPanel(PreprocessingRule r) {
    showDialog<void>(
      context: context,
      builder: (_) => _LineEditorColorDialog(
        ruleId: r.id,
        ruleName: r.name,
      ),
    );
  }

  void _save() {
    ref
        .read(lineEditorOrderProvider.notifier)
        .setAll(_rules.map((r) => r.id).toList());
    ref.read(lineEditorRulesProvider.notifier).setAll(_rules);

    // 清掉被删除按钮的颜色记录。
    final newIds = _rules.map((r) => r.id).toSet();
    final oldIds = widget.rules.map((r) => r.id).toSet();
    for (final id in oldIds.difference(newIds)) {
      ref.read(lineEditorButtonColorsProvider.notifier).remove(id);
    }

    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
  }
}

class _LineEditorColorDialog extends ConsumerStatefulWidget {
  const _LineEditorColorDialog({
    required this.ruleId,
    required this.ruleName,
  });

  final String ruleId;
  final String ruleName;

  @override
  ConsumerState<_LineEditorColorDialog> createState() =>
      _LineEditorColorDialogState();
}

class _LineEditorColorDialogState
    extends ConsumerState<_LineEditorColorDialog> {
  @override
  Widget build(BuildContext context) {
    final all = ref.watch(lineEditorButtonColorsProvider);
    final c = all[widget.ruleId] ?? const LineEditorButtonColor();

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: Text(
        '${widget.ruleName} · 按钮颜色',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _colorRow(
              context: context,
              label: '背景色',
              isSet: c.bg != null,
              color: c.bg ?? Colors.white,
              onPick: (v) => _setBg(v),
            ),
            _colorRow(
              context: context,
              label: '文字色',
              isSet: c.fg != null,
              color: c.fg ?? Colors.black,
              onPick: (v) => _setFg(v),
            ),
            _colorRow(
              context: context,
              label: '边框色',
              isSet: c.border != null,
              color: c.border ?? Colors.black.withOpacity(0.5),
              onPick: (v) => _setBorder(v),
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
    );
  }

  void _setBg(Color? color) {
    final all = ref.read(lineEditorButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const LineEditorButtonColor();
    ref.read(lineEditorButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          LineEditorButtonColor(bg: color, fg: cur.fg, border: cur.border),
        );
  }

  void _setFg(Color? color) {
    final all = ref.read(lineEditorButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const LineEditorButtonColor();
    ref.read(lineEditorButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          LineEditorButtonColor(bg: cur.bg, fg: color, border: cur.border),
        );
  }

  void _setBorder(Color? color) {
    final all = ref.read(lineEditorButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const LineEditorButtonColor();
    ref.read(lineEditorButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          LineEditorButtonColor(bg: cur.bg, fg: cur.fg, border: color),
        );
  }

  Widget _colorRow({
    required BuildContext context,
    required String label,
    required bool isSet,
    required Color color,
    required void Function(Color?) onPick,
  }) {
    final s = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isSet ? _hexOf(color) : '默认',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: isSet ? s.onSurface : s.outline,
            ),
          ),
          const SizedBox(width: 4),
          if (isSet)
            SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: '清空（回到默认）',
                icon: const Icon(Icons.close, size: 14),
                onPressed: () => onPick(null),
              ),
            ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () async {
              final picked = await pickColorDialog(context, color);
              if (picked != null) onPick(picked);
            },
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(color: s.outline),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _hexOf(Color c) {
    final v = c.toARGB32() & 0xFFFFFF;
    return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}
