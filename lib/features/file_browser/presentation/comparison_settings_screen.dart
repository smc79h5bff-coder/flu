import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../help/presentation/help_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/application/builtin_rules.dart';
import '../../preprocessing/application/preprocessing_service.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';
import 'replace_rules_screen.dart';

/// 顶部说明笔记的 sectionId。
const String _orderNoteSectionId = 'ruleOrderTop';

/// ==================== 7 个开关的默认说明文字 ====================
/// 用 raw string，$ 和 \ 都是字面字符。
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
  查找 (abc)  仅字面=匹配"(abc)"五个字；正则=捕获"abc"

什么时候用：
  · 要找的字符串里含 . * + ? ( ) [ ] { } | \ ^ $
    这些符号，而你是想找它们本身
  · 不想被正则引擎"吃掉"特殊字符

跟"支持转义"的关系：字面模式下，转义开关仍然有效。
  转义先执行，之后才做字面匹配。''',

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

—————— 和"支持正则"的关系 ——————

Dart 的正则引擎本身就认 \n \t \\ 这些转义。
所以"支持正则"开着时，\n 是能用的，本开关开不开都行。

只有"仅字面匹配"开着时，本开关才有意义：
  · 开 = 把 \n 还原成真换行，然后做字面匹配
  · 关 = 把 \n 当两个字面字符

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

例3：提取邮箱用户名和域名，调换
  查找：(\w+)@(\w+)
  替换：$2#$1
  结果：abc@xyz → xyz#abc

例4：给数字加括号
  查找：(\d+)
  替换：($1)
  结果：123 → (123)

—————— 需要注意 ——————

· 想用 $1，查找词里必须有对应数量的 ()。
· $1 和 $10 有歧义：Dart 会优先当成 $10。
  想表示"$1 后面跟个 0"，写 ${1}0。
· 想输出字面的 $，写 \$。
· $1 $2 可以多次出现，比如 $1-$2-$1 会输出三段。
· 转义开关（还原 \n \t）独立控制，与本开关无关。''',

  'replaceBackslash': r'''【替换词 · \1 \2 引用】

开：替换词里出现 \1 \2 \3 …… 时，会被替换成捕获组内容。
关：按字面输出（不展开 \1）。
与"仅字面输出"互斥，与"$1 $2 引用"可共存。

—————— 什么是 \1 ——————

\1 是捕获组的一种引用写法，跟 $1 效果一模一样。
\1 = $1，\2 = $2，依此类推。

捕获组 = 查找词里每一对圆括号 () 抓到的内容。
从左到右编号：第 1 对括号是 \1，第 2 对是 \2。

例：查找词写 (\d+)-(\d+)
  第 1 对括号 → \1
  第 2 对括号 → \2

文本 12-34 用这个查找词：
  \1 = 12
  \2 = 34

—————— 例子 ——————

例1：调换顺序
  查找：(\d+)-(\d+)
  替换：\2-\1
  结果：12-34 → 34-12

例2：加括号
  查找：(\d+)
  替换：(\1)
  结果：123 → (123)

例3：日期格式转换
  查找：(\d{4})-(\d{2})-(\d{2})
  替换：\1年\2月\3日
  结果：2024-01-01 → 2024年01月01日

—————— \1 和 $1 的区别 ——————

效果：完全一样。
写法：\1 用反斜杠，$1 用美元符号。
来源：\1 是传统正则替换语法，$1 是 Perl 风格。

—————— 什么时候用 \1 ——————

一般用 $1 就够了，看习惯。
只有一种情况必须用 \1：替换词里本来就要输出一个 $ 符号，
同时又要引用捕获组。

—————— 注意 ——————

· \1 后面必须跟数字，不能写 \a \b。
· 想让替换词输出一个真反斜杠，写 \\。
· 没有捕获组时，\1 \2 展开为空串。
· 转义开关（还原 \n \t）独立控制，与本开关无关。''',

  'replaceLiteral': r'''【替换词 · 仅字面输出】

开：替换词完全按字面输出，不展开任何 $1 $2 或 \1 \2 引用。
关：由"$1 $2 引用"和"\1 \2 引用"接管（三者至少开一个）。

跟两个引用开关的关系：互斥。
  · 开"仅字面输出"    → 自动关掉"$1 $2 引用"和"\1 \2 引用"
  · 开任一引用开关    → 自动关掉"仅字面输出"
  · 三个必须有一个开着

例子：
  查找：(\d+)
  替换：$1     仅字面=输出"$1"四个字符；引用=输出括号里抓到的数字
  替换：\1     仅字面=输出"\1"三个字符；引用=同上

什么时候用：
  · 替换词里本来就有 $ 或 \数字 这种字面内容，
    不想被当成捕获组引用
  · 想让替换结果跟正则里的 $1 \1 完全无关

跟"支持转义"的关系：转义开关仍然有效。
  转义先执行，之后才做字面输出。
  所以"仅字面输出"+"支持转义"开着时，\n 仍然会变成真换行。''',

  'replaceEscape': r'''【替换词 · 支持转义】

开：替换词里的转义序列会被还原成真字符。
关：转义序列按字面输出（\n 输出"反斜杠+n"两个字符）。

支持的转义：
  \n   换行符
  \r   回车符（老 Mac 换行，现代少用）
  \t   Tab 制表符
  \\   一个反斜杠
  \0   空字符（NUL，极少用）

例子：
  替换词 \n          开=输出一个真换行；关=输出"反斜杠+n"
  替换词 第$1章\n    开=每章后面跟一个真换行
  替换词 \t          开=输出一个真 Tab
  替换词 C:\\Users   开=输出 C:\Users

—————— 什么时候需要它 ——————

· 想在替换结果里插入换行：\n
· 想在替换结果里插入 Tab：\t
· 想输出一个字面反斜杠：\\

—————— 和"多行输入"的区别 ——————

你也可以直接在替换框里敲回车输入真换行，
不用写 \n。两种方式都行：
  · 敲回车 = 真换行
  · 写 \n  = 靠这个开关还原

本开关只影响"反斜杠 + 字母"这种写法。''',
};

