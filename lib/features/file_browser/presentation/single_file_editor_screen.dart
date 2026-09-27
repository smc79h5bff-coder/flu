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
import '../../viewer/presentation/providers/toolbar_rules_provider.dart';
import 'comparison_settings_screen.dart'
    show RuleEditorDialog, ruleSubtitle;

/// 文件大小阈值。
const int _warnSizeBytes = 5 * 1024 * 1024;
const int _rejectSizeBytes = 20 * 1024 * 1024;

enum _SaveEncoding {
  utf8('UTF-8'),
  gbk('GBK');

  const _SaveEncoding(this.label);
  final String label;
}

class SingleFileEditorScreen extends ConsumerStatefulWidget {
  const SingleFileEditorScreen({
    super.key,
    required this.filePath,
    required this.fileName,
  });

  final String filePath;
  final String fileName;

  @override
  ConsumerState<SingleFileEditorScreen> createState() =>
      _SingleFileEditorScreenState();
}

class _SingleFileEditorScreenState
    extends ConsumerState<SingleFileEditorScreen> {
  late _HighlightController _textCtrl;
  final ScrollController _scrollCtrl = ScrollController();
  final ScrollController _hScrollCtrl = ScrollController();
  final TextEditingController _findCtrl = TextEditingController();
  final TextEditingController _replaceCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _showFind = false;
  bool _processing = false;
  String _processingText = '';

  String _detectedEncoding = '';
  _SaveEncoding _saveEncoding = _SaveEncoding.utf8;

  bool _useRegex = false;
  bool _caseSensitive = false;

  bool _noWrap = false;
  double _fontSize = 14.0;

  final Map<int, Offset> _touches = <int, Offset>{};
  double _pinchStartDist = 0;
  double _pinchStartFont = 14.0;

  double _maxLineWidth = 600;

  @override
  void initState() {
    super.initState();
    _textCtrl = _HighlightController();
    _textCtrl.addListener(_onTextChanged);
    _load();
  }

  @override
  void dispose() {
    _textCtrl.removeListener(_onTextChanged);
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _hScrollCtrl.dispose();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (!_dirty) setState(() => _dirty = true);
    if (_noWrap) _recomputeMaxLineWidth();
  }

  void _recomputeMaxLineWidth() {
    var max = 0;
    final t = _textCtrl.text;
    var start = 0;
    for (var i = 0; i <= t.length; i++) {
      if (i == t.length || t.codeUnitAt(i) == 0x0A) {
        final len = i - start;
        if (len > max) max = len;
        start = i + 1;
      }
    }
    _maxLineWidth = max * _fontSize * 0.62 + 80;
    if (_maxLineWidth < 600) _maxLineWidth = 600;
  }

  // ==================== 加载 ====================

  Future<void> _load() async {
    try {
      final file = File(widget.filePath);
      final len = await file.length();

      if (len > _rejectSizeBytes) {
        if (!mounted) return;
        setState(() => _loading = false);
        _toast('文件超过 ${_rejectSizeBytes ~/ 1024 ~/ 1024} MB，请用预览功能');
        return;
      }

      bool noWrap = false;
      if (len > _warnSizeBytes) {
        if (!mounted) return;
        final mb = (len / 1024 / 1024).toStringAsFixed(1);
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('文件较大'),
            content: Text(
              '此文件约 $mb MB，将以「不换行」模式打开以避免卡顿。\n'
              '打开后可在顶栏切换回换行模式。',
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
          if (!mounted) return;
          setState(() => _loading = false);
          return;
        }
        noWrap = true;
      }

      final bytes = await file.readAsBytes();
      final enc = EncodingDetector.detect(bytes);
      final text = EncodingDetector.decodeChunked(bytes, enc);
      if (!mounted) return;
      setState(() {
        _textCtrl.text = text;
        _dirty = false;
        _detectedEncoding = enc.label;
        _saveEncoding = _guessSaveEncoding(enc);
        _noWrap = noWrap;
        _loading = false;
      });
      if (noWrap) _recomputeMaxLineWidth();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取失败：$e');
    }
  }

  _SaveEncoding _guessSaveEncoding(EncodingType enc) {
    switch (enc) {
      case EncodingType.gbk:
      case EncodingType.gb18030:
        return _SaveEncoding.gbk;
      default:
        return _SaveEncoding.utf8;
    }
  }

  // ==================== 保存 ====================

  Uint8List _encodeText(String text, _SaveEncoding enc) {
    switch (enc) {
      case _SaveEncoding.utf8:
        return Uint8List.fromList(utf8.encode(text));
      case _SaveEncoding.gbk:
        return Uint8List.fromList(gbk.encode(text));
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = _encodeText(_textCtrl.text, _saveEncoding);
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
      final bytes = _encodeText(_textCtrl.text, _saveEncoding);
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

  // ==================== 跳转 ====================

  void _jumpToTop() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.jumpTo(0);
  }

  void _jumpToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
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

    final text = _textCtrl.text;
    var pos = 0;
    var currentLine = 1;
    while (currentLine < line && pos < text.length) {
      final idx = text.indexOf('\n', pos);
      if (idx < 0) break;
      pos = idx + 1;
      currentLine++;
    }
    _textCtrl.selection = TextSelection.collapsed(offset: pos);
    _toast('已跳到第 $line 行');
  }

  // ==================== 查找替换 ====================

  void _recomputeMatches() {
    _textCtrl.findQuery = _findCtrl.text;
    _textCtrl.useRegex = _useRegex;
    _textCtrl.caseSensitive = _caseSensitive;
    _textCtrl.recomputeMatches();
    setState(() {});
  }

  void _findNext() {
    final n = _textCtrl.matchCount;
    if (n == 0) {
      _toast('未找到');
      return;
    }
    _textCtrl.currentMatch = (_textCtrl.currentMatch + 1) % n;
    _jumpToCurrentMatch();
    setState(() {});
  }

  void _findPrev() {
    final n = _textCtrl.matchCount;
    if (n == 0) {
      _toast('未找到');
      return;
    }
    _textCtrl.currentMatch = (_textCtrl.currentMatch - 1 + n) % n;
    _jumpToCurrentMatch();
    setState(() {});
  }

  void _jumpToCurrentMatch() {
    final pos = _textCtrl.currentMatchStart;
    final end = _textCtrl.currentMatchEnd;
    if (pos < 0) return;
    _textCtrl.selection = TextSelection(
      baseOffset: pos,
      extentOffset: end,
    );
  }

  void _replaceCurrent() {
    final n = _textCtrl.matchCount;
    if (n == 0) {
      _findNext();
      return;
    }
    final pos = _textCtrl.currentMatchStart;
    final end = _textCtrl.currentMatchEnd;
    if (pos < 0) {
      _findNext();
      return;
    }
    final text = _textCtrl.text;
    final next = text.replaceRange(pos, end, _replaceCtrl.text);
    _textCtrl.text = next;
    _recomputeMatches();
    _findNext();
  }

  void _replaceAll() {
    final q = _findCtrl.text;
    if (q.isEmpty) {
      _toast('请输入要查找的内容');
      return;
    }
    if (_useRegex) {
      try {
        final re = RegExp(q,
            caseSensitive: _caseSensitive, multiLine: true);
        _textCtrl.text =
            _textCtrl.text.replaceAll(re, _replaceCtrl.text);
      } catch (e) {
        _toast('正则无效：$e');
        return;
      }
    } else {
      if (_caseSensitive) {
        _textCtrl.text =
            _textCtrl.text.replaceAll(q, _replaceCtrl.text);
      } else {
        final re = RegExp(RegExp.escape(q),
            caseSensitive: false, multiLine: true);
        _textCtrl.text =
            _textCtrl.text.replaceAll(re, _replaceCtrl.text);
      }
    }
    _recomputeMatches();
    _toast('全部替换完成');
  }

  // ==================== 按钮栏 ====================

  Widget _buildToolbar() {
    final rules = ref.watch(toolbarRulesOrderedProvider);
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
                      '点 + 添加常用按钮（长按按钮编辑）',
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
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 7,
                        ),
                        child: GestureDetector(
                          onTap: () => _applyToolbarRule(r),
                          onLongPress: () => _editToolbarRule(r),
                          child: Container(
                            constraints:
                                const BoxConstraints(maxWidth: 160),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12),
                            decoration: BoxDecoration(
                              color: s.primaryContainer,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: s.primary.withOpacity(0.3),
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: s.onPrimaryContainer,
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
            tooltip: '排序按钮',
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
      final next = applyOneRule(_textCtrl.text, rule);
      _textCtrl.text = next;
      if (_findCtrl.text.isNotEmpty) _recomputeMatches();
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
      builder: (_) =>
          const RuleEditorDialog(showCopyToPreprocess: false),
    );
    if (rule == null || !mounted) return;
    ref.read(toolbarRulesProvider.notifier).add(rule);
    _toast('已添加按钮「${rule.name}」');
  }

  Future<void> _editToolbarRule(PreprocessingRule rule) async {
    final updated = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => RuleEditorDialog(
        initial: rule,
        showCopyToPreprocess: true,
        onCopyToPreprocess: (copied) {
          _toast('「${copied.name}」已复制到预处理规则');
        },
      ),
    );
    if (updated == null || !mounted) return;
    ref.read(toolbarRulesProvider.notifier).updateRule(updated);
  }

  Future<void> _showToolbarOrderDialog() async {
    final rules = ref.read(toolbarRulesOrderedProvider);
    if (rules.isEmpty) {
      _toast('还没有按钮');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => _ToolbarOrderDialog(rules: rules),
    );
  }

  // ==================== 编码切换 ====================

  Future<void> _showEncodingDialog() async {
    final r = await showDialog<_SaveEncoding>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('保存编码'),
        children: [
          for (final e in _SaveEncoding.values)
            RadioListTile<_SaveEncoding>(
              value: e,
              groupValue: _saveEncoding,
              title: Text(e.label),
              onChanged: (v) => Navigator.pop(c, v),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '检测到的编码：$_detectedEncoding\n'
              '保存时将按你选的编码写出。',
              style: Theme.of(c).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
    if (r != null && mounted) {
      setState(() => _saveEncoding = r);
      _toast('保存编码已设为 ${r.label}');
    }
  }

  // ==================== 双指缩放 ====================

  void _onPointerDown(PointerDownEvent e) {
    _touches[e.pointer] = e.localPosition;
    if (_touches.length == 2) {
      _pinchStartDist = _distBetweenTouches();
      _pinchStartFont = _fontSize;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length != 2 || _pinchStartDist <= 0) return;
    final d = _distBetweenTouches();
    if (d <= 0) return;
    final next = (_pinchStartFont * d / _pinchStartDist).clamp(8.0, 36.0);
    if ((next - _fontSize).abs() < 0.3) return;
    setState(() {
      _fontSize = next;
      if (_noWrap) _recomputeMaxLineWidth();
    });
  }

  void _onPointerEnd(PointerEvent e) {
    _touches.remove(e.pointer);
    if (_touches.length < 2) _pinchStartDist = 0;
  }

  double _distBetweenTouches() {
    final pts = _touches.values.toList(growable: false);
    if (pts.length < 2) return 0;
    return (pts[0] - pts[1]).distance;
  }

  // ==================== 查找栏 ====================

  Widget _buildFindBar() {
    final s = Theme.of(context).colorScheme;
    final count = _textCtrl.matchCount;
    final cur = count == 0 ? 0 : _textCtrl.currentMatch + 1;

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
                    _textCtrl.findQuery = '';
                    _textCtrl.recomputeMatches();
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
                    onChanged: (_) => _recomputeMatches(),
                    onSubmitted: (_) => _findNext(),
                  ),
                ),
                Text(
                  '$cur/$count',
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
                    _recomputeMatches();
                  },
                ),
                _toggle(
                  label: '区分大小写',
                  value: _caseSensitive,
                  onTap: () {
                    setState(() => _caseSensitive = !_caseSensitive);
                    _recomputeMatches();
                  },
                ),
                const Spacer(),
                if (_useRegex)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '正则模式',
                      style: TextStyle(
                        fontSize: 11,
                        color: s.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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

  // ==================== 编辑器本体 ====================

  Widget _buildEditorArea() {
    final bodyStyle = TextStyle(
      fontSize: _fontSize,
      height: 1.4,
      fontFamily: 'monospace',
    );

    final field = TextField(
      controller: _textCtrl,
      scrollController: _scrollCtrl,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      style: bodyStyle,
      decoration: InputDecoration(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        contentPadding: const EdgeInsets.all(10),
        hintText: '（空文件）',
      ),
    );

    if (_noWrap) {
      return Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerEnd,
        onPointerCancel: _onPointerEnd,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          controller: _hScrollCtrl,
          child: SizedBox(
            width: _maxLineWidth,
            child: field,
          ),
        ),
      );
    }

    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: field,
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
              onPressed: () => setState(() {
                _showFind = !_showFind;
                if (_showFind) _recomputeMatches();
              }),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                switch (v) {
                  case 'saveAs':
                    _saveAs();
                    break;
                  case 'encoding':
                    _showEncodingDialog();
                    break;
                  case 'wrap':
                    setState(() {
                      _noWrap = !_noWrap;
                      if (_noWrap) _recomputeMaxLineWidth();
                    });
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
                  value: 'encoding',
                  child: Row(
                    children: [
                      const Icon(Icons.translate),
                      const SizedBox(width: 10),
                      Text('保存编码：${_saveEncoding.label}'),
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
                  if (_processing)
                    Container(
                      width: double.infinity,
                      color: Theme.of(context)
                          .colorScheme
                          .tertiaryContainer,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        _processingText,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onTertiaryContainer,
                        ),
                      ),
                    ),
                  if (_showFind) _buildFindBar(),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: _buildEditorArea(),
                    ),
                  ),
                  Container(
                    width: double.infinity,
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceVariant
                        .withOpacity(0.4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Text(
                      '${_textCtrl.text.length} 字符 · '
                      '$_detectedEncoding → ${_saveEncoding.label}'
                      '${_noWrap ? " · 不换行" : ""}'
                      '${_dirty ? " · 未保存" : ""}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
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

// ==================== 高亮控制器 ====================

/// 自定义 TextEditingController：把所有匹配词涂黄，当前匹配涂粉。
/// 匹配位置在 recomputeMatches 时一次性算好，buildTextSpan 只读缓存。
class _HighlightController extends TextEditingController {
  String findQuery = '';
  bool useRegex = false;
  bool caseSensitive = false;

  /// 所有匹配的起止位置。
  List<int> matchStarts = const [];
  List<int> matchEnds = const [];

  /// 当前停留的匹配序号，-1 表示没有。
  int currentMatch = -1;

  int get matchCount => matchStarts.length;

  int get currentMatchStart =>
      currentMatch >= 0 && currentMatch < matchStarts.length
          ? matchStarts[currentMatch]
          : -1;

  int get currentMatchEnd =>
      currentMatch >= 0 && currentMatch < matchEnds.length
          ? matchEnds[currentMatch]
          : -1;

  static const Color _matchYellow = Color(0xFFFFF59D);
  static const Color _matchPink = Color(0xFFFF4081);

  void recomputeMatches() {
    final text = this.text;
    matchStarts = const [];
    matchEnds = const [];
    currentMatch = -1;
    if (findQuery.isEmpty || text.isEmpty) return;

    final starts = <int>[];
    final ends = <int>[];

    if (useRegex) {
      RegExp re;
      try {
        re = RegExp(findQuery,
            caseSensitive: caseSensitive, multiLine: true);
      } catch (_) {
        return;
      }
      for (final m in re.allMatches(text)) {
        if (m.start == m.end) continue;
        starts.add(m.start);
        ends.add(m.end);
      }
    } else {
      final q = caseSensitive ? findQuery : findQuery.toLowerCase();
      final t = caseSensitive ? text : text.toLowerCase();
      var from = 0;
      while (from <= t.length) {
        final i = t.indexOf(q, from);
        if (i < 0) break;
        starts.add(i);
        ends.add(i + q.length);
        from = i + q.length;
      }
    }

    matchStarts = starts;
    matchEnds = ends;
    if (starts.isNotEmpty) currentMatch = 0;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = this.text;
    if (text.isEmpty) return TextSpan(style: style, text: ' ');
    if (matchStarts.isEmpty) return TextSpan(style: style, text: text);

    final spans = <InlineSpan>[];
    var last = 0;
    for (var i = 0; i < matchStarts.length; i++) {
      final s = matchStarts[i];
      final e = matchEnds[i];
      if (s < last) continue;
      if (s > last) {
        spans.add(TextSpan(text: text.substring(last, s)));
      }
      final isCurrent = i == currentMatch;
      spans.add(TextSpan(
        text: text.substring(s, e),
        style: TextStyle(
          backgroundColor: isCurrent ? _matchPink : _matchYellow,
          fontWeight: FontWeight.bold,
        ),
      ));
      last = e;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return TextSpan(style: style, children: spans);
  }
}

// ==================== 按钮排序对话框 ====================

class _ToolbarOrderDialog extends ConsumerStatefulWidget {
  const _ToolbarOrderDialog({required this.rules});

  final List<PreprocessingRule> rules;

  @override
  ConsumerState<_ToolbarOrderDialog> createState() =>
      _ToolbarOrderDialogState();
}

class _ToolbarOrderDialogState extends ConsumerState<_ToolbarOrderDialog> {
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
      title: const Text('按钮排序'),
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
              trailing: IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  setState(() => _rules.removeAt(i));
                },
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

  void _save() {
    ref
        .read(toolbarOrderProvider.notifier)
        .setAll(_rules.map((r) => r.id).toList());
    ref.read(toolbarRulesProvider.notifier).setAll(_rules);
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
  }
}
