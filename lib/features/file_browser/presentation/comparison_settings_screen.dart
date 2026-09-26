import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../help/presentation/help_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';
import '../../viewer/presentation/providers/diff_viewer_providers.dart';
import 'replace_rules_screen.dart';

/// 忽略项在 UI 里的副标题（因为 PreprocessingRule 没有这个字段）。
const _ignoreSubtitles = <String, String>{
  'ig_nl': r'统一 \r\n / \r / \n 三种换行格式',
  'ig_invisible':
      '删除零宽空格/连字、方向控制、BOM、软连字符、NBSP 等看不见的字符后再对比',
  'ig_ws': '去掉所有空格和 Tab 后对比',
  'ig_empty': '去掉空白行后对比',
  'ig_comma': '英文逗号 , 和中文逗号 ，都删掉后对比',
  'ig_num': '连续数字（如 123）视为占位符 <NUM>',
  'ig_case': 'A 和 a 视为相同',
  'ig_ansi': '非 ANSI 字符（Emoji、生僻字）会被删除。开启会丢失内容，慎用',
};

class ComparisonSettingsScreen extends ConsumerWidget {
  const ComparisonSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userRules = ref.watch(userRulesProvider);
    final builtinRules = ref.watch(builtinRulesWithStateProvider);
    final enabledBuiltin = builtinRules.where((r) => r.enabled).length;
    final ignoreEnables = ref.watch(ignoreRuleEnablesProvider);

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
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // ==================== 一、批量替换规则 ====================
          const _SectionHeader(
            sectionId: 'batch',
            title: '批量替换规则',
            defaultDescription:
                '一整块文本，一行一条。适合一次写很多简单替换，速度快。\n'
                '整块一起生效，没法单独关掉某一条。',
          ),
          _entryTile(
            context,
            ref,
            title: '普通文字替换',
            subtitle: '特殊符号（. * + ? 等）按字面处理，无需转义。',
            isRegex: false,
          ),
          _entryTile(
            context,
            ref,
            title: '正则表达式替换',
            subtitle: r'支持分组引用 $1 $2，适合复杂匹配。',
            isRegex: true,
          ),

          // ==================== 二、单条规则 ====================
          const _SectionHeader(
            sectionId: 'rules',
            title: '单条规则',
            defaultDescription:
                '每条规则一个开关，可单独启用 / 关闭。\n'
                '适合需要精细控制、临时想停某一条的场景。',
          ),
          _SubHeader(title: '自定义规则', count: userRules.length),
          if (userRules.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '还没有自定义规则',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          for (final r in userRules)
            _ruleTile(context, ref, r, builtin: false),
          ListTile(
            leading: Icon(Icons.add_circle_outline,
                color: Theme.of(context).colorScheme.primary),
            title: Text(
              '新建规则',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: const Text(
              '查找正则 → 替换串，可指定只对左侧/右侧生效',
              style: TextStyle(fontSize: 12),
            ),
            onTap: () => _showEditor(context, ref),
          ),

          _SubHeader(
            title: '内置规则',
            count: enabledBuiltin,
            total: builtinRules.length,
          ),
          for (final r in builtinRules)
            _ruleTile(context, ref, r, builtin: true),

          // ==================== 三、忽略项（列表驱动） ====================
          for (final r in defaultIgnoreRules())
            _switchTile(
              context,
              title: r.name,
              subtitle: _ignoreSubtitles[r.id] ?? '',
              value: ignoreEnables[r.id] ?? r.enabled,
              onChanged: (v) => ref
                  .read(ignoreRuleEnablesProvider.notifier)
                  .setOne(r.id, v),
            ),
        ],
      ),
    );
  }

  Widget _entryTile(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String subtitle,
    required bool isRegex,
  }) {
    final text = ref.watch(
      isRegex ? regexRulesTextProvider : keywordRulesTextProvider,
    );
    final n = text.isEmpty
        ? 0
        : text.split('\n').where((l) => l.trim().isNotEmpty).length;

    return ListTile(
      leading: Icon(
        isRegex ? Icons.code : Icons.text_fields,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(title),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$n 条', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ReplaceRulesScreen(isRegex: isRegex),
          ),
        );
      },
    );
  }

  Widget _ruleTile(
    BuildContext context,
    WidgetRef ref,
    PreprocessingRule rule, {
    required bool builtin,
  }) {
    return ListTile(
      title: Text(rule.name),
      subtitle: Text(
        rule.script != null
            ? '(内置脚本: ${rule.script})'
            : '/${rule.findPattern}/ → "${rule.replaceWith}"',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: rule.enabled,
            onChanged: builtin
                ? (v) => ref
                    .read(builtinRuleEnablesProvider.notifier)
                    .setOne(rule.id, v)
                : (v) => ref
                    .read(userRulesProvider.notifier)
                    .updateRule(rule.copyWith(enabled: v)),
          ),
          if (!builtin)
            IconButton(
              tooltip: '移除该规则',
              icon: const Icon(Icons.delete_outline),
              onPressed: () =>
                  ref.read(userRulesProvider.notifier).remove(rule.id),
            ),
        ],
      ),
    );
  }

  Widget _switchTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: Theme.of(context).textTheme.labelSmall,
      ),
      value: value,
      onChanged: onChanged,
    );
  }

  void _showEditor(BuildContext context, WidgetRef ref) async {
    final rule = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => const _RuleEditorDialog(),
    );
    if (rule != null) ref.read(userRulesProvider.notifier).add(rule);
  }
}

