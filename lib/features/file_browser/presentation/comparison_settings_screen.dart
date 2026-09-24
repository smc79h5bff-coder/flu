import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../help/presentation/help_screen.dart';
import '../../rules/presentation/rules_management_screen.dart';
import '../../viewer/presentation/providers/diff_viewer_providers.dart';

/// 比较设置页面。
///
/// 集中 4 个原有忽略项 + 3 个新增忽略项 + 规则/帮助入口。
/// 所有开关都是全局默认，改完立即生效；下次对比会用新设置。
class ComparisonSettingsScreen extends ConsumerWidget {
  const ComparisonSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          const Divider(height: 24),
          _sectionHeader(context, '高级'),
          ListTile(
            leading: const Icon(Icons.rule),
            title: const Text('预处理规则'),
            subtitle: const Text('自定义 find / replace 规则，比忽略项更灵活'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const RulesManagementScreen(),
                ),
              );
            },
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
}
