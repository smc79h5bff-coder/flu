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

/// ==================== 6 个开关的默认说明文字 ====================
/// 用户长按标签可查看并编辑，保存后覆盖这里的默认值。
const Map<String, String> _flagHelpDefaults = {
  'findRegex': '''【查找词 · 支持正则】

开：查找词按"正则表达式"解析，特殊符号有特殊含义。
关：查找词按"普通文字"匹配，填什么就匹配什么。

正则里几个常见符号：
  .     任意一个字符
  \\d    任意一个数字
  \\w    字母、数字或下划线
  \\s    空白（空格 / Tab / 换行）
  *     前面的内容出现 0 次或多次
  +     前面的内容出现 1 次或多次
  ?     前面的内容出现 0 次或 1 次
  ()    分组，替换时可用 \$1 \$2 引用

例子：
  查找 \\d+        开=匹配所有连续数字；关=匹配字面"\\d+"
  查找 第\\d+章    开=匹配"第1章""第23章"；关=匹配字面"第\\d+章"

判断标准：想让查找词里的符号有"特殊含义"，就开。
只想按字面找一个固定字符串，就关。''',

  'findEscape': '''【查找词 · 支持转义】

开：查找词里的转义序列会被还原成真字符。
关：转义序列按字面处理。

支持的转义：
  \\n   换行符
  \\r   回车符
  \\t   Tab 制表符
  \\\\   一个反斜杠
  \\0   空字符（NUL）

例子：
  查找 \\n    开=匹配真正的换行；关=匹配"反斜杠+n"两个字符
  查找 \\t    开=匹配真正的 Tab；关=匹配"反斜杠+t"

注意：转义先于正则执行。开了"支持正则"和"支持转义"时，
查找词会先把 \\n 变成真换行，再交给正则引擎。''',

  'findDollar': '''【查找词 · 支持 \$ 行尾锚点】

仅当"支持正则"开启时有意义。

\$ 在正则里表示"行尾位置"。
  abc\$    匹配"以 abc 结尾的行"（abc 后面必须紧跟行尾）

开：\$ 当行尾锚点。
关：\$ 当普通字符，匹配字面的"\$"。

例子：
  查找 abc\$     开=匹配"abc"结尾的行；关=匹配字面"abc\$"
  查找 ^\\d+\$   开=匹配"整行都是数字"的行

提示：大多数情况下保持开启。只有当你真的想匹配一个字面的
"\$"符号时，才关掉它，或者写 \\\$。''',

  'replaceRegex': '''【替换词 · 支持正则（\\1 \\2 引用）】

开：替换词里的 \\1 \\2 会被替换成对应捕获组的内容。
关：\\1 \\2 按字面输出。

捕获组：正则里每出现一对括号 ()，就产生一个捕获组，
从左到右编号 1、2、3……

例子：
  查找 (\\d+)-(\\d+)
  替换 \\2-\\1
  开=把"12-34"变成"34-12"；关=输出字面"\\2-\\1"

注意：
· \\1 是反斜杠+数字的写法，跟 \$1 是两套独立语法。
· 一般用 \$1 就够了（靠"支持 \$"开关）。\\1 属于备用写法。
· 没有捕获组时，\\1 \\2 展开为空串。''',

  'replaceEscape': '''【替换词 · 支持转义】

开：替换词里的转义序列会被还原成真字符。
关：转义序列按字面输出。

支持的转义：
  \\n   换行符
  \\r   回车符
  \\t   Tab 制表符
  \\\\   一个反斜杠
  \\0   空字符（NUL）

例子：
  替换词 \\n          开=输出一个真换行；关=输出"反斜杠+n"
  替换词 第\$1章\\n    开=每章后面跟一个真换行
  替换词 \\t          开=输出一个真 Tab

用途：想在替换结果里插入换行、Tab、反斜杠，就开这个。''',

  'replaceDollar': '''【替换词 · 支持 \$（\$1 \$2 引用）】

开：替换词里的 \$0 \$1 \$2 …… 会被展开。
关：\$0 \$1 \$2 …… 按字面输出。

\$0 表示整个匹配的内容。
\$1 \$2 …… 表示第 1、2、…… 个捕获组的内容。
捕获组就是查找词里每个 () 里的内容。

例子：
  查找 (\\d{4})-(\\d{2})-(\\d{2})
  替换 \$1年\$2月\$3日
  结果：2024-01-01 → 2024年01月01日

  查找 (\\w+)@(\\w+)
  替换 \$2#\$1
  结果：abc@xyz → xyz#abc

提示：这是最常用的捕获组引用方式。配合"查找词·支持正则"
里写 ()，就能实现"记住一部分，搬到另一部分"。''',
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

  // ==================== 列表构建 ====================

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

  // ==================== 拖动 ====================

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

  // ==================== 项渲染 ====================

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
    if (rule.findRegex) flags.add('正则');
    if (rule.findEscape) flags.add('查找转义');
    if (rule.findDollar) flags.add(r'$锚点');
    if (rule.replaceRegex) flags.add(r'\1引用');
    if (rule.replaceEscape) flags.add('替换转义');
    if (rule.replaceDollar) flags.add(r'$1引用');
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

  // ==================== 顶部说明（可点开写笔记） ====================

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

  // ==================== 底部新建 / 进入块编辑 ====================

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

// ==================== 6 开关说明 provider ====================

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

// ==================== 规则编辑弹窗（大窗口 + 6 开关） ====================

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
  late bool _findEscape;
  late bool _findDollar;
  late bool _replaceRegex;
  late bool _replaceEscape;
  late bool _replaceDollar;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _nameCtrl = TextEditingController(text: i?.name ?? '');
    _findCtrl = TextEditingController(text: i?.findPattern ?? '');
    _replaceCtrl = TextEditingController(text: i?.replaceWith ?? '');
    _scope = i?.scope ?? RuleScope.both;
    _findRegex = i?.findRegex ?? true;
    _findEscape = i?.findEscape ?? false;
    _findDollar = i?.findDollar ?? true;
    _replaceRegex = i?.replaceRegex ?? false;
    _replaceEscape = i?.replaceEscape ?? false;
    _replaceDollar = i?.replaceDollar ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    super.dispose();
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
                    tooltip: '全部关闭（纯字符串匹配）',
                    icon: const Icon(Icons.backspace_outlined),
                    onPressed: _resetToPlain,
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
                    hint: '开：按正则解析；关：完全字面匹配',
                    value: _findRegex,
                    onChanged: (v) => setState(() => _findRegex = v),
                  ),
                  _flagSwitch(
                    flagId: 'findEscape',
                    label: r'支持转义（\n \r \t \\ \0）',
                    hint: '开：把这些转义还原成真字符后再匹配',
                    value: _findEscape,
                    onChanged: (v) => setState(() => _findEscape = v),
                  ),
                  _flagSwitch(
                    flagId: 'findDollar',
                    label: r'支持 $（行尾锚点）',
                    hint: r'开：$ 当行尾；关：$ 当普通字符。仅"支持正则"开启时有意义',
                    value: _findDollar,
                    onChanged: (v) => setState(() => _findDollar = v),
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
                    flagId: 'replaceRegex',
                    label: r'支持正则（\1 \2 引用）',
                    hint: r'开：替换串里的 \1 \2 展开为捕获组',
                    value: _replaceRegex,
                    onChanged: (v) => setState(() => _replaceRegex = v),
                  ),
                  _flagSwitch(
                    flagId: 'replaceEscape',
                    label: r'支持转义（\n \r \t \\ \0）',
                    hint: '开：把这些转义还原成真字符后再输出',
                    value: _replaceEscape,
                    onChanged: (v) => setState(() => _replaceEscape = v),
                  ),
                  _flagSwitch(
                    flagId: 'replaceDollar',
                    label: r'支持 $（$1 $2 引用）',
                    hint: r'开：替换串里的 $1 $2 展开为捕获组',
                    value: _replaceDollar,
                    onChanged: (v) => setState(() => _replaceDollar = v),
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
                          value: RuleScope.both, child: Text('两份文档')),
                      DropdownMenuItem(
                          value: RuleScope.originalOnly, child: Text('仅原文')),
                      DropdownMenuItem(
                          value: RuleScope.modifiedOnly, child: Text('仅修改版')),
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
                      '全部关闭 = 纯字符串查找 + 纯字符串替换。\n'
                      '6 个开关互相独立，任意组合。\n'
                      '长按任一开关的标签，可查看并编辑该开关的详细说明。',
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
                    icon: const Icon(Icons.clear_all, size: 18),
                    label: const Text('全部关闭'),
                    onPressed: _resetToPlain,
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

  void _resetToPlain() {
    setState(() {
      _findRegex = false;
      _findEscape = false;
      _findDollar = false;
      _replaceRegex = false;
      _replaceEscape = false;
      _replaceDollar = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已全部关闭 → 纯字符串匹配'),
        duration: Duration(seconds: 1),
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
    if (_findRegex) {
      try {
        var test = find;
        if (_findEscape) test = unescapeEscapes(test);
        if (!_findDollar) test = test.replaceAll(r'$', r'\$');
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
        findEscape: _findEscape,
        findDollar: _findDollar,
        replaceRegex: _replaceRegex,
        replaceEscape: _replaceEscape,
        replaceDollar: _replaceDollar,
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
