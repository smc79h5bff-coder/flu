import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../help/presentation/help_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/application/builtin_rules.dart';
import '../../preprocessing/application/js_runtime.dart';
import '../../preprocessing/application/presets.dart';
import '../../preprocessing/application/preprocessing_service.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';
import 'replace_rules_screen.dart';

/// 顶部说明笔记的 sectionId。
const String _orderNoteSectionId = 'ruleOrderTop';

/// ==================== 7 个开关的默认说明文字 ====================
const Map<String, String> _flagHelpDefaults = {
  'findRegex': r'''【查找词 · 支持正则】

开：查找词按"正则表达式"解析，特殊符号有特殊含义。
关：改由"仅字面匹配"接管（两者互斥，必须开一个）。

正则里几个常见符号：
  .     任意一个字符
  \d    任意一个数字
  \w    字母、数字或下划线
  \s    空白（空格 / Tab / 换行）
  *     前面的内容出现 0 次或多次
  +     前面的内容出现 1 次或多次
  ?     前面的内容出现 0 次或 1 次
  ()    分组。这一对括号也叫"捕获组"。
        搭配替换侧的 $1 或 \1 开关，可以"抓到内容搬走"。
        详见替换侧引用开关的说明。

例子：
  查找 \d+        开=匹配所有连续数字；关=匹配字面"\d+"
  查找 第\d+章    开=匹配"第1章""第23章"；关=匹配字面"第\d+章"

判断标准：想让查找词里的符号有"特殊含义"，就开。
只想按字面找一个固定字符串，就改成"仅字面匹配"。''',

  'findLiteral': r'''【查找词 · 仅字面匹配】

开：查找词完全按普通文字处理，任何符号都没有特殊含义。
    填什么就匹配什么。
关：由"支持正则"接管（两者互斥，必须开一个）。

跟"支持正则"的关系：互斥。
  · 开"支持正则"    → 自动关掉"仅字面匹配"
  · 开"仅字面匹配"  → 自动关掉"支持正则"
  · 两个必须有一个开着，不能同时关

例子：
  查找 a.b    仅字面=匹配"a.b"三个字；正则=匹配"a 任意 b"
  查找 a*b    仅字面=匹配"a*b"三个字；正则=匹配"b""ab""aab"等
  查找 (abc)  仅字面=匹配"(abc)"五个字；正则=捕获"abc"''',

  'findEscape': r'''【查找词 · 支持转义】

开：查找词里的转义序列会被还原成真字符，再去匹配。
关：转义序列按字面处理（\n 匹配"反斜杠+n"两个字符）。

支持的转义：
  \n   换行符
  \r   回车符
  \t   Tab 制表符
  \\   一个反斜杠
  \0   空字符（NUL）

例子：
  查找 \n    开=匹配真正的换行；关=匹配字面"反斜杠+n"
  查找 \t    开=匹配真正的 Tab；关=匹配字面"反斜杠+t"

—————— 多行匹配 ——————

你也可以直接在查找框里敲回车，输入多行文本。
敲进去的是真换行，不需要 \n，也不需要这个开关。''',

  'replaceDollar': r'''【替换词 · $1 $2 引用】

开：替换词里出现 $0 $1 $2 …… 时，会被替换成捕获组内容。
关：$0 $1 $2 …… 原样输出（字面）。
与"仅字面输出"互斥，与"\1 \2 引用"可共存。

—————— 什么是捕获组 ——————

捕获组 = 查找词里每一对圆括号 () 抓到的内容。
从左到右编号：第 1 对括号抓到的是 $1，第 2 对是 $2。
$0 表示"整个匹配到的内容"，不是括号里的。

例：查找词写 (\d+)-(\d+)
  ( \d+ )  第 1 对括号 → $1
  ( \d+ )  第 2 对括号 → $2

文本 12-34 用这个查找词：
  $0 = 12-34（整个匹配）
  $1 = 12
  $2 = 34

—————— 怎么用 ——————

例1：调换顺序
  查找：(\d+)-(\d+)
  替换：$2-$1
  结果：12-34 → 34-12

例2：日期格式转换
  查找：(\d{4})-(\d{2})-(\d{2})
  替换：$1年$2月$3日
  结果：2024-01-01 → 2024年01月01日

—————— 需要注意 ——————

· 想用 $1，查找词里必须有对应数量的 ()。
· $1 和 $10 有歧义：Dart 会优先当成 $10。
  想表示"$1 后面跟个 0"，写 ${1}0。
· 想输出字面的 $，写 \$。''',

  'replaceBackslash': r'''【替换词 · \1 \2 引用】

开：替换词里出现 \1 \2 \3 …… 时，会被替换成捕获组内容。
关：按字面输出（不展开 \1）。
与"仅字面输出"互斥，与"$1 $2 引用"可共存。

\1 和 $1 是两套写法，效果一样。
一般用 $1 就够了，\1 是备用。

只有一种情况必须用 \1：替换词里本来就要输出一个 $ 符号，
同时又要引用捕获组。''',

  'replaceLiteral': r'''【替换词 · 仅字面输出】

开：替换词完全按字面输出，不展开任何 $1 $2 或 \1 \2 引用。
关：由"$1 $2 引用"和"\1 \2 引用"接管（三者至少开一个）。

跟两个引用开关的关系：互斥。
  · 开"仅字面输出"    → 自动关掉两个引用
  · 开任一引用开关    → 自动关掉"仅字面输出"
  · 三个必须有一个开着

注意：跟"支持转义"不互斥。字面输出 + 支持转义时，\n 仍然会变真换行。''',

  'replaceEscape': r'''【替换词 · 支持转义】

开：替换词里的转义序列会被还原成真字符。
关：转义序列按字面输出（\n 输出"反斜杠+n"两个字符）。

支持的转义：
  \n   换行符
  \r   回车符
  \t   Tab 制表符
  \\   一个反斜杠
  \0   空字符（NUL）

例子：
  替换词 \n          开=输出一个真换行；关=输出"反斜杠+n"
  替换词 第$1章\n    开=每章后面跟一个真换行
  替换词 \\          开=输出一个真反斜杠''',
};

/// ==================== 列表项类型 ====================

sealed class _RuleItem {
  String get id;
  Key get key;
}

class _SingleRuleItem extends _RuleItem {
  _SingleRuleItem(this.rule);
  final PreprocessingRule rule;
  @override
  String get id => rule.id;
  @override
  Key get key => ValueKey<String>('single:${rule.id}');
}

class _KeywordBlockItem extends _RuleItem {
  _KeywordBlockItem(this.lineCount);
  final int lineCount;
  @override
  String get id => RuleBlockIds.keyword;
  @override
  Key get key => const ValueKey<String>('block:keyword');
}

class _RegexBlockItem extends _RuleItem {
  _RegexBlockItem(this.lineCount);
  final int lineCount;
  @override
  String get id => RuleBlockIds.regex;
  @override
  Key get key => const ValueKey<String>('block:regex');
}

/// ==================== 比较设置页 ====================

class ComparisonSettingsScreen extends ConsumerStatefulWidget {
  const ComparisonSettingsScreen({
    super.key,
    this.confirmOnExit = false,
  });

  /// 从对比页进入时传 true：返回时若规则变了，弹窗确认。
  /// 从文件浏览器进入时保持默认 false：静默返回。
  final bool confirmOnExit;
  @override
  ConsumerState<ComparisonSettingsScreen> createState() =>
      _ComparisonSettingsScreenState();
}