/// 列表里的一项：单条规则 / 关键词块 / 正则块。
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

class ComparisonSettingsScreen extends ConsumerStatefulWidget {
  const ComparisonSettingsScreen({super.key});

  @override
  ConsumerState<ComparisonSettingsScreen> createState() =>
      _ComparisonSettingsScreenState();
}

class _ComparisonSettingsScreenState
    extends ConsumerState<ComparisonSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final items = _buildItems();

    return Scaffold(
      appBar: AppBar(
        title: const Text('比较设置'),
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
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        child: Icon(Icons.drag_handle),
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
        title: '关键词规则',
        subtitle: '一整块文本 · ${item.lineCount} 行',
        onTap: () => _openReplaceRules(isRegex: false),
      );
    }
    final regexItem = item as _RegexBlockItem;
    return _buildBlockTile(
      key: regexItem.key,
      dragHandle: dragHandle,
      icon: Icons.code,
      title: '正则规则',
      subtitle: '一整块文本 · ${regexItem.lineCount} 行',
      onTap: () => _openReplaceRules(isRegex: true),
    );
  }

  Widget _buildSingleTile(_SingleRuleItem item, Widget dragHandle) {
    final rule = item.rule;
    final subtitle = _ruleSubtitle(rule);

    return ListTile(
      key: item.key,
      leading: dragHandle,
      title: Text(rule.name),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
          if (!rule.isBuiltin) ...[
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _editUserRule(rule),
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () =>
                  ref.read(userRulesProvider.notifier).remove(rule.id),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.lock_outline, size: 16),
            ),
        ],
      ),
    );
  }

  String _ruleSubtitle(PreprocessingRule rule) {
    if (rule.script != null && rule.script!.isNotEmpty) {
      return '(内置脚本: ${rule.script})';
    }
    if (rule.findPattern.isEmpty) return '(无内容)';

    final flags = <String>[];
    // 查找侧。
    if (rule.findLiteral) {
      flags.add('字面');
    } else if (rule.findRegex) {
      flags.add('正则');
    }
    if (rule.findEscape) flags.add('查找转义');
    // 替换侧。
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
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
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

  Widget _buildHeader() {
    final s = Theme.of(context).colorScheme;
    final notes = ref.watch(_notesProvider);
    final hasNote = (notes[_orderNoteSectionId] ?? '').trim().isNotEmpty;

    return Material(
      color: s.primaryContainer.withOpacity(0.35),
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
                color: hasNote ? s.primary : s.onSurfaceVariant,
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
      builder: (_) => const _RuleEditorDialog(),
    );
    if (rule != null) ref.read(userRulesProvider.notifier).add(rule);
  }

  Future<void> _editUserRule(PreprocessingRule rule) async {
    final updated = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => _RuleEditorDialog(initial: rule),
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

// ==================== 7 开关说明 provider ====================

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

// ==================== 规则编辑弹窗 ====================

class _RuleEditorDialog extends ConsumerStatefulWidget {
  const _RuleEditorDialog({this.initial});

  final PreprocessingRule? initial;

  @override
  ConsumerState<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends ConsumerState<_RuleEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _findCtrl;
  late final TextEditingController _replaceCtrl;
  late RuleScope _scope;

  late bool _findRegex;
  late bool _findLiteral;
  late bool _findEscape;
  late bool _replaceDollar;
  late bool _replaceBackslash;
  late bool _replaceLiteral;
  late bool _replaceEscape;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _nameCtrl = TextEditingController(text: i?.name ?? '');
    _findCtrl = TextEditingController(text: i?.findPattern ?? '');
    _replaceCtrl = TextEditingController(text: i?.replaceWith ?? '');
    _scope = i?.scope ?? RuleScope.both;
    _findRegex = i?.findRegex ?? true;
    _findLiteral = i?.findLiteral ?? false;
    _findEscape = i?.findEscape ?? false;
    _replaceDollar = i?.replaceDollar ?? true;
    _replaceBackslash = i?.replaceBackslash ?? false;
    _replaceLiteral = i?.replaceLiteral ?? false;
    _replaceEscape = i?.replaceEscape ?? false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    super.dispose();
  }

  // ==================== 互斥逻辑 ====================

  /// 查找侧：正则和字面互斥，必须有一个。
  void _setFindMode({required bool regex}) {
    setState(() {
      _findRegex = regex;
      _findLiteral = !regex;
    });
  }

  /// 替换侧：三个开关至少一个。\1 和 $1 可共存，字面输出与两者互斥。
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已恢复默认开关'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  // ==================== 说明弹窗 ====================

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

  // ==================== UI ====================

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
                  Text(
                    widget.initial == null ? '新建规则' : '编辑规则',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '恢复默认',
                    icon: const Icon(Icons.restore),
                    onPressed: _resetToDefault,
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                children: [
                  TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '规则名',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 18),

                  // ===== 查找词 =====
                  _sectionHeader('查找词'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _findCtrl,
                    minLines: 3,
                    maxLines: 8,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(
                      hintText: r'例如：\d{4}-\d{2}-\d{2}',
                      border: OutlineInputBorder(),
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

                  // ===== 替换词 =====
                  _sectionHeader('替换词'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _replaceCtrl,
                    minLines: 3,
                    maxLines: 8,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(
                      hintText: r'例如：$1年$2月$3日',
                      border: OutlineInputBorder(),
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

                  const SizedBox(height: 20),

                  // ===== 作用范围 =====
                  DropdownButtonFormField<RuleScope>(
                    value: _scope,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '作用范围',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                          value: RuleScope.both, child: Text('两侧文件')),
                      DropdownMenuItem(
                          value: RuleScope.originalOnly, child: Text('仅左侧文件')),
                      DropdownMenuItem(
                          value: RuleScope.modifiedOnly, child: Text('仅右侧文件')),
                    ],
                    onChanged: (v) =>
                        setState(() => _scope = v ?? RuleScope.both),
                  ),

                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: s.surfaceVariant.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '查找侧："支持正则"和"仅字面匹配"互斥，必须开一个。\n'
                      '替换侧："\$1 \$2 引用"、"\$1 \$2 引用"、"仅字面输出"'
                      '三者至少开一个。\n'
                      '长按任一开关的标签，可查看并编辑详细说明。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: s.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('恢复默认'),
                    onPressed: _resetToDefault,
                  ),
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
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

  void _submit() {
    final name = _nameCtrl.text.trim();
    final find = _findCtrl.text;
    final replace = _replaceCtrl.text;
    if (name.isEmpty || find.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('规则名和查找词不能为空')),
      );
      return;
    }

    // 只有正则模式才校验。
    final useRegex = _findRegex && !_findLiteral;
    if (useRegex) {
      try {
        var test = find;
        if (_findEscape) test = unescapeEscapes(test);
        RegExp(test);
      } catch (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正则无效，请检查查找词')),
        );
        return;
      }
    }

    final initial = widget.initial;
    Navigator.pop(
      context,
      PreprocessingRule(
        id: initial?.id ?? 'user_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        findPattern: find,
        replaceWith: replace,
        scope: _scope,
        enabled: initial?.enabled ?? true,
        isBuiltin: false,
        findRegex: _findRegex,
        findLiteral: _findLiteral,
        findEscape: _findEscape,
        replaceDollar: _replaceDollar,
        replaceBackslash: _replaceBackslash,
        replaceLiteral: _replaceLiteral,
        replaceEscape: _replaceEscape,
      ),
    );
  }
}

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
                  IconButton(
                    tooltip: '恢复默认说明',
                    icon: const Icon(Icons.restore),
                    onPressed: () {
                      setState(() {
                        _ctrl.text = widget.defaultText;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已恢复默认，点保存生效'),
                          duration: Duration(seconds: 1),
                        ),
                      );
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
