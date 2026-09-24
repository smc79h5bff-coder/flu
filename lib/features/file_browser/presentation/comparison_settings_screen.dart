import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../help/presentation/help_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';
import '../../viewer/presentation/providers/diff_viewer_providers.dart';

/// 比较设置页面。所有规则/开关在同一列表中，顺序：
///   自定义规则 → 内置规则 → 忽略项
/// 无分区标题、无分割线。
class ComparisonSettingsScreen extends ConsumerWidget {
  const ComparisonSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userRules = ref.watch(userRulesProvider);
    final builtinRules = ref.watch(builtinRulesWithStateProvider);

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
        children: [
          // ---- 1. 自定义规则 ----
          for (final r in userRules)
            _ruleTile(context, ref, r, builtin: false),
          ListTile(
            leading: Icon(Icons.add_circle_outline,
                color: Theme.of(context).colorScheme.primary),
            title: const Text('新建规则'),
            onTap: () => _showEditor(context, ref),
          ),

          // ---- 2. 内置规则 ----
          for (final r in builtinRules)
            _ruleTile(context, ref, r, builtin: true),

          // ---- 3. 忽略项 ----
          _switchTile(
            context,
            title: '删掉空白符号',
            subtitle: '去掉所有空格和 Tab 后对比',
            value: ref.watch(ignoreWhitespaceProvider),
            onChanged: (v) =>
                ref.read(ignoreWhitespaceProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '删掉空行',
            subtitle: '去掉空白行后对比',
            value: ref.watch(ignoreEmptyLinesProvider),
            onChanged: (v) =>
                ref.read(ignoreEmptyLinesProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '统一换行符',
            subtitle: r'统一 \r\n / \r / \n 三种换行格式',
            value: ref.watch(ignoreLineEndingsProvider),
            onChanged: (v) =>
                ref.read(ignoreLineEndingsProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '大写全转成小写',
            subtitle: 'A 和 a 视为相同',
            value: ref.watch(ignoreCaseProvider),
            onChanged: (v) =>
                ref.read(ignoreCaseProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '忽略纯数字（数字改为占位符）',
            subtitle: '连续数字（如 123）视为占位符 <NUM>',
            value: ref.watch(ignoreNumbersProvider),
            onChanged: (v) =>
                ref.read(ignoreNumbersProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '忽略不可见字符',
            subtitle: '删除零宽空格/连字、方向控制、BOM、软连字符、NBSP 等看不见的字符后再对比',
            value: ref.watch(ignoreInvisibleProvider),
            onChanged: (v) =>
                ref.read(ignoreInvisibleProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '统一编码 ANSI',
            subtitle: '非 ANSI 字符（Emoji、生僻字）会被删除。开启会丢失内容，慎用',
            value: ref.watch(unifyAnsiProvider),
            onChanged: (v) =>
                ref.read(unifyAnsiProvider.notifier).state = v,
          ),

          const SizedBox(height: 32),
        ],
      ),
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
        '/${rule.findPattern}/ → "${rule.replaceWith}"',
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
                    .update((prev) => {...prev, rule.id: v})
                : (v) => ref
                    .read(userRulesProvider.notifier)
                    .update(rule.copyWith(enabled: v)),
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

/// 新建规则对话框。从 rules_management_screen.dart 复制过来，
/// 保持和原来一致的行为。
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
