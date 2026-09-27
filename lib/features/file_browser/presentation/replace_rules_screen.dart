import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/persistent_notifier.dart';
import '../../import/presentation/providers/import_providers.dart';

/// 规则表编辑页。
///
/// 两种模式共用一套 UI：
///   - 规则表（普通文字）：AC 一次扫描，同位置按行号优先
///   - 规则表（支持正则）：逐条 replaceAll，严格按行顺序
///
/// 顶部灰色说明可点击 → 打开详细说明弹窗（可编辑、各自一份）。
/// 底部有测试区，默认收起；展开后实时更新。
class ReplaceRulesScreen extends ConsumerStatefulWidget {
  const ReplaceRulesScreen({required this.isRegex, super.key});

  final bool isRegex;

  @override
  ConsumerState<ReplaceRulesScreen> createState() =>
      _ReplaceRulesScreenState();
}

class _ReplaceRulesScreenState extends ConsumerState<ReplaceRulesScreen> {
  late final TextEditingController _ctrl;
  late final TextEditingController _testInputCtrl;
  bool _dirty = false;

  /// 测试区是否展开。
  bool _testExpanded = false;

  /// 测试结果文本。
  String _testResult = '';

  Timer? _testDebounce;

  String get _title =>
      widget.isRegex ? '规则表（支持正则）' : '规则表（普通文字）';

  String get _defaultHelp =>
      widget.isRegex ? _regexHelpText : _keywordHelpText;

  NotifierProvider<StringPrefNotifier, String> get _provider =>
      widget.isRegex ? regexRulesTextProvider : keywordRulesTextProvider;

