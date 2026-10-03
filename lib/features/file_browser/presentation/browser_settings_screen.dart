import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/file_browser_providers.dart';

/// 文件浏览器设置页。
///
/// 目前只有一项：点击文件时的打开方式。
/// 未来加新设置直接往 [_buildSections] 里追加 section。
class BrowserSettingsScreen extends ConsumerWidget {
  const BrowserSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('浏览器设置')),
      body: ListView(
        children: [
          ..._buildSections(context, ref),
        ],
      ),
    );
  }

  List<Widget> _buildSections(BuildContext context, WidgetRef ref) {
    return [
      _buildOpenModeSection(context, ref),
      // 未来在这里追加更多 section：
      // _buildSortSection(context, ref),
      // _buildThemeSection(context, ref),
      // ...
    ];
  }

  Widget _buildOpenModeSection(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(fileOpenModeProvider);
    final n = ref.read(fileOpenModeProvider.notifier);

    Widget tile({
      required FileOpenMode value,
      required IconData icon,
      required String title,
      required String subtitle,
    }) {
      return RadioListTile<FileOpenMode>(
        value: value,
        groupValue: mode,
        onChanged: (v) {
          if (v != null) n.update(v);
        },
        title: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 10),
            Text(title),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(left: 30, top: 2),
          child: Text(subtitle, style: const TextStyle(fontSize: 12)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: '点击文件时',
          subtitle: '点击文本文件时用哪种方式打开。设置会一直记住，下次启动仍生效。',
        ),
        tile(
          value: FileOpenMode.reader,
          icon: Icons.menu_book,
          title: '阅读器',
          subtitle: '分页翻页，适合看小说。不能编辑',
        ),
        tile(
          value: FileOpenMode.editor,
          icon: Icons.edit_note,
          title: '旧编辑器',
          subtitle: '功能全，但大文件会卡',
        ),
        tile(
          value: FileOpenMode.lineEditor,
          icon: Icons.view_list,
          title: '行编辑器',
          subtitle: '虚拟化逐行渲染，大文件流畅',
        ),
        tile(
          value: FileOpenMode.ask,
          icon: Icons.help_outline,
          title: '每次询问',
          subtitle: '每次点击文件都弹窗问一次（弹窗里可以勾选"记住"）',
        ),
        const SizedBox(height: 12),
        const Divider(),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: s.primary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(fontSize: 12, color: s.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
