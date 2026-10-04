import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../import/presentation/providers/import_providers.dart';

/// 规则表编辑页。
///
/// 两种模式共用一套 UI：
///   - 规则表（普通文字）：AC 一次扫描，同位置按行号优先
///   - 规则表（支持正则）：逐条 replaceAll，严格按行顺序
///
/// 顶部一行提示，点击 → 打开详细说明弹窗（可编辑、各自一份）。
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
            // ========== 改动（B19）：右上角保存按钮文字 ==========
            TextButton.icon(
              onPressed: _dirty ? _save : null,
              icon: Icon(
                Icons.save,
                size: 18,
                color: _dirty ? AppColors.accentPurple : null,
              ),
              label: Text(
                '保存',
                style: TextStyle(
                  color: _dirty ? AppColors.accentPurple : null,
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            // 顶部一行提示（可点击，弹出详细说明弹窗）
            InkWell(
              onTap: _openHelp,
              child: Container(
                width: double.infinity,
                color: s.surfaceVariant.withOpacity(0.4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: s.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '每行一条。点击查看详细说明 →',
                        style: TextStyle(
                          fontSize: 12,
                          color: s.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
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
                // ========== 改动（B19）：详情弹窗大编辑框 ==========
                child: TextField(
                  controller: _ctrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  cursorColor: AppColors.accentPurple,
                  style: const TextStyle(fontSize: 14, height: 1.6),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: AppColors.accentPurple,
                        width: 2,
                      ),
                    ),
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

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 基本写法
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

每行一条。用 ->=> 分隔"匹配"和"替换"：

  xx小说网->=>起点      把"xx小说网"换成"起点"
  xx小说网             删除"xx小说网"（没有 ->=> 就是删除）

特殊字符（. * + ? ( ) [ ] { } | \ ^ $）按**普通文字**处理，没有特殊含义。
比如写 `.` 就是匹配一个点号，不是"任意字符"。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 你输入的东西会怎样
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

这一节讲"输入法按的键"和"实际产生的字符"的关系。这俩不是一回事。

【按键 → 产生什么字符】
  按空格键       → 产生一个空格字符（U+0020）
  按 Tab 键      → 产生一个 Tab 字符（U+0009）
  按回车键       → 产生一个换行字符（U+000A）
  从别处粘贴     → 原样的所有字符（可能带换行、空格、隐藏字符）

【产生的字符 → 本表怎么处理】

  空格字符       ✅ 保留，能当查找词
                  （首、中、尾都能，打一个空格也行）
  Tab 字符       ✅ 保留，能当查找词
  全角空格       ✅ 保留，能当查找词
  隐藏字符       ✅ 保留，能当查找词
                  （零宽空格、BOM、软连字符等，从别处粘贴来的都行）
  换行字符       ❌ 被当"规则分隔符"，切成两条规则
                  （按回车键产生的那种）
  完全空行       ❌ 跳过
                  （连续按两次回车，中间那行是空的）

【具体例子】

  你输入"一个空格->=>"：
    改后 → 有效规则，匹配文本里所有空格，替换成空。

  你输入"逗号+空格->=>逗号"：
    改后 → 匹配"逗号后跟一个空格"，替换成"逗号"。

  你输入"空格+abc"：
    改后 → 匹配"空格+abc"。

  你输入"abc"后面打了个空格：
    改后 → 匹配"abc+空格"，不是只匹配"abc"。想只匹配 abc，请把空格删掉。

  你按回车键想换行：
    → 变成"分两条规则"，不是"匹配换行"。

【想匹配换行怎么办】
  用内置规则或单条规则（正则）。本表做不到。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 关于 \n \s 这种写法
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

本表**按字面理解**，不做转义。

  写 \n → 匹配"反斜杠 + n"两个字符，不是换行
  写 \s → 匹配"反斜杠 + s"两个字符，不是空白

只有**替换串**里才支持这几个转义：

  \n   → 换行
  \r   → 回车
  \t   → Tab
  \\   → 反斜杠
  \0   → 空字符

查找串里的 \ 一律按字面（因为查找是普通文字匹配，不认转义）。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 执行方式
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

所有规则一起扫描，**一次完成**。不是一条一条执行的。
性能最好，几万条规则也不会慢。

■ 同一位置多条规则命中时

按行号优先——哪条规则在文本里**行号靠前**，就用哪条。

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

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 高性能场景
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

大量删除/替换（比如几千条水印），用这个规则表。
Aho-Corasick 一次扫描命中所有词，规则再多也不慢。
''';

const String _regexHelpText = r'''
【规则表（支持正则）· 详细说明】

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 基本写法
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

每行一条正则。用 ->=> 分隔"匹配"和"替换"：

  \d+->=>数字      把连续数字换成"数字"
  \d+              删除连续数字（没有 ->=> 就是删除）

非法正则会被跳过，不影响其它行。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 你输入的东西会怎样
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

这一节讲"输入法按的键"和"实际产生的字符"的关系。这俩不是一回事。

【按键 → 产生什么字符】
  按空格键       → 产生一个空格字符（U+0020）
  按 Tab 键      → 产生一个 Tab 字符（U+0009）
  按回车键       → 产生一个换行字符（U+000A）
  从别处粘贴     → 原样的所有字符（可能带换行、空格、隐藏字符）

【产生的字符 → 本表怎么处理】

  空格字符       ✅ 保留，能当正则的一部分
                  （首、中、尾都能，打一个空格也行）
  Tab 字符       ✅ 保留，能当正则的一部分
  全角空格       ✅ 保留，能当正则的一部分
  隐藏字符       ✅ 保留，能当正则的一部分
                  （零宽空格、BOM、软连字符等）
  换行字符       ❌ 被当"规则分隔符"，切成两条规则
                  （按回车键产生的那种）

【具体例子】

  你输入"一个空格->=>"：
    → 正则匹配一个空格字符，替换成空。

  你输入"abc"后面打了个空格：
    → 正则匹配"abc+空格"，不是只匹配 abc。想只匹配 abc，请把空格删掉。

  你按回车键想换行：
    → 变成"分两条正则"，不是"正则里包含换行"。

【想匹配换行怎么办】
  在正则里写 \n（正则引擎认识的转义）。
  注意：换行是规则分隔符，本表里**手打回车**不行，但**写 \n 可以**。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 关于 \n \s 这种写法（和普通文字表不同！）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

本表是**正则**，所以正则的转义在这里生效：

  \n  → 换行
  \r  → 回车
  \t  → Tab
  \s  → 任意空白（空格 / Tab / 换行）
  \d  → 任意数字
  \w  → 字母、数字或下划线
  \\  → 一个反斜杠

【和普通文字表的区别】

  同一个 \n：
    普通文字表 → 匹配"反斜杠 + n"两个字面字符
    正则表     → 匹配"换行"

写规则时注意区分，别把两个表的行为搞混。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 执行方式
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

严格按行顺序，**从上到下依次执行**。
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

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 替换串里的引用
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  $1 $2 ...  → 引用捕获组（查找串里第 1、2 对括号匹配到的内容）
  $0        → 整个匹配到的内容

例：
  查找：(\d+)-(\d+)
  替换：$2-$1
  输入："12-34"
  结果："34-12"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 替换串里的转义
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  \n \r \t \\ \0  同普通文字表。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ 性能提示
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

每条规则一遍扫描。规则越多越慢。
大量规则的场景，优先用普通文字表。

■ 匹配无关字符时自动跳过

查找串不含正则元字符的（比如就是一个普通词），会走快速路径。
''';