  NotifierProvider<StringPrefNotifier, String> get _helpProvider =>
      widget.isRegex ? regexRulesHelpProvider : keywordRulesHelpProvider;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ref.read(_provider));
    _testInputCtrl = TextEditingController();
    _ctrl.addListener(() {
      if (!_dirty) setState(() => _dirty = true);
      _scheduleTestRefresh();
    });
    _testInputCtrl.addListener(_scheduleTestRefresh);
  }

  void _scheduleTestRefresh() {
    if (!_testExpanded) return;
    _testDebounce?.cancel();
    _testDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _runTest();
    });
  }

  void _runTest() {
    final input = _testInputCtrl.text;
    if (input.isEmpty) {
      setState(() => _testResult = '');
      return;
    }
    final rules = _ctrl.text;
    final String out;
    try {
      out = widget.isRegex
          ? applyRegexRules(input, rules)
          : applyKeywordRules(input, rules);
    } catch (e) {
      setState(() => _testResult = '【执行出错】$e');
      return;
    }
    setState(() => _testResult = out);
  }

  void _toggleTestExpanded() {
    setState(() {
      _testExpanded = !_testExpanded;
      if (_testExpanded) {
        _runTest();
      } else {
        _testResult = '';
      }
    });
  }

  @override
  void dispose() {
    _testDebounce?.cancel();
    _ctrl.dispose();
    _testInputCtrl.dispose();
    super.dispose();
  }

  void _save() {
    ref.read(_provider.notifier).update(_ctrl.text);
    setState(() => _dirty = false);
    ref.read(importRevisionProvider.notifier).state++;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$_title 已保存')),
    );
  }

  Future<void> _openHelp() async {
    final current = ref.read(_helpProvider);
    final content = current.isEmpty ? _defaultHelp : current;
    final saved = await showDialog<String>(
      context: context,
      builder: (_) => _RulesHelpDialog(
        title: _title,
        initialText: content,
      ),
    );
    if (saved != null && mounted) {
      ref.read(_helpProvider.notifier).update(saved);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('说明已保存')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final lineCount =
        _ctrl.text.isEmpty ? 0 : _ctrl.text.split('\n').length;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('放弃修改？'),
            content: const Text('还有未保存的修改，返回将丢失。'),
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
          title: Text(_title),
          actions: [
            TextButton.icon(
              onPressed: _dirty ? _save : null,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('保存'),
            ),
          ],
        ),
        body: Column(
          children: [
            // 顶部灰色说明（可点击，弹出详细说明弹窗）
            InkWell(
              onTap: _openHelp,
              child: Container(
                width: double.infinity,
                color: s.surfaceVariant.withOpacity(0.4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.isRegex
                            ? '每行一条正则。用 ->=> 分隔"匹配"和"替换"：\n'
                                r'  \d+->=>数字      把连续数字换成"数字"'
                                '\n'
                                r'  \d+              删除连续数字' '\n'
                                '  非法正则会被跳过，不影响其它行。'
                            : '每行一条。用 ->=> 分隔"匹配"和"替换"：\n'
                                '  xx小说网->=>起点      把"xx小说网"换成"起点"\n'
                                '  xx小说网             删除"xx小说网"\n'
                                '  特殊字符（. * + ? 等）按普通文字处理。',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: s.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: s.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: TextField(
                  controller: _ctrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    fontFamily: 'monospace',
                  ),
                  decoration: const InputDecoration(
                    hintText: '每行一条规则…',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(8),
                  ),
                ),
              ),
            ),
            // 测试区（默认收起）
            _buildTestPanel(s),
            // 底部行数提示
            Container(
              width: double.infinity,
              color: s.surface,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                '共 $lineCount 行${_dirty ? " · 未保存" : ""}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestPanel(ColorScheme s) {
    return Container(
      color: s.surfaceVariant.withOpacity(0.25),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: _toggleTestExpanded,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _testExpanded
                        ? Icons.expand_more
                        : Icons.chevron_right,
                    size: 18,
                    color: s.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '测试区',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: s.onSurface,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _testExpanded ? '收起' : '展开',
                    style: TextStyle(
                      fontSize: 11,
                      color: s.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_testExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '输入测试文本：',
                    style: TextStyle(
                      fontSize: 11,
                      color: s.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _testInputCtrl,
                    minLines: 2,
                    maxLines: 4,
                    style: const TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                    decoration: const InputDecoration(
                      hintText: '输入一段文本…',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.all(8),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '处理结果：',
                    style: TextStyle(
                      fontSize: 11,
                      color: s.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 40),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: s.surface,
                      border: Border.all(color: s.outlineVariant),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      _testResult.isEmpty ? '(空)' : _testResult,
                      style: const TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ==================== 详细说明弹窗 ====================

class _RulesHelpDialog extends StatefulWidget {
  const _RulesHelpDialog({
    required this.title,
    required this.initialText,
  });

  final String title;
  final String initialText;

  @override
  State<_RulesHelpDialog> createState() => _RulesHelpDialogState();
}

class _RulesHelpDialogState extends State<_RulesHelpDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(4),
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.title} · 详细说明',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _ctrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 14, height: 1.6),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(12),
                    hintText: '在这里编辑详细说明…',
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _ctrl.text),
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 默认详细说明 ====================

const String _keywordHelpText = r'''
【规则表（普通文字）· 详细说明】

每行一条。用 ->=> 分隔"匹配"和"替换"：
  xx小说网->=>起点      把"xx小说网"换成"起点"
  xx小说网             删除"xx小说网"
  特殊字符（. * + ? 等）按普通文字处理。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

■ 执行方式

所有规则一起扫描，一次完成。不是一条一条执行的。
性能最好，几万条规则也不会慢。

■ 同一位置多条规则命中时

按行号优先——哪条规则在文本里行号靠前，就用哪条。

例：
  行1: 。。->=>q
  行2: 。。。。->=>d
  行3: 。。。。。。->=>b

  输入 "。。。。。。。"（7 个点）
  位置 0 三条规则都命中 → 选行号最小的（行1 的 。。->q）
  结果：qqqq。

  想让"长"的规则优先？把它写在最上面：
  行1: 。。。。。。->=>b
  行2: 。。。。->=>d
  行3: 。。->=>q

  输入 "。。。。。。。"（7 个点）
  结果：b

■ 新产生的文本不再参与

一次扫描。A 换成 B 后，新出来的 B 不会再被后面的规则处理。

例：
  行1: a->=>b
  行2: b->=>c

  输入 "a"
  结果："b"（不是 "c"，因为新出来的 b 不参与后续处理）

■ 替换串里的转义

  \n   → 换行
  \r   → 回车
  \t   → Tab
  \\   → 反斜杠
  \0   → 空字符

■ 高性能场景

大量删除/替换（比如几千条水印），用这个规则表。
Aho-Corasick 一次扫描命中所有词，规则再多也不慢。
''';

const String _regexHelpText = r'''
【规则表（支持正则）· 详细说明】

每行一条正则。用 ->=> 分隔"匹配"和"替换"：
  \d+->=>数字      把连续数字换成"数字"
  \d+              删除连续数字
  非法正则会被跳过，不影响其它行。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

■ 执行方式

严格按行顺序，从上到下依次执行。
前一条的结果，就是后一条的输入。

例：
  行1: a->=>b
  行2: b->=>c

  输入 "a"
  行1 处理 → "b"
  行2 处理 "b" → "c"
  结果："c"

■ 与普通文字表的区别

普通文字表：一次扫描，所有规则同时生效；新产生的文本不参与。
正则表：按行顺序执行，前一步的结果会影响后一步。

■ 替换串里的引用

  $1 $2 ...  → 引用捕获组（查找串里第 1、2 对括号匹配到的内容）
  $0        → 整个匹配到的内容

例：
  查找：(\d+)-(\d+)
  替换：$2-$1
  输入："12-34"
  结果："34-12"

■ 替换串里的转义

  \n \r \t \\ \0  同普通文字表。

■ 性能提示

每条规则一遍扫描。规则越多越慢。
大量规则的场景，优先用普通文字表。

■ 匹配无关字符时自动跳过

查找串不含正则元字符的（比如就是一个普通词），会走快速路径。
''';
