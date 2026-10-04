import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';

/// Manage built-in + custom preprocessing rules. PRD §2 Module 3.3.
class RulesManagementScreen extends ConsumerWidget {
  const RulesManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userRules = ref.watch(userRulesProvider);
    final builtin = ref.watch(builtinRulesWithStateProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('预处理规则')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('新建规则'),
        onPressed: () => _showEditor(context, ref),
      ),
      body: ListView(
        children: [
          const _Section(label: '内置规则（可勾选启用）'),
          for (final r in builtin) _RuleTile(rule: r, builtin: true),
          const _Section(label: '自定义规则'),
          if (userRules.isEmpty)
            const ListTile(title: Text('暂无自定义规则，点击右下新建')),
          for (final r in userRules) _RuleTile(rule: r, builtin: false),
        ],
      ),
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

class _Section extends StatelessWidget {
  const _Section({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(label, style: Theme.of(context).textTheme.labelMedium),
      );
}

class _RuleTile extends ConsumerWidget {
  const _RuleTile({required this.rule, required this.builtin});

  final PreprocessingRule rule;
  final bool builtin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            // ========== 改动（B25）：规则名输入框 ==========
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
              ),
            ),
            const SizedBox(height: 8),

            // ========== 改动（B25）：查找正则输入框 ==========
            TextField(
              controller: _findCtrl,
              cursorColor: AppColors.accentPurple,
              decoration: const InputDecoration(
                labelText: '查找正则',
                hintText: r'\d{4}-\d{2}-\d{2}',
                border: OutlineInputBorder(),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: AppColors.accentPurple,
                    width: 2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // ========== 改动（B25）：替换串输入框 ==========
            TextField(
              controller: _replaceCtrl,
              cursorColor: AppColors.accentPurple,
              decoration: const InputDecoration(
                labelText: '替换串',
                hintText: '<DATE>',
                border: OutlineInputBorder(),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: AppColors.accentPurple,
                    width: 2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // ========== 改动（B25）：作用范围下拉框 ==========
            // 原来用的是 DropdownButton（无边框），换成 DropdownButtonFormField
            // 以便使用边框 / 聚焦变紫等属性。行为和原来完全一样。
            DropdownButtonFormField<RuleScope>(
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
              ),
              items: const [
                DropdownMenuItem(
                  value: RuleScope.both,
                  child: Text('两份文档',
                      style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: RuleScope.originalOnly,
                  child: Text('仅原文',
                      style: TextStyle(color: Colors.black)),
                ),
                DropdownMenuItem(
                  value: RuleScope.modifiedOnly,
                  child: Text('仅修改版',
                      style: TextStyle(color: Colors.black)),
                ),
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
      RegExp(find); // validate
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
