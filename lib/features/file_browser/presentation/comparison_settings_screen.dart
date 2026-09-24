import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../help/presentation/help_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';
import '../../viewer/presentation/providers/diff_viewer_providers.dart';

/// 比较设置页面。
///
/// 把所有对比相关的可调项集中在一页：
///   - 忽略项：空白 / 空行 / 换行 / 大小写 / 逗号 / 数字 / ANSI
///   - 内置预处理规则（可勾选启用）
///   - 用户自定义预处理规则（可增删）
///   - 新建自定义规则
///
/// 从文件管理器和对比页都能进入；两处打开的是同一个页面。
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
          _sectionHeader(context, '忽略项'),
          _switchTile(
            context,
            title: '忽略空白符号',
            subtitle: '去掉所有空格和 Tab 后对比',
            value: ref.watch(ignoreWhitespaceProvider),
            onChanged: (v) =>
                ref.read(ignoreWhitespaceProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '忽略空行',
            subtitle: '去掉空白行后对比',
            value: ref.watch(ignoreEmptyLinesProvider),
            onChanged: (v) =>
                ref.read(ignoreEmptyLinesProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '忽略换行符',
            subtitle: r'统一 \r\n / \r / \n 三种换行格式',
            value: ref.watch(ignoreLineEndingsProvider),
            onChanged: (v) =>
                ref.read(ignoreLineEndingsProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '忽略大小写',
            subtitle: 'A 和 a 视为相同',
            value: ref.watch(ignoreCaseProvider),
            onChanged: (v) =>
                ref.read(ignoreCaseProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '忽略中英文逗号',
            subtitle: '去掉英文 , 和中文 ， 后对比',
            value: ref.watch(ignoreCommasProvider),
            onChanged: (v) =>
                ref.read(ignoreCommasProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '忽略纯数字',
            subtitle: '连续数字（如 123）视为占位符 <NUM>',
            value: ref.watch(ignoreNumbersProvider),
            onChanged: (v) =>
                ref.read(ignoreNumbersProvider.notifier).state = v,
          ),
          _switchTile(
            context,
            title: '统一编码 ANSI',
            subtitle: '非 ANSI 字符（Emoji、生僻字）会被删除。开启会丢失内容，慎用',
            value: ref.watch(unifyAnsiProvider),
            onChanged: (v) =>
                ref.read(unifyAnsiProvider.notifier).state = v,
          ),

          const Divider(height: 32),
          _sectionHeader(context, '内置预处理规则（可勾选启用）'),
          for (final r in builtinRules)
            _ruleTile(
              context,
              rule: r,
              onToggle: (v) => ref
                  .read(builtinRuleEnablesProvider.notifier)
                  .update((prev) => {...prev, r.id: v}),
            ),

          const Divider(height: 32),
          _sectionHeader(context, '自定义预处理规则'),
          if (userRules.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '暂无自定义规则',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          for (final r in userRules)
            _ruleTile(
              context,
              rule: r,
              onToggle: (v) => ref
                  .read(userRulesProvider.notifier)
                  .update(r.copyWith(enabled: v)),
              onDelete: () =>
                  ref.read(userRulesProvider.notifier).remove(r.id),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('新建自定义规则'),
              onPressed: () => _showEditor(context, ref),
            ),
          ),

          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '所有设置立即生效。下次打开对比页会使用新的设置。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
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

  Widget _ruleTile(
    BuildContext context, {
    required PreprocessingRule rule,
    required ValueChanged<bool> onToggle,
    VoidCallback? onDelete,
  }) {
    return ListTile(
      title: Text(rule.name),
      subtitle: Text(
        '/${rule.findPattern}/ → "${rule.replaceWith}"',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(value: rule.enabled, onChanged: onToggle),
          if (onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '移除',
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }

  void _showEditor(BuildContext context, WidgetRef ref) {
    showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => const _RuleEditorDialog(),
    ).then((rule) {
      if (rule != null) {
        ref.read(userRulesProvider.notifier).add(rule);
      }
    });
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
            const SizedBox(height: 12),
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