class _SectionHeader extends ConsumerWidget {
  const _SectionHeader({
    required this.sectionId,
    required this.title,
    required this.defaultDescription,
  });

  final String sectionId;
  final String title;
  final String defaultDescription;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(_notesProvider);
    final userNote = notes[sectionId];
    final hasNote = userNote != null && userNote.trim().isNotEmpty;
    final s = Theme.of(context).colorScheme;

    return Material(
      color: s.primaryContainer.withOpacity(0.35),
      child: InkWell(
        onTap: () => _openNoteDialog(context, ref, userNote ?? ''),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          margin: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: s.onSurface,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    hasNote
                        ? Icons.sticky_note_2
                        : Icons.sticky_note_2_outlined,
                    size: 18,
                    color: hasNote ? s.primary : s.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                defaultDescription,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: s.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openNoteDialog(
    BuildContext context,
    WidgetRef ref,
    String existing,
  ) async {
    final ctrl = TextEditingController(text: existing);
    final saved = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('$title · 笔记'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                defaultDescription,
                style: Theme.of(c).textTheme.labelSmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                maxLines: 10,
                minLines: 5,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '在这里记点什么…',
                  border: OutlineInputBorder(),
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
      ref.read(_notesProvider.notifier).setOne(sectionId, saved);
    }
  }
}

class _SubHeader extends StatelessWidget {
  const _SubHeader({
    required this.title,
    required this.count,
    this.total,
  });

  final String title;
  final int count;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final countText = total == null ? '$count 条' : '$count / $total 启用';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: s.onSurface,
            ),
          ),
          const Spacer(),
          Text(
            countText,
            style: TextStyle(fontSize: 11, color: s.outline),
          ),
        ],
      ),
    );
  }
}

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

class _RuleEditorDialog extends StatefulWidget {
  const _RuleEditorDialog();

  @override
  State<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<_RuleEditorDialog> {
  final _nameCtrl = TextEditingController();
  final _findCtrl = TextEditingController();
  final _replaceCtrl = TextEditingController();
  RuleScope _scope = RuleScope.both;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建规则'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: '规则名'),
            ),
            TextField(
              controller: _findCtrl,
              decoration: const InputDecoration(
                labelText: '查找正则',
                hintText: r'\d{4}-\d{2}-\d{2}',
              ),
            ),
            TextField(
              controller: _replaceCtrl,
              decoration: const InputDecoration(
                labelText: '替换串',
                hintText: '<DATE>',
              ),
            ),
            DropdownButton<RuleScope>(
              value: _scope,
              isExpanded: true,
              items: const [
                DropdownMenuItem(
                    value: RuleScope.both, child: Text('两份文档')),
                DropdownMenuItem(
                    value: RuleScope.originalOnly, child: Text('仅原文')),
                DropdownMenuItem(
                    value: RuleScope.modifiedOnly, child: Text('仅修改版')),
              ],
              onChanged: (v) => setState(() => _scope = v ?? RuleScope.both),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final find = _findCtrl.text;
    final replace = _replaceCtrl.text;
    if (name.isEmpty || find.isEmpty) return;
    try {
      RegExp(find);
    } on FormatException {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正则无效')),
      );
      return;
    }
    Navigator.pop(
      context,
      PreprocessingRule(
        id: 'user_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        findPattern: find,
        replaceWith: replace,
        scope: _scope,
        enabled: true,
        isBuiltin: false,
      ),
    );
  }
}