class _ComparisonSettingsScreenState
    extends ConsumerState<ComparisonSettingsScreen> {
  late final String _initialSnapshot;

  @override
  void initState() {
    super.initState();
    _initialSnapshot = comparisonRulesSnapshot(ref);
  }

  Future<void> _handleBack() async {
    final current = comparisonRulesSnapshot(ref);
    final changed = current != _initialSnapshot;

    if (!changed || !widget.confirmOnExit) {
      if (mounted) Navigator.of(context).pop(changed);
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: const Text('规则已修改'),
        content: const Text(
          '返回后，左右两边会在当前内容基础上，重新套一遍所有生效的规则。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确定返回'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildItems();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
       appBar: AppBar(
  title: GestureDetector(
    onLongPress: _showHiddenRules,
    behavior: HitTestBehavior.opaque,
    child: const Text('比较设置'),
  ),
  actions: [
            IconButton(
              icon: const Icon(Icons.help_outline),
              tooltip: '使用说明',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const HelpScreen(),
                  ),
                );
              },
            ),
          ],
        ),
        body: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: ReorderableListView.builder(
                itemCount: items.length,
                onReorder: _onReorder,
                buildDefaultDragHandles: false,
                itemBuilder: (ctx, i) => _buildTile(items[i], i),
              ),
            ),
            _buildAddButton(),
          ],
        ),
      ),
    );
  }

  List<_RuleItem> _buildItems() {
    final order = ref.watch(ruleOrderProvider);
    final byId = ref.watch(ruleByIdProvider);
    final kwText = ref.watch(keywordRulesTextProvider);
    final rgText = ref.watch(regexRulesTextProvider);

    final kwLines = kwText.isEmpty
        ? 0
        : kwText.split('\n').where((l) => l.trim().isNotEmpty).length;
    final rgLines = rgText.isEmpty
        ? 0
        : rgText.split('\n').where((l) => l.trim().isNotEmpty).length;

    final items = <_RuleItem>[];
    final seen = <String>{};

    for (final id in order) {
      if (seen.contains(id)) continue;
      if (id == RuleBlockIds.keyword) {
        items.add(_KeywordBlockItem(kwLines));
        seen.add(id);
      } else if (id == RuleBlockIds.regex) {
        items.add(_RegexBlockItem(rgLines));
        seen.add(id);
      } else {
        final r = byId[id];
        if (r != null) {
          items.add(_SingleRuleItem(r));
          seen.add(id);
        }
      }
    }

    for (final r in BuiltinRules.all()) {
      if (!seen.contains(r.id)) {
        final rule = byId[r.id];
        if (rule != null) {
          items.add(_SingleRuleItem(rule));
          seen.add(r.id);
        }
      }
    }
    if (!seen.contains(RuleBlockIds.keyword)) {
      items.add(_KeywordBlockItem(kwLines));
    }
    if (!seen.contains(RuleBlockIds.regex)) {
      items.add(_RegexBlockItem(rgLines));
    }

    return items;
  }

  void _onReorder(int oldIndex, int newIndex) {
    final items = _buildItems();
    if (oldIndex < 0 || oldIndex >= items.length) return;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex < 0) newIndex = 0;
    if (newIndex > items.length - 1) newIndex = items.length - 1;
    if (oldIndex == newIndex) return;

    final moved = items.removeAt(oldIndex);
    items.insert(newIndex, moved);

    final newOrder = items.map((it) => it.id).toList();
    ref.read(ruleOrderProvider.notifier).setAll(newOrder);

    if (newOrder.isNotEmpty && newOrder.first == 'ig_empty') {
      _toast('「删掉空行」在最前会改变行数，编辑回写可能错位');
    }
  }

  Widget _buildTile(_RuleItem item, int index) {
    final dragHandle = ReorderableDragStartListener(
      index: index,
      child: const SizedBox(
        width: 54,
        height: 44,
        child: Center(child: Icon(Icons.drag_handle)),
      ),
    );

    if (item is _SingleRuleItem) {
      return _buildSingleTile(item, dragHandle);
    }
    if (item is _KeywordBlockItem) {
      return _buildBlockTile(
        key: item.key,
        dragHandle: dragHandle,
        icon: Icons.text_fields,
        title: '规则表（普通文字）',
        subtitle: '一整块文本 · ${item.lineCount} 行',
        onTap: () => _openReplaceRules(isRegex: false),
      );
    }
    final regexItem = item as _RegexBlockItem;
    return _buildBlockTile(
      key: regexItem.key,
      dragHandle: dragHandle,
      icon: Icons.code,
      title: '规则表（支持正则）',
      subtitle: '一整块文本 · ${regexItem.lineCount} 行',
      onTap: () => _openReplaceRules(isRegex: true),
    );
  }

  Widget _buildSingleTile(_SingleRuleItem item, Widget dragHandle) {
    final rule = item.rule;
    final preview = _shortPreview(rule);

    return Container(
      key: item.key,
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        children: [
          dragHandle,
          Expanded(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
  onLongPress: () => _showRuleDetail(rule),
  behavior: HitTestBehavior.opaque,
  child: Text(
    rule.name,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(fontSize: 14),
  ),
),
                  
                  const SizedBox(height: 2),
                  GestureDetector(
                    onLongPress: () => _showRuleDetail(rule),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: LayoutBuilder(
                        builder: (ctx, constraints) => _buildTwoDotsText(
                          preview,
                          constraints.maxWidth,
                          TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Switch(
            value: rule.enabled,
            onChanged: (v) {
              if (rule.isBuiltin) {
                ref
                    .read(builtinRuleEnablesProvider.notifier)
                    .setOne(rule.id, v);
              } else {
                ref
                    .read(userRulesProvider.notifier)
                    .updateRule(rule.copyWith(enabled: v));
              }
            },
          ),
          if (!rule.isBuiltin)
            SizedBox(
              width: 52,
              child: IconButton(
                tooltip: '编辑',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _editUserRule(rule),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTwoDotsText(String text, double maxWidth, TextStyle style) {
    if (text.isEmpty) return Text('', style: style);

    final full = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: maxWidth);
    if (!full.didExceedMaxLines) {
      return Text(text, style: style, maxLines: 1);
    }

    var lo = 0;
    var hi = text.length;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      final tp = TextPainter(
        text: TextSpan(text: '${text.substring(0, mid)}..', style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: maxWidth);
      if (tp.didExceedMaxLines) {
        hi = mid - 1;
      } else {
        lo = mid;
      }
    }
    return Text('${text.substring(0, lo)}..', style: style, maxLines: 1);
  }

  String _shortPreview(PreprocessingRule rule) {
    if (rule.script != null && rule.script!.isNotEmpty) {
      return '内置实现 · ${rule.script}';
    }
    switch (rule.kind) {
      case RuleKind.preset:
        final preset = Presets.byId(rule.presetId ?? '');
        return preset == null ? '预置功能' : '预置 · ${preset.name}';
      case RuleKind.js:
        return 'JS 脚本';
      case RuleKind.replace:
        if (rule.findPattern.isEmpty) return '(无内容)';
        final action = rule.replaceWith.isEmpty
            ? '删除'
            : '替换为「${rule.replaceWith}」';
        return '/${rule.findPattern}/ $action';
    }
  }
/// 取规则的详细说明。
String? _resolveHelpText(PreprocessingRule rule) {
  if (rule.helpText != null && rule.helpText!.isNotEmpty) {
    return rule.helpText;
  }
  if (rule.kind == RuleKind.preset && rule.presetId != null) {
    final preset = Presets.byId(rule.presetId!);
    if (preset != null && preset.helpText.isNotEmpty) {
      return preset.helpText;
    }
  }
  return null;
}


  Future<void> _showRuleDetail(PreprocessingRule rule) async {
  // 主内容 = ruleSubtitle 的输出。
  // 如果有 helpText，拼到下面一起显示。
  final detail = ruleSubtitle(rule);
  final helpText = _resolveHelpText(rule);
  final kindLabel = switch (rule.kind) {
      RuleKind.replace => '查找替换',
      RuleKind.preset => '预置功能',
      RuleKind.js => 'JS 脚本',
    };
    final scopeLabel = switch (rule.scope) {
      RuleScope.both => '两侧文件',
      RuleScope.originalOnly => '仅左侧文件',
      RuleScope.modifiedOnly => '仅右侧文件',
    };

    final action = await showDialog<String>(
      context: context,
      builder: (c) {
        final s = Theme.of(c).colorScheme;
        return AlertDialog(
          insetPadding: const EdgeInsets.all(8),
          titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  rule.name,
                  style: const TextStyle(fontSize: 16),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (rule.isBuiltin)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    '内置',
                    style: TextStyle(
                      fontSize: 11,
                      color: s.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(c).size.height * 0.6,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _tag(kindLabel, s),
                      const SizedBox(width: 6),
                      _tag(scopeLabel, s),
                      const SizedBox(width: 6),
                      _tag(rule.enabled ? '已启用' : '已禁用', s),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  SelectableText(
  () {
    final main = detail.isEmpty ? '(无内容)' : detail;
    if (helpText == null || helpText.isEmpty) {
      return main;
    }
    return '$main\n\n${'─' * 30}\n\n$helpText';
  }(),
  style: const TextStyle(
    fontSize: 13,
    height: 1.6,
    fontFamily: 'monospace',
  ),
),
                  
                  if (rule.implType != null) ...[
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    Text(
                      '实现方式',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: s.primary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '类型：${rule.implType}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (rule.implDetail != null) ...[
                      const SizedBox(height: 4),
                      SelectableText(
                        rule.implDetail!,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ],
                  if (rule.replacementType != null) ...[
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    Text(
                      '替代方案',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: s.primary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          rule.replacementType == 'ok'
                              ? '✅'
                              : rule.replacementType == 'warn'
                                  ? '⚠️'
                                  : '❌',
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          rule.replacementType == 'ok'
                              ? '可以用正则替代'
                              : rule.replacementType == 'warn'
                                  ? '可替代，但不建议'
                                  : '无法用正则替代',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                    if (rule.replacementDetail != null) ...[
                      const SizedBox(height: 6),
                      SelectableText(
                        rule.replacementDetail!,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                    if (rule.replacementNote != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        rule.replacementNote!,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.4,
                          color: s.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (rule.isBuiltin) ...[
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, 'rename'),
                child: const Text('重命名'),
              ),
              
    TextButton(
      style: TextButton.styleFrom(foregroundColor: Colors.red),
      onPressed: () => Navigator.pop(c, 'hide'),
      child: const Text('隐藏'),
    ),

              
            ] else ...[
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, 'edit'),
                child: const Text('编辑'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                onPressed: () => Navigator.pop(c, 'delete'),
                child: const Text('删除'),
              ),
            ],
          ],
        );
      },
    );

     if (!mounted) return;
  if (action == 'rename') {
    await _renameBuiltinRule(rule);
  } else if (action == 'edit') {
    await _editUserRule(rule);
  } else if (action == 'delete') {
    await _confirmDeleteRule(rule);
  } else if (action == 'hide') {
    await _confirmHideBuiltinRule(rule);
  }
}

  Widget _tag(String text, ColorScheme s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: s.secondaryContainer.withOpacity(0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: s.onSecondaryContainer,
        ),
      ),
    );
  }

  /// 重命名内置规则。
  Future<void> _renameBuiltinRule(PreprocessingRule rule) async {
    final ctrl = TextEditingController(text: rule.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: const Text('重命名内置规则'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '新名字',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, ''),
            child: const Text('恢复默认'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (newName == null || !mounted) return;

    ref
        .read(builtinRuleNameOverridesProvider.notifier)
        .setOne(rule.id, newName);
    if (newName.trim().isEmpty) {
      _toast('已恢复默认名');
    } else {
      _toast('已重命名');
    }
  }

  Future<void> _confirmDeleteRule(PreprocessingRule rule) async {
    if (rule.isBuiltin) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: const Text('删除规则？'),
        content: Text('「${rule.name}」将被删除，无法恢复。'),
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
    if (ok == true && mounted) {
      ref.read(userRulesProvider.notifier).remove(rule.id);
      _toast('已删除「${rule.name}」');
    }
  }
Future<void> _confirmHideBuiltinRule(PreprocessingRule rule) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      title: const Text('隐藏此条内置规则？'),
      content: Text(
        '「${rule.name}」将不再出现在规则列表里。\n'
        '配置不会删除，长按左上角“比较设置”随时可以恢复。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('隐藏'),
        ),
      ],
    ),
  );
  if (ok == true && mounted) {
    ref.read(builtinRuleHiddenProvider.notifier).hide(rule.id);
    _toast('已隐藏「${rule.name}」');
  }
}

Future<void> _showHiddenRules() async {
  final hidden = ref.read(builtinRuleHiddenProvider);
  if (hidden.isEmpty) return;

  final all = <String, PreprocessingRule>{
    for (final r in BuiltinRules.all()) r.id: r,
  };

  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      title: const Text('已隐藏的内置规则'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(c).size.height * 0.5,
        child: Consumer(
          builder: (c, ref, _) {
            final hidden = ref.watch(builtinRuleHiddenProvider);
            final ids = hidden.toList();
            if (ids.isEmpty) {
              return const Center(child: Text('（空）'));
            }
            return ListView.builder(
              itemCount: ids.length,
              itemBuilder: (ctx, i) {
                final id = ids[i];
                final r = all[id];
                return ListTile(
                  dense: true,
                  title: Text(r?.name ?? id),
                  subtitle: r == null
                      ? null
                      : Text(
                          '/${r.findPattern}/',
                          style: const TextStyle(fontSize: 11),
                        ),
                  trailing: TextButton(
                    onPressed: () {
                      ref
                          .read(builtinRuleHiddenProvider.notifier)
                          .restore(id);
                    },
                    child: const Text('恢复'),
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('关闭'),
        ),
        TextButton(
          onPressed: () {
            ref.read(builtinRuleHiddenProvider.notifier).restoreAll();
            Navigator.pop(c);
          },
          child: const Text('全部恢复'),
        ),
      ],
    ),
  );
}
  Widget _buildBlockTile({
    required Key key,
    required Widget dragHandle,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
      child: Material(
        color: s.secondaryContainer.withOpacity(0.35),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Row(
            children: [
              dragHandle,
              Icon(icon, color: s.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: s.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  // ========== 改动（B17）：顶部笔记图标 ==========
  Widget _buildHeader() {
    final s = Theme.of(context).colorScheme;
    final notes = ref.watch(_notesProvider);
    final hasNote = (notes[_orderNoteSectionId] ?? '').trim().isNotEmpty;

    return Material(
      color: const Color(0xFFF3FFDA),
      child: InkWell(
        onTap: _openOrderNoteDialog,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '从上到下，依次执行',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: s.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '按住左侧手柄上下拖动调整顺序。点这里可写笔记。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: s.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                hasNote ? Icons.sticky_note_2 : Icons.sticky_note_2_outlined,
                size: 20,
                color: hasNote ? AppColors.accentPurple : s.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openOrderNoteDialog() async {
    final notes = ref.read(_notesProvider);
    final existing = notes[_orderNoteSectionId] ?? '';
    final ctrl = TextEditingController(text: existing);

    final saved = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        title: const Text('执行顺序 · 笔记'),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.75,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '规则从上到下依次执行。拖动左侧手柄调整顺序。\n'
                '「删掉空行」会改变行数，拖到最前时行号可能错位。',
                style: Theme.of(c).textTheme.labelSmall,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: ctrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  autofocus: true,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                  decoration: const InputDecoration(
                    hintText: '在这里记点什么…',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(10),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (saved != null) {
      ref.read(_notesProvider.notifier).setOne(_orderNoteSectionId, saved);
    }
  }

  Widget _buildAddButton() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('新建规则'),
            onPressed: _addUserRule,
          ),
        ),
      ),
    );
  }

  Future<void> _addUserRule() async {
    final rule = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => const RuleEditorDialog(),
    );
    if (rule != null) ref.read(userRulesProvider.notifier).add(rule);
  }

  Future<void> _editUserRule(PreprocessingRule rule) async {
    final updated = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => RuleEditorDialog(initial: rule),
    );
    if (updated != null) {
      ref.read(userRulesProvider.notifier).updateRule(updated);
    }
  }

  void _openReplaceRules({required bool isRegex}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReplaceRulesScreen(isRegex: isRegex),
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

// ==================== 副标题生成（公开，按钮栏也用） ====================

// ==================== 副标题生成（公开，按钮栏也用） ====================
String ruleSubtitle(PreprocessingRule rule) {
  if (rule.script != null && rule.script!.isNotEmpty) {
    return '(内置实现: ${rule.script})';
  }

  switch (rule.kind) {
    case RuleKind.preset:
      final preset = Presets.byId(rule.presetId ?? '');
      if (preset == null) return '(未知预置功能)';
      final parts = <String>[];
      for (final p in preset.params) {
        final v = rule.params[p.key] ?? p.defaultValue;
        if (v.isEmpty) continue;
        parts.add(
            '${p.label}=${p.type == PresetParamType.choice ? p.labelFor(v) : v}');
      }
      final paramText = parts.isEmpty ? '' : '\n${parts.join(' · ')}';
      return '${preset.name}$paramText';

    case RuleKind.js:
      final script = (rule.jsScript ?? '').trim();
      if (script.isEmpty) return 'JS 脚本（空）';
      final firstLine = script.split('\n').firstWhere(
            (l) => l.trim().isNotEmpty,
            orElse: () => script,
          );
      return 'JS 脚本\n$firstLine';

    case RuleKind.replace:
      if (rule.findPattern.isEmpty) return '(无内容)';

      // 内置规则：只标实现类型，不显示 7 开关（内置没有开关）。
      if (rule.isBuiltin) {
        final t = rule.implType ?? '正则';
        return '/${rule.findPattern}/ → "${rule.replaceWith}"\n[$t]';
      }

      // 自定义规则：显示 7 开关。
      final flags = <String>[];
      if (rule.findLiteral) {
        flags.add('字面');
      } else if (rule.findRegex) {
        flags.add('正则');
      }
      if (rule.findEscape) flags.add('查找转义');
      if (rule.replaceLiteral) {
        flags.add('字面输出');
      } else {
        if (rule.replaceDollar) flags.add(r'$1引用');
        if (rule.replaceBackslash) flags.add(r'\1引用');
      }
      if (rule.replaceEscape) flags.add('替换转义');
      final flagText = flags.isEmpty ? '纯字符串' : flags.join(' · ');
      return '/${rule.findPattern}/ → "${rule.replaceWith}"\n[$flagText]';
  }
}

// ==================== 笔记 provider ====================

final _notesProvider = NotifierProvider<_NotesNotifier, Map<String, String>>(
  _NotesNotifier.new,
);

class _NotesNotifier extends PersistentNotifier<Map<String, String>> {
  @override
  String get key => PrefKeys.comparisonNotes;

  @override
  Map<String, String> get defaultValue => const {};

  @override
  Map<String, String> decode(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, v as String));
  }

  @override
  String encode(Map<String, String> value) => jsonEncode(value);

  void setOne(String sectionId, String text) {
    final next = Map<String, String>.from(state);
    if (text.trim().isEmpty) {
      next.remove(sectionId);
    } else {
      next[sectionId] = text;
    }
    update(next);
  }
}

// ==================== 开关说明 provider ====================

final _flagHelpProvider =
    NotifierProvider<_FlagHelpNotifier, Map<String, String>>(
  _FlagHelpNotifier.new,
);

class _FlagHelpNotifier extends PersistentNotifier<Map<String, String>> {
  @override
  String get key => PrefKeys.ruleFlagHelp;

  @override
  Map<String, String> get defaultValue => const {};

  @override
  Map<String, String> decode(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, v as String));
  }

  @override
  String encode(Map<String, String> value) => jsonEncode(value);

  void setOne(String id, String text) {
    final next = Map<String, String>.from(state);
    if (text.trim().isEmpty) {
      next.remove(id);
    } else {
      next[id] = text;
    }
    update(next);
  }
}

// ==================== 规则编辑弹窗（公开） ====================

class RuleEditorDialog extends ConsumerStatefulWidget {
  const RuleEditorDialog({
    super.key,
    this.initial,
    this.showCopyToPreprocess = false,
    this.onCopyToPreprocess,
  });

  final PreprocessingRule? initial;

  final bool showCopyToPreprocess;

  final void Function(PreprocessingRule rule)? onCopyToPreprocess;

  @override
  ConsumerState<RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends ConsumerState<RuleEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _findCtrl;
  late final TextEditingController _replaceCtrl;
  late final TextEditingController _jsCtrl;
  late RuleScope _scope;
  late RuleKind _kind;

  late bool _findRegex;
  late bool _findLiteral;
  late bool _findEscape;
  late bool _replaceDollar;
  late bool _replaceBackslash;
  late bool _replaceLiteral;
  late bool _replaceEscape;

  String? _presetId;
  Map<String, String> _presetParams = const {};

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _nameCtrl = TextEditingController(text: i?.name ?? '');
    _findCtrl = TextEditingController(text: i?.findPattern ?? '');
    _replaceCtrl = TextEditingController(text: i?.replaceWith ?? '');
    _jsCtrl = TextEditingController(
      text: i?.jsScript ?? defaultJsTemplate,
    );
    _scope = i?.scope ?? RuleScope.both;
    _kind = i?.kind ?? RuleKind.replace;
    _findRegex = i?.findRegex ?? true;
    _findLiteral = i?.findLiteral ?? false;
    _findEscape = i?.findEscape ?? false;
    _replaceDollar = i?.replaceDollar ?? true;
    _replaceBackslash = i?.replaceBackslash ?? false;
    _replaceLiteral = i?.replaceLiteral ?? false;
    _replaceEscape = i?.replaceEscape ?? false;
    _presetId = i?.presetId;
    _presetParams = Map<String, String>.from(i?.params ?? const {});
    if (_kind == RuleKind.preset && _presetId == null) {
      final first = Presets.all().firstOrNull;
      if (first != null) {
        _presetId = first.id;
        _presetParams = {
          for (final p in first.params) p.key: p.defaultValue,
        };
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    _jsCtrl.dispose();
    super.dispose();
  }

  void _setFindMode({required bool regex}) {
    setState(() {
      _findRegex = regex;
      _findLiteral = !regex;
    });
  }

  void _setReplaceDollar(bool v) {
    setState(() {
      _replaceDollar = v;
      if (v) _replaceLiteral = false;
      _ensureReplaceNotAllOff();
    });
  }

  void _setReplaceBackslash(bool v) {
    setState(() {
      _replaceBackslash = v;
      if (v) _replaceLiteral = false;
      _ensureReplaceNotAllOff();
    });
  }

  void _setReplaceLiteral(bool v) {
    setState(() {
      if (v) {
        _replaceLiteral = true;
        _replaceDollar = false;
        _replaceBackslash = false;
      } else {
        _replaceLiteral = false;
        if (!_replaceDollar && !_replaceBackslash) {
          _replaceDollar = true;
        }
      }
    });
  }

  void _ensureReplaceNotAllOff() {
    if (!_replaceDollar && !_replaceBackslash && !_replaceLiteral) {
      _replaceDollar = true;
    }
  }

  void _resetToDefault() {
    setState(() {
      _findRegex = true;
      _findLiteral = false;
      _findEscape = false;
      _replaceDollar = true;
      _replaceBackslash = false;
      _replaceLiteral = false;
      _replaceEscape = false;
    });
    _showFloatHint('已恢复默认开关');
  }

  void _showFloatHint(String msg) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        bottom: 80,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Material(
              color: Colors.white,
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(
                  msg,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future<void>.delayed(const Duration(seconds: 2), () {
      try {
        entry.remove();
      } catch (_) {}
    });
  }

  Future<void> _openFlagHelp(String flagId, String flagLabel) async {
    final helps = ref.read(_flagHelpProvider);
    final current = helps[flagId] ?? _flagHelpDefaults[flagId] ?? '';
    final defaultText = _flagHelpDefaults[flagId] ?? '';

    final saved = await showDialog<String>(
      context: context,
      builder: (_) => _FlagHelpDialog(
        flagLabel: flagLabel,
        currentText: current,
        defaultText: defaultText,
      ),
    );
    if (saved != null) {
      ref.read(_flagHelpProvider.notifier).setOne(flagId, saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final s = Theme.of(context).colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.all(4),
      child: SizedBox(
        width: double.maxFinite,
        height: mq.size.height * 0.94,
        child: Column(
          children: [
            _buildTitleBar(),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                children: [
                  // ========== 改动（A7）：规则名输入框 ==========
                  TextField(
                    controller: _nameCtrl,
                    cursorColor: AppColors.accentPurple,
                    decoration: const InputDecoration(
                      labelText: '规则名',
                      border: OutlineInputBorder(),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: AppColors.accentPurple,
                          width: 2,
                        ),
                      ),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _buildKindSelector(),
                  const SizedBox(height: 14),
                  ..._buildKindContent(),
                  const SizedBox(height: 20),
                  _buildScopeDropdown(),
                  const SizedBox(height: 16),
                  _buildHintBox(),
                ],
              ),
            ),
            const Divider(height: 1),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
      child: Row(
        children: [
          Text(
            widget.initial == null ? '新建规则' : '编辑规则',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          if (_kind == RuleKind.replace)
            TextButton.icon(
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('恢复默认'),
              onPressed: _resetToDefault,
            ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildKindSelector() {
    return SegmentedButton<RuleKind>(
      segments: const [
        ButtonSegment(value: RuleKind.replace, label: Text('查找替换')),
        ButtonSegment(value: RuleKind.preset, label: Text('预置功能')),
        ButtonSegment(value: RuleKind.js, label: Text('JS 脚本')),
      ],
      selected: {_kind},
      onSelectionChanged: (set) {
        setState(() {
          _kind = set.first;
          if (_kind == RuleKind.preset && _presetId == null) {
            final first = Presets.all().firstOrNull;
            if (first != null) {
              _presetId = first.id;
              _presetParams = {
                for (final p in first.params) p.key: p.defaultValue,
              };
            }
          }
        });
      },
    );
  }

  List<Widget> _buildKindContent() {
    switch (_kind) {
      case RuleKind.replace:
        return _buildReplaceContent();
      case RuleKind.preset:
        return _buildPresetContent();
      case RuleKind.js:
        return _buildJsContent();
    }
  }

  List<Widget> _buildReplaceContent() {
    return [
      _sectionHeader('查找词'),
      const SizedBox(height: 6),

      // ========== 改动（A7）：查找词输入框 ==========
      TextField(
        controller: _findCtrl,
        minLines: 3,
        maxLines: 8,
        cursorColor: AppColors.accentPurple,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          hintText: r'例如：\d{4}-\d{2}-\d{2}',
          border: OutlineInputBorder(),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: AppColors.accentPurple,
              width: 2,
            ),
          ),
          isDense: true,
          contentPadding: EdgeInsets.all(10),
        ),
      ),
      const SizedBox(height: 6),
      _flagSwitch(
        flagId: 'findRegex',
        label: '支持正则',
        hint: '开：按正则解析；关：改由"仅字面匹配"接管',
        value: _findRegex,
        onChanged: (v) => _setFindMode(regex: v),
      ),
      _flagSwitch(
        flagId: 'findLiteral',
        label: '仅字面匹配',
        hint: '开：特殊符号按普通字符处理；关：改由"支持正则"接管',
        value: _findLiteral,
        onChanged: (v) => _setFindMode(regex: !v),
      ),
      _flagSwitch(
        flagId: 'findEscape',
        label: r'支持转义（\n \r \t \\ \0）',
        hint: '开：把这些转义还原成真字符后再匹配',
        value: _findEscape,
        onChanged: (v) => setState(() => _findEscape = v),
      ),
      const SizedBox(height: 20),
      _sectionHeader('替换词'),
      const SizedBox(height: 6),

      // ========== 改动（A7）：替换词输入框 ==========
      TextField(
        controller: _replaceCtrl,
        minLines: 3,
        maxLines: 8,
        cursorColor: AppColors.accentPurple,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          hintText: r'例如：$1年$2月$3日',
          border: OutlineInputBorder(),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: AppColors.accentPurple,
              width: 2,
            ),
          ),
          isDense: true,
          contentPadding: EdgeInsets.all(10),
        ),
      ),
      const SizedBox(height: 6),
      _flagSwitch(
        flagId: 'replaceDollar',
        label: r'$1 $2 引用',
        hint: r'开：替换串里的 $1 $2 展开为捕获组',
        value: _replaceDollar,
        onChanged: _setReplaceDollar,
      ),
      _flagSwitch(
        flagId: 'replaceBackslash',
        label: r'\1 \2 引用',
        hint: r'开：替换串里的 \1 \2 展开为捕获组',
        value: _replaceBackslash,
        onChanged: _setReplaceBackslash,
      ),
      _flagSwitch(
        flagId: 'replaceLiteral',
        label: '仅字面输出',
        hint: '开：不展开引用，替换串原样输出',
        value: _replaceLiteral,
        onChanged: _setReplaceLiteral,
      ),
      _flagSwitch(
        flagId: 'replaceEscape',
        label: r'支持转义（\n \r \t \\ \0）',
        hint: '开：把这些转义还原成真字符后再输出',
        value: _replaceEscape,
        onChanged: (v) => setState(() => _replaceEscape = v),
      ),
    ];
  }

  List<Widget> _buildPresetContent() {
    final presets = Presets.all();
    final current = Presets.byId(_presetId ?? '');

    return [
      _sectionHeader('预置功能'),
      const SizedBox(height: 9),

      // ========== 改动（A7）：选择功能下拉框 ==========
      DropdownButtonFormField<String>(
        value: _presetId,
        isExpanded: true,
        iconEnabledColor: AppColors.accentPurple,
        decoration: const InputDecoration(
          labelText: '选择功能',
          border: OutlineInputBorder(),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: AppColors.accentPurple,
              width: 2,
            ),
          ),
          isDense: true,
        ),
        items: [
          for (final p in presets)
            DropdownMenuItem(
              value: p.id,
              child: Text(p.name,
                  style: const TextStyle(color: Colors.black)),
            ),
        ],
        onChanged: (v) {
          if (v == null) return;
          final p = Presets.byId(v);
          if (p == null) return;
          setState(() {
            _presetId = v;
            _presetParams = {
              for (final param in p.params)
                param.key: _presetParams[param.key] ?? param.defaultValue,
            };
          });
        },
      ),
      if (current != null) ...[
        const SizedBox(height: 12),
        ..._buildPresetParams(current),
      ],
    ];
  }

  List<Widget> _buildPresetParams(Preset preset) {
    if (preset.params.isEmpty) {
      return [
        Text(
          '（此功能不需要参数）',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ];
    }
    return [
      for (final p in preset.params)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _buildPresetParam(p),
        ),
    ];
  }

  // ========== 改动（A7）：参数输入框 / 下拉框 ==========
  Widget _buildPresetParam(PresetParam p) {
    final value = _presetParams[p.key] ?? p.defaultValue;
    switch (p.type) {
      case PresetParamType.choice:
        return DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          iconEnabledColor: AppColors.accentPurple,
          decoration: InputDecoration(
            labelText: p.label,
            border: const OutlineInputBorder(),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(
                color: AppColors.accentPurple,
                width: 2,
              ),
            ),
            isDense: true,
            helperText: p.hint.isEmpty ? null : p.hint,
          ),
          items: [
            for (final o in p.options)
              DropdownMenuItem(
                value: _optValue(o),
                child: Text(_optLabel(o),
                    style: const TextStyle(color: Colors.black)),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _presetParams = {
                  ..._presetParams,
                  p.key: v,
                });
          },
        );
      case PresetParamType.integer:
        return TextFormField(
          initialValue: value,
          keyboardType: TextInputType.number,
          cursorColor: AppColors.accentPurple,
          decoration: InputDecoration(
            labelText: p.label,
            border: const OutlineInputBorder(),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(
                color: AppColors.accentPurple,
                width: 2,
              ),
            ),
            isDense: true,
            helperText: p.hint.isEmpty ? null : p.hint,
          ),
          onChanged: (v) {
            _presetParams = {..._presetParams, p.key: v};
          },
        );
      case PresetParamType.text:
        return TextFormField(
          initialValue: value,
          cursorColor: AppColors.accentPurple,
          decoration: InputDecoration(
            labelText: p.label,
            border: const OutlineInputBorder(),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(
                color: AppColors.accentPurple,
                width: 2,
              ),
            ),
            isDense: true,
            helperText: p.hint.isEmpty ? null : p.hint,
          ),
          onChanged: (v) {
            _presetParams = {..._presetParams, p.key: v};
          },
        );
    }
  }

  String _optValue(String o) {
    final i = o.indexOf('|');
    return i < 0 ? o : o.substring(0, i);
  }

  String _optLabel(String o) {
    final i = o.indexOf('|');
    return i < 0 ? o : o.substring(i + 1);
  }

  List<Widget> _buildJsContent() {
    return [
      _sectionHeader('JS 脚本'),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:
              Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '这是「用代码处理文本」的入口。\n'
          '\n'
          '脚本里有一个变量 text，就是整篇文本。\n'
          '脚本的最后一行，就是处理结果。\n'
          '\n'
          '比如删掉所有空行：\n'
          '    text.split(\'\\n\').filter(l => l.trim()).join(\'\\n\')\n'
          '\n'
          '不懂编程的话，用「预置功能」更省事。\n'
          '想试试的话，点下方「使用说明」按钮，\n'
          '里面有从零开始的教程和 30 多个现成例子。\n'
          '\n'
          '【关于 JS 版本】\n'
          '支持 ES2019 及更早的 JavaScript 语法。\n'
          '网上新写法（2020 年以后）可能不支持，遇到报错换老写法试试。\n'
          '\n'
          '常见的不支持写法对照：\n'
          '  text?.length        老写法：text ? text.length : 0\n'
          '  a ?? b              老写法：a !== null && a !== undefined ? a : b\n'
          '  a ||= b             老写法：a = a || b\n'
          '  a &&= b             老写法：a = a && b\n'
          '  a ??= b             老写法：if (a === null || a === undefined) a = b\n'
          '  text.replaceAll()   老写法：text.replace(/x/g, \'y\') 或 text.split(\'x\').join(\'y\')\n'
          '  arr.at(-1)          老写法：arr[arr.length - 1]\n'
          '  arr.at(0)           老写法：arr[0]\n'
          '  arr.flat()          老写法：手写循环合并\n'
          '  arr.flatMap()       老写法：先 map 再手写合并\n'
          '  arr.findLast()      老写法：先 reverse 再 find\n'
          '  Object.fromEntries() 老写法：手写 reduce\n'
          '  Object.hasOwn()     老写法：obj.hasOwnProperty(key)\n'
          '  str.matchAll()      老写法：while 循环 + exec\n'
          '  Promise.allSettled() 老写法：Promise.all + catch 包裹\n'
          '  1_000_000（数字分隔符） 老写法：1000000\n'
          '  123n（BigInt）      老写法：用 Number，别用 BigInt\n'
          '  #private（私有字段） 老写法：不用类，用普通变量\n'
          '  top-level await     老写法：(async () => { ... })()\n'
          '  arr.toSorted()      老写法：[...arr].sort()\n'
          '  structuredClone(o)  老写法：JSON.parse(JSON.stringify(o))',
          style: TextStyle(
            fontSize: 12,
            height: 1.6,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      const SizedBox(height: 8),

      // ========== 改动（A7）：JS 脚本输入框 ==========
      TextField(
        controller: _jsCtrl,
        minLines: 12,
        maxLines: 24,
        cursorColor: AppColors.accentPurple,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.5,
        ),
        decoration: const InputDecoration(
          hintText:
              '// 例如：删除空行\ntext.split(\'\\n\').filter(l => l.trim()).join(\'\\n\')',
          border: OutlineInputBorder(),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: AppColors.accentPurple,
              width: 2,
            ),
          ),
          contentPadding: EdgeInsets.all(10),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.restore, size: 16),
            label: const Text('用基础模板'),
            onPressed: () {
              setState(() => _jsCtrl.text = defaultJsTemplate);
            },
          ),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.info_outline, size: 16),
            label: const Text('使用说明'),
            onPressed: _showJsExamples,
          ),
        ],
      ),
    ];
  }

  void _showJsExamples() {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: const Text('JS 脚本 · 使用说明'),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.7,
          child: SingleChildScrollView(
            child: SelectableText(
              _jsExamples,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ========== 改动（A7）：作用范围下拉框 ==========
  Widget _buildScopeDropdown() {
    return DropdownButtonFormField<RuleScope>(
      value: _scope,
      isExpanded: true,
      iconEnabledColor: AppColors.accentPurple,
      decoration: const InputDecoration(
        labelText: '作用范围',
        border: OutlineInputBorder(),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(
            color: AppColors.accentPurple,
            width: 2,
          ),
        ),
        isDense: true,
      ),
      items: const [
        DropdownMenuItem(
            value: RuleScope.both,
            child: Text('两侧文件',
                style: TextStyle(color: Colors.black))),
        DropdownMenuItem(
            value: RuleScope.originalOnly,
            child: Text('仅左侧文件',
                style: TextStyle(color: Colors.black))),
        DropdownMenuItem(
            value: RuleScope.modifiedOnly,
            child: Text('仅右侧文件',
                style: TextStyle(color: Colors.black))),
      ],
      onChanged: (v) => setState(() => _scope = v ?? RuleScope.both),
    );
  }

  Widget _buildHintBox() {
    final s = Theme.of(context).colorScheme;
    String hint;
    switch (_kind) {
      case RuleKind.replace:
        hint = '查找侧："支持正则"和"仅字面匹配"互斥，必须开一个。\n'
            '替换侧："\$1 \$2 引用"、"\$1 \$2 引用"、"仅字面输出"'
            '三者至少开一个。\n'
            '长按任一开关的标签，可查看并编辑详细说明。';
        break;
      case RuleKind.preset:
        final preset = Presets.byId(_presetId ?? '');
        hint = preset?.helpText ?? '请先选择一个功能';
        break;
      case RuleKind.js:
        hint = '脚本最后一行就是处理结果。\n'
            '返回数字、布尔值会自动转成文本。\n'
            '不懂编程的话，建议用「预置功能」。';
        break;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: s.surfaceVariant.withOpacity(0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        hint,
        style: TextStyle(
          fontSize: 12,
          height: 1.5,
          color: s.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const Spacer(),
      ],
    );
  }

  Widget _flagSwitch({
    required String flagId,
    required String label,
    required String hint,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: GestureDetector(
              onLongPress: () => _openFlagHelp(flagId, label),
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(label, style: const TextStyle(fontSize: 13)),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.info_outline,
                        size: 13,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '（长按查看详细说明）',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.3,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          if (widget.showCopyToPreprocess)
            TextButton.icon(
              icon: const Icon(Icons.copy_all, size: 18),
              label: const Text('复制到预处理'),
              onPressed: _handleCopyToPreprocess,
            )
          else
            const SizedBox.shrink(),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _submit,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _handleCopyToPreprocess() {
    final rule = _buildRule();
    if (rule == null) return;
    final copied = PreprocessingRule(
      id: 'user_${DateTime.now().microsecondsSinceEpoch}',
      name: rule.name,
      kind: rule.kind,
      findPattern: rule.findPattern,
      replaceWith: rule.replaceWith,
      scope: rule.scope,
      enabled: true,
      isBuiltin: false,
      script: rule.script,
      findRegex: rule.findRegex,
      findLiteral: rule.findLiteral,
      findEscape: rule.findEscape,
      replaceDollar: rule.replaceDollar,
      replaceBackslash: rule.replaceBackslash,
      replaceLiteral: rule.replaceLiteral,
      replaceEscape: rule.replaceEscape,
      presetId: rule.presetId,
      params: rule.params,
      jsScript: rule.jsScript,
      implType: rule.implType,
      implDetail: rule.implDetail,
      replacementType: rule.replacementType,
      replacementDetail: rule.replacementDetail,
      replacementNote: rule.replacementNote,
    );
    ref.read(userRulesProvider.notifier).add(copied);
    if (!mounted) return;
    _showFloatHint('已复制到预处理规则列表');
    widget.onCopyToPreprocess?.call(copied);
  }

  void _submit() {
    final rule = _buildRule();
    if (rule == null) return;
    Navigator.pop(context, rule);
  }

  PreprocessingRule? _buildRule() {
    final raw = _nameCtrl.text;
    if (raw.isEmpty) {
      _toast('规则名不能为空');
      return null;
    }

    switch (_kind) {
      case RuleKind.replace:
        final find = _findCtrl.text;
        if (find.isEmpty) {
          _toast('查找词不能为空');
          return null;
        }
        final useRegex = _findRegex && !_findLiteral;
        if (useRegex) {
          try {
            var test = find;
            if (_findEscape) test = unescapeEscapes(test);
            RegExp(test);
          } catch (_) {
            _toast('正则无效，请检查查找词');
            return null;
          }
        }
        return PreprocessingRule(
          id: widget.initial?.id ??
              'user_${DateTime.now().microsecondsSinceEpoch}',
          name: raw,
          kind: RuleKind.replace,
          findPattern: find,
          replaceWith: _replaceCtrl.text,
          scope: _scope,
          enabled: widget.initial?.enabled ?? true,
          isBuiltin: false,
          findRegex: _findRegex,
          findLiteral: _findLiteral,
          findEscape: _findEscape,
          replaceDollar: _replaceDollar,
          replaceBackslash: _replaceBackslash,
          replaceLiteral: _replaceLiteral,
          replaceEscape: _replaceEscape,
        );

      case RuleKind.preset:
        if (_presetId == null) {
          _toast('请选择预置功能');
          return null;
        }
        final preset = Presets.byId(_presetId!);
        return PreprocessingRule(
          id: widget.initial?.id ??
              'user_${DateTime.now().microsecondsSinceEpoch}',
          name: raw,
          kind: RuleKind.preset,
          scope: _scope,
          enabled: widget.initial?.enabled ?? true,
          isBuiltin: false,
          presetId: _presetId,
          params: Map<String, String>.from(_presetParams),
          implType: preset?.implType,
          implDetail: preset?.implDetail,
          replacementType: preset?.replacementType,
          replacementDetail: preset?.replacementDetail,
          replacementNote: preset?.replacementNote,
        );

      case RuleKind.js:
        final script = _jsCtrl.text;
        if (script.trim().isEmpty) {
          _toast('JS 脚本不能为空');
          return null;
        }
        return PreprocessingRule(
          id: widget.initial?.id ??
              'user_${DateTime.now().microsecondsSinceEpoch}',
          name: raw,
          kind: RuleKind.js,
          scope: _scope,
          enabled: widget.initial?.enabled ?? true,
          isBuiltin: false,
          jsScript: script,
        );
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    _showFloatHint(msg);
  }
}

// ==================== JS 示例文本 ====================
const String _jsExamples = r'''
【一、JS 脚本是干嘛的】

App 会把整篇文本交给一段"小程序"，
小程序处理完，把结果交回来。

跟其它两个选项的区别：
  · 查找替换：填个词，全篇替换
  · 预置功能：选一个做好的操作
  · JS 脚本：自己写"怎么做"

举个例子：你想删掉所有空行。
  用预置功能：选「删除空行」→ 完事。
  用 JS 脚本：你得写一行代码：
      text.split('\n').filter(l => l.trim()).join('\n')

结果一样，但 JS 脚本要你自己写。

为什么要用它？
因为预置功能只有那么几十个。
你遇到一个「预置功能里没有」的操作，
就可能需要 JS 脚本。
或者，你想把好几个操作合并成一步做。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【二、脚本里有什么】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

脚本里有一个变量，叫 text。
它就是整篇文本。你可以对 text 做各种操作。

比如：
  text.length          数一数字符有多少个
  text.toUpperCase()   全部变成大写
  text.trim()          去掉开头和结尾的空格
  text.split('\n')     按换行切成一行一行的


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【三、脚本的"输出"】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

关键规则：脚本最后一行，就是处理结果。
App 会拿最后一行的值，替换掉原来的文本。

对：
  text.trim()
  text.split('\n').reverse().join('\n')
  text.length

错：
  console.log(text);      会返回 undefined
  let result = text;      最后一行是赋值语句，不是值


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【四、完整例子：删掉所有空行】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

需求：删掉所有空行。

步骤拆解：
  第 1 步：把文本按行拆开
      text.split('\n')
      结果：['第一行', '', '第二行', '', '第三行']

  第 2 步：删掉空的行
      .filter(l => l.trim())
      结果：['第一行', '第二行', '第三行']

  第 3 步：再拼回一整段
      .join('\n')
      结果："第一行\n第二行\n第三行"

连起来写：
  text.split('\n').filter(l => l.trim()).join('\n')


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【五、通用套路：切 → 处理 → 拼】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

几乎所有"按行处理"的需求，都是这个套路：

  text.split('\n')      切
       ↓
  .filter(...)           处理（改这里）
       ↓
  .join('\n')            拼

你只要改"处理"那一步就行。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【六、基础例子 · 按行操作】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

■ 去掉重复行
[...new Set(text.split('\n'))].join('\n')

■ 去掉空行
text.split('\n').filter(l => l.trim()).join('\n')

■ 每行前加行号
text.split('\n').map((l, i) => `${i + 1}. ${l}`).join('\n')

■ 每行去首尾空格
text.split('\n').map(l => l.trim()).join('\n')

■ 倒序排列每行
text.split('\n').reverse().join('\n')

■ 按长度排序（短到长）
text.split('\n').sort((a, b) => a.length - b.length).join('\n')

■ 每行倒序字符
text.split('\n').map(l => [...l].reverse().join('')).join('\n')

■ 只保留前 100 行
text.split('\n').slice(0, 100).join('\n')

■ 只保留后 100 行
text.split('\n').slice(-100).join('\n')

■ 行间插入空行
text.split('\n').join('\n\n')

■ 每隔一行取一行
text.split('\n').filter((_, i) => i % 2 === 0).join('\n')


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【七、基础例子 · 按条件筛选】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

■ 只保留含"第X章"的行
text.split('\n').filter(l => /^第\d+章/.test(l)).join('\n')

■ 删除含"广告"的行
text.split('\n').filter(l => !l.includes('广告')).join('\n')

■ 只保留以"！"结尾的行
text.split('\n').filter(l => l.endsWith('！')).join('\n')

■ 只保留长度超过 20 的行
text.split('\n').filter(l => l.length > 20).join('\n')

■ 删除以"//"开头的行（注释）
text.split('\n').filter(l => !l.startsWith('//')).join('\n')


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【八、基础例子 · 整篇操作】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

■ 大写转小写
text.toLowerCase()

■ 小写转大写
text.toUpperCase()

■ 去掉前后空白
text.trim()

■ 两个空格变一个
text.replace(/  +/g, ' ')

■ 删除 HTML 标签
text.replace(/<[^>]+>/g, '')

■ 首字母大写（每个单词）
text.replace(/\b\w/g, c => c.toUpperCase())

■ 数字加千分位
text.replace(/\d+/g, n => Number(n).toLocaleString())

■ 把 a 换成 b（全篇）
text.replace(/a/g, 'b')


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【九、进阶例子 · 多步骤处理】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

■ 删空行 + 每行去首尾空格
text.split('\n')
    .map(l => l.trim())
    .filter(l => l)
    .join('\n')

■ 每行去重 + 每行倒序字符
[...new Set(text.split('\n'))]
    .map(l => [...l].reverse().join(''))
    .join('\n')

■ 只保留含"第X章"的行 + 每行前加行号
text.split('\n')
    .filter(l => /^第\d+章/.test(l))
    .map((l, i) => `${i + 1}. ${l}`)
    .join('\n')

■ 按行首字母排序（忽略大小写）
text.split('\n')
    .sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()))
    .join('\n')


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【十、进阶例子 · 段落处理】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

■ 段落合并（连续非空行合并成一行）
text.split(/\n\s*\n/).map(p => p.split('\n').join(' ')).join('\n\n')

■ 每段之间加一个空行
text.split(/\n\s*\n/).join('\n\n\n')

■ 每段前后加括号
text.split(/\n\s*\n/).map(p => '【' + p + '】').join('\n\n')


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【十一、进阶例子 · 自定义函数】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

一行代码写不下时，可以用箭头函数包起来。
末尾写一个"立即执行函数"，
最后一个 return 的值就是结果。

■ 统计行数
(() => {
  return text.split('\n').length;
})()

■ 词频统计（前 20 个）
(() => {
  const words = text.split(/\s+/);
  const freq = {};
  words.forEach(w => freq[w] = (freq[w] || 0) + 1);
  return Object.entries(freq)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 20)
    .map(([w, n]) => `${w}: ${n}`)
    .join('\n');
})()

■ 最长的一行
text.split('\n').reduce((a, b) => a.length > b.length ? a : b)

■ 找出含"标题"的行，并去重
(() => {
  const lines = text.split('\n').filter(l => l.includes('标题'));
  return [...new Set(lines)].join('\n');
})()

■ 检测敏感词（有则返回"【警告】"，无则返回原文）
(() => {
  const bad = ['广告', '推广', '联系我'];
  if (bad.some(w => text.includes(w))) return '【警告】';
  return text;
})()


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【十二、进阶例子 · 正则替换】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

■ 删除所有数字
text.replace(/\d+/g, '')

■ 删除所有英文
text.replace(/[a-zA-Z]+/g, '')

■ 删除所有中文
text.replace(/[\u4e00-\u9fa5]+/g, '')

■ 只保留中文
text.replace(/[^\u4e00-\u9fa5]/g, '')

■ 把连续空格压成一个
text.replace(/ +/g, ' ')

■ 把连续换行压成一个
text.replace(/\n+/g, '\n')

■ 把"数字-数字"改成"数字 到 数字"
text.replace(/(\d+)-(\d+)/g, '$1 到 $2')

■ 日期格式转换 YYYY-MM-DD → YYYY年MM月DD日
text.replace(/(\d{4})-(\d{2})-(\d{2})/g, '$1年$2月$3日')


━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【十三、一些提示】
━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 脚本最后一行就是结果。
   不要写分号，不要写 console.log。

2. 想调试可以写 console.log，
   但最后一行还得是一个值。

3. 出错不会崩，只会"这次处理无效"，原文不变。

4. JS 脚本比预置功能慢。

5. 更多 JS 语法去网上搜：
   "JavaScript 数组方法"
   "JavaScript 字符串方法"
''';

// ==================== 开关说明对话框 ====================

class _FlagHelpDialog extends StatefulWidget {
  const _FlagHelpDialog({
    required this.flagLabel,
    required this.currentText,
    required this.defaultText,
  });

  final String flagLabel;
  final String currentText;
  final String defaultText;

  @override
  State<_FlagHelpDialog> createState() => _FlagHelpDialogState();
}

class _FlagHelpDialogState extends State<_FlagHelpDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.currentText);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _showFloatHint(String msg) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        bottom: 80,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Material(
              color: Colors.white,
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(
                  msg,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future<void>.delayed(const Duration(seconds: 2), () {
      try {
        entry.remove();
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final s = Theme.of(context).colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.all(4),
      child: SizedBox(
        width: double.maxFinite,
        height: mq.size.height * 0.94,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.flagLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.restore, size: 16),
                    label: const Text('恢复默认'),
                    onPressed: () {
                      setState(() {
                        _ctrl.text = widget.defaultText;
                      });
                      _showFloatHint('已恢复默认，点保存生效');
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Container(
              width: double.infinity,
              color: s.surfaceVariant.withOpacity(0.4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                '这里是该开关的详细说明，可直接编辑。保存后覆盖默认内容。',
                style: TextStyle(fontSize: 11, color: s.onSurfaceVariant),
              ),
            ),
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
                    hintText: '在这里编辑说明…',
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

/// 规则快照。用于判断"进比较设置转一圈到底改没改东西"。
/// 不含笔记（笔记不影响渲染），只含会改变对比结果的规则状态。
///
/// ⚠️ 不用 jsonEncode：规则多的时候（几百条用户规则 + 长文本），
/// jsonEncode 会在返回设置页时阻塞主线程几十毫秒。
/// 直接拼接字符串，只做一次 StringBuffer 写入，快 5~10 倍。
///
/// 用 \u0001 当字段分隔符，\u0002 当条目分隔符——用户输入里几乎不可能出现。
String comparisonRulesSnapshot(WidgetRef ref) {
  final buf = StringBuffer();

  // 规则顺序
  for (final id in ref.read(ruleOrderProvider)) {
    buf.write(id);
    buf.write('\u0001');
  }
  buf.write('\u0002');

  // 用户规则：序列化所有会影响执行结果的字段
  for (final r in ref.read(userRulesProvider)) {
    buf.write(r.id);
    buf.write('\u0001');
    buf.write(r.name);
    buf.write('\u0001');
    buf.write(r.kind.name);
    buf.write('\u0001');
    buf.write(r.enabled ? '1' : '0');
    buf.write('\u0001');
    buf.write(r.findPattern);
    buf.write('\u0001');
    buf.write(r.replaceWith);
    buf.write('\u0001');
    buf.write(r.scope.name);
    buf.write('\u0001');
    buf.write(r.presetId ?? '');
    buf.write('\u0001');
    buf.write(r.jsScript ?? '');
    buf.write('\u0001');
    buf.write(r.findRegex ? '1' : '0');
    buf.write(r.findLiteral ? '1' : '0');
    buf.write(r.findEscape ? '1' : '0');
    buf.write(r.replaceDollar ? '1' : '0');
    buf.write(r.replaceBackslash ? '1' : '0');
    buf.write(r.replaceLiteral ? '1' : '0');
    buf.write(r.replaceEscape ? '1' : '0');
    buf.write('\u0001');
    // params 是 Map<String, String>，按键排序保证稳定
    final paramKeys = r.params.keys.toList()..sort();
    for (final k in paramKeys) {
      buf.write(k);
      buf.write('=');
      buf.write(r.params[k]!);
      buf.write(';');
    }
    buf.write('\u0002');
  }
  buf.write('\u0002');

  // 内置规则开关
  final enables = ref.read(builtinRuleEnablesProvider);
  final enableKeys = enables.keys.toList()..sort();
  for (final k in enableKeys) {
    buf.write(k);
    buf.write('\u0001');
    buf.write(enables[k]! ? '1' : '0');
    buf.write('\u0001');
  }
  buf.write('\u0002');

  // 两块规则表文本
  buf.write(ref.read(keywordRulesTextProvider));
  buf.write('\u0002');
  buf.write(ref.read(regexRulesTextProvider));

  return buf.toString();
}
