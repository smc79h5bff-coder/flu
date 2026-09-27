import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../edit/application/edit_saver.dart';
import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/application/preprocessing_service.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';
import '../../viewer/presentation/providers/toolbar_rules_provider.dart';
import 'comparison_settings_screen.dart'
    show RuleEditorDialog, ruleSubtitle;

/// 单文件编辑器。
///
/// 从文件浏览器点文本类文件进入。
/// 顶部按钮栏跟对比页共用同一套规则（toolbar_rules_provider）。
/// 点按钮直接执行，不弹"改哪侧"。
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
  final TextEditingController _textCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _findCtrl = TextEditingController();
  final TextEditingController _replaceCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _showFind = false;
  bool _processing = false;
  String _processingText = '';
  String _encoding = '';

  @override
  void initState() {
    super.initState();
    _textCtrl.addListener(_onTextChanged);
    _load();
  }

  @override
  void dispose() {
    _textCtrl.removeListener(_onTextChanged);
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (!_dirty) setState(() => _dirty = true);
  }

  // ==================== 加载 / 保存 ====================

  Future<void> _load() async {
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      final enc = EncodingDetector.detect(bytes);
      final text = EncodingDetector.decodeChunked(bytes, enc);
      if (!mounted) return;
      setState(() {
        _textCtrl.text = text;
        _dirty = false;
        _encoding = enc.label;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取失败：$e');
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      const saver = EditSaver();
      await saver.saveOverwrite(widget.filePath, _textCtrl.text);
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

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('有未保存的修改'),
        content: const Text('返回将丢失改动，确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('放弃并返回'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(c, true);
              _save();
            },
            child: const Text('保存并返回'),
          ),
        ],
      ),
    );
    return r == true;
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

  // ==================== 查找替换 ====================

  void _findNext() {
    final q = _findCtrl.text;
    if (q.isEmpty) return;
    final text = _textCtrl.text;
    final sel = _textCtrl.selection;
    final startFrom = sel.isValid && !sel.isCollapsed
        ? sel.end
        : (sel.isValid ? sel.end : 0);
    var idx = text.indexOf(q, startFrom);
    if (idx < 0) {
      idx = text.indexOf(q);
      if (idx < 0) {
        _toast('未找到');
        return;
      }
    }
    _textCtrl.selection = TextSelection(
      baseOffset: idx,
      extentOffset: idx + q.length,
    );
  }

  void _replaceCurrent() {
    final q = _findCtrl.text;
    if (q.isEmpty) return;
    final sel = _textCtrl.selection;
    if (!sel.isValid || sel.isCollapsed) {
      _findNext();
      return;
    }
    final selected = _textCtrl.text.substring(sel.start, sel.end);
    if (selected != q) {
      _findNext();
      return;
    }
    final text = _textCtrl.text;
    final newText = text.replaceRange(sel.start, sel.end, _replaceCtrl.text);
    _textCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: sel.start + _replaceCtrl.text.length,
      ),
    );
    _findNext();
  }

  void _replaceAll() {
    final q = _findCtrl.text;
    if (q.isEmpty) {
      _toast('请输入要查找的内容');
      return;
    }
    final newText = _textCtrl.text.replaceAll(q, _replaceCtrl.text);
    _textCtrl.text = newText;
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
                            constraints: const BoxConstraints(maxWidth: 160),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
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

  // ==================== 查找替换栏 ====================

  Widget _buildFindBar() {
    final s = Theme.of(context).colorScheme;
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
                  onPressed: () => setState(() => _showFind = false),
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
                    onSubmitted: (_) => _findNext(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_up),
                  tooltip: '上一个',
                  visualDensity: VisualDensity.compact,
                  onPressed: _findNext,
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down),
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
          ],
        ),
      ),
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
              icon: const Icon(Icons.search),
              tooltip: '查找 / 替换',
              onPressed: () => setState(() => _showFind = !_showFind),
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
                      color: Theme.of(context).colorScheme.tertiaryContainer,
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
                      child: TextField(
                        controller: _textCtrl,
                        scrollController: _scrollCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          fontFamily: 'monospace',
                        ),
                        decoration: InputDecoration(
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          contentPadding: const EdgeInsets.all(10),
                          hintText: '（空文件）',
                        ),
                      ),
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
                      '${_textCtrl.text.length} 字符 · $_encoding'
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
