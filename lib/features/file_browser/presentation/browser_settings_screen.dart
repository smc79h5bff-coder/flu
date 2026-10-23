import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/skin.dart';
import 'providers/file_browser_providers.dart';

/// 文件浏览器设置页。
///
/// 包含：
///   · 主题皮肤
///   · 显示方式（列表 / 网格）
///   · 网格显示内容
///   · 字号
///   · 排序（方式 + 方向，左右并排）
///   · 点击文件时的打开方式
///
/// 右上角 ? 打开"使用说明"，Tab 化，可编辑可保存。
class BrowserSettingsScreen extends ConsumerWidget {
  const BrowserSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gridMode = ref.watch(browserGridModeProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('浏览器设置'),
      ),
      body: ListView(
        children: [
          _buildSkinSection(context, ref),
          const Divider(height: 1),
          _buildSearchBarSection(context, ref),
          const Divider(height: 1),
          _buildDisplayModeSection(context, ref),
          const Divider(height: 1),

          // 只有网格模式才显示"网格显示内容"
          if (gridMode) ...[
            _buildGridContentSection(context, ref),
            const Divider(height: 1),
          ],

          _buildFontSizeSection(context, ref),
          const Divider(height: 1),
          _buildScrollbarSection(context, ref),
          const Divider(height: 1),
          _buildFloatingPageSection(context, ref),
          const Divider(height: 1),
          _buildSortSection(context, ref),
          const Divider(height: 1),
          _buildOpenModeSection(context, ref),
        ],
      ),
    );
  }

  // ==================== 主题皮肤 ====================

  Widget _buildSkinSection(BuildContext context, WidgetRef ref) {
    final current = ref.watch(skinProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: '主题皮肤',
          subtitle: '切换后立即生效，自动保存，下次启动仍生效。',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              for (final skin in AppSkin.values)
                _SkinDot(
                  skin: skin,
                  selected: skin == current,
                  onTap: () =>
                      ref.read(skinProvider.notifier).update(skin),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ==================== 搜索栏 ====================

  Widget _buildSearchBarSection(BuildContext context, WidgetRef ref) {
    final current = ref.watch(searchBarVisibilityProvider);
    final isCollapsible = current == SearchBarVisibility.collapsible;
    final isAlwaysVisible = current == SearchBarVisibility.alwaysVisible;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: '搜索栏',
          subtitle: '控制文件浏览器里搜索栏的显示方式。',
        ),
        RadioListTile<SearchBarVisibility>(
          value: SearchBarVisibility.collapsible,
          groupValue: current,
          activeColor: cs.primary,
          onChanged: (v) {
            if (v != null) {
              ref.read(searchBarVisibilityProvider.notifier).update(v);
            }
          },
          title: Text(
            '可折叠',
            style: TextStyle(
              color: isCollapsible ? cs.primary : cs.onSurface,
              fontWeight:
                  isCollapsible ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          subtitle: const Text(
            '平时显示，点右上角图标可以收起，随时再展开。',
            style: TextStyle(fontSize: 12),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        RadioListTile<SearchBarVisibility>(
          value: SearchBarVisibility.alwaysVisible,
          groupValue: current,
          activeColor: cs.primary,
          onChanged: (v) {
            if (v != null) {
              ref.read(searchBarVisibilityProvider.notifier).update(v);
            }
          },
          title: Text(
            '始终显示',
            style: TextStyle(
              color: isAlwaysVisible ? cs.primary : cs.onSurface,
              fontWeight:
                  isAlwaysVisible ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          subtitle: const Text(
            '搜索栏永远显示，右上角不出现收起按钮。',
            style: TextStyle(fontSize: 12),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // ==================== 显示方式 ====================
Widget _buildDisplayModeSection(BuildContext context, WidgetRef ref) {
  final gridMode = ref.watch(browserGridModeProvider);
  final compact = ref.watch(browserListCompactProvider);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SectionHeader(title: '显示方式'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Row(
          children: [
            ChoiceChip(
              label: const Text('列表'),
              selected: !gridMode,
              onSelected: (_) {
                ref.read(browserGridModeProvider.notifier).update(false);
              },
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('网格'),
              selected: gridMode,
              onSelected: (_) {
                ref.read(browserGridModeProvider.notifier).update(true);
              },
            ),
          ],
        ),
      ),
      // 列表模式下的行高：默认是 MD3 的宽松间距，打开后更紧凑。
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: _SwitchRow(
          label: '紧凑列表（行距更小，一屏显示更多文件）',
          value: compact,
          enabled: !gridMode,
          onChanged: (v) =>
              ref.read(browserListCompactProvider.notifier).update(v),
        ),
      ),
    ],
  );
}

  // ==================== 网格显示内容 ====================

  Widget _buildGridContentSection(BuildContext context, WidgetRef ref) {
    final showSize = ref.watch(browserGridShowSizeProvider);
    final showTime = ref.watch(browserGridShowTimeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '网格显示内容'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: _SwitchRow(
                  label: '显示大小',
                  value: showSize,
                  enabled: true,
                  onChanged: (v) => ref
                      .read(browserGridShowSizeProvider.notifier)
                      .update(v),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _SwitchRow(
                  label: '显示时间',
                  value: showTime,
                  enabled: true,
                  onChanged: (v) => ref
                      .read(browserGridShowTimeProvider.notifier)
                      .update(v),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  // ==================== 字号 ====================

  Widget _buildFontSizeSection(BuildContext context, WidgetRef ref) {
    final gridMode = ref.watch(browserGridModeProvider);
    final listName = ref.watch(browserFontListNameProvider);
    final listMeta = ref.watch(browserFontListMetaProvider);
    final gridName = ref.watch(browserFontGridNameProvider);
    final gridMeta = ref.watch(browserFontGridMetaProvider);

    final nameValue = gridMode ? gridName : listName;
    final metaValue = gridMode ? gridMeta : listMeta;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '字号',
          subtitle: gridMode ? '网格模式' : '列表模式',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: _FontSizeRow(
                  label: '文件名',
                  value: nameValue,
                  onChanged: (v) {
                    if (gridMode) {
                      ref
                          .read(browserFontGridNameProvider.notifier)
                          .set(v);
                    } else {
                      ref
                          .read(browserFontListNameProvider.notifier)
                          .set(v);
                    }
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _FontSizeRow(
                  label: '大小/时间',
                  value: metaValue,
                  onChanged: (v) {
                    if (gridMode) {
                      ref
                          .read(browserFontGridMetaProvider.notifier)
                          .set(v);
                    } else {
                      ref
                          .read(browserFontListMetaProvider.notifier)
                          .set(v);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==================== 滚动条 ====================

  Widget _buildScrollbarSection(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(browserScrollbarEnabledProvider);
    final track = ref.watch(browserScrollbarTrackColorProvider);
    final thumb = ref.watch(browserScrollbarThumbColorProvider);
    final opacity = ref.watch(browserScrollbarOpacityProvider);
    final width = ref.watch(browserScrollbarWidthProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: '滚动条',
          subtitle: '默认关闭。打开后列表右侧会出现一根可以拖动/点按的滚动条。',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: _SwitchRow(
            label: '显示滚动条',
            value: enabled,
            enabled: true,
            onChanged: (v) =>
                ref.read(browserScrollbarEnabledProvider.notifier).update(v),
          ),
        ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              children: [
                _ColorRow(
                  label: '轨道颜色',
                  color: track,
                  onChanged: (c) => ref
                      .read(browserScrollbarTrackColorProvider.notifier)
                      .update(c),
                ),
                _ColorRow(
                  label: '拖动块颜色',
                  color: thumb,
                  onChanged: (c) => ref
                      .read(browserScrollbarThumbColorProvider.notifier)
                      .update(c),
                ),
                _SliderRow(
                  label: '透明度',
                  value: opacity,
                  min: 0,
                  max: 100,
                  suffix: '%',
                  onChanged: (v) => ref
                      .read(browserScrollbarOpacityProvider.notifier)
                      .update(v),
                ),
                _SliderRow(
                  label: '宽度',
                  value: width,
                  min: 2,
                  max: 28,
                  suffix: '',
                  onChanged: (v) => ref
                      .read(browserScrollbarWidthProvider.notifier)
                      .update(v),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  // ==================== 悬浮翻页按钮 ====================

  Widget _buildFloatingPageSection(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(browserFloatingPageEnabledProvider);
    final color = ref.watch(browserFloatingPageColorProvider);
    final opacity = ref.watch(browserFloatingPageOpacityProvider);
    final size = ref.watch(browserFloatingPageSizeProvider);
    final upX = ref.watch(browserFloatingPageUpXProvider);
    final upY = ref.watch(browserFloatingPageUpYProvider);
    final downX = ref.watch(browserFloatingPageDownXProvider);
    final downY = ref.watch(browserFloatingPageDownYProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: '悬浮翻页按钮',
          subtitle: '默认关闭。打开后列表上出现上/下两个悬浮按钮，点一下翻一页；'
              '向下翻页时，上一页最后一个文件仍会显示在最上面。',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: _SwitchRow(
            label: '显示悬浮翻页按钮',
            value: enabled,
            enabled: true,
            onChanged: (v) => ref
                .read(browserFloatingPageEnabledProvider.notifier)
                .update(v),
          ),
        ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ColorRow(
                  label: '按钮颜色',
                  color: color,
                  onChanged: (c) => ref
                      .read(browserFloatingPageColorProvider.notifier)
                      .update(c),
                ),
                _SliderRow(
                  label: '透明度',
                  value: opacity,
                  min: 0,
                  max: 100,
                  suffix: '%',
                  onChanged: (v) => ref
                      .read(browserFloatingPageOpacityProvider.notifier)
                      .update(v),
                ),
                _SliderRow(
                  label: '大小',
                  value: size,
                  min: 28,
                  max: 88,
                  suffix: '',
                  onChanged: (v) => ref
                      .read(browserFloatingPageSizeProvider.notifier)
                      .update(v),
                ),
                const SizedBox(height: 8),
                Text(
                  '上按钮位置',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                _SliderRow(
                  label: 'X',
                  value: upX,
                  min: 0,
                  max: 100,
                  suffix: '%',
                  onChanged: (v) => ref
                      .read(browserFloatingPageUpXProvider.notifier)
                      .update(v),
                ),
                _SliderRow(
                  label: 'Y',
                  value: upY,
                  min: 0,
                  max: 100,
                  suffix: '%',
                  onChanged: (v) => ref
                      .read(browserFloatingPageUpYProvider.notifier)
                      .update(v),
                ),
                const SizedBox(height: 8),
                Text(
                  '下按钮位置',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                _SliderRow(
                  label: 'X',
                  value: downX,
                  min: 0,
                  max: 100,
                  suffix: '%',
                  onChanged: (v) => ref
                      .read(browserFloatingPageDownXProvider.notifier)
                      .update(v),
                ),
                _SliderRow(
                  label: 'Y',
                  value: downY,
                  min: 0,
                  max: 100,
                  suffix: '%',
                  onChanged: (v) => ref
                      .read(browserFloatingPageDownYProvider.notifier)
                      .update(v),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  // ==================== 排序 ====================

  Widget _buildSortSection(BuildContext context, WidgetRef ref) {
    final sortField = ref.watch(sortFieldProvider);
    final sortAsc = ref.watch(sortAscProvider);
    final s = Theme.of(context).colorScheme;

    final labelStyle = TextStyle(
      fontSize: 12,
      color: s.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '排序'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 左：排序方式（3 行）
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('排序方式', style: labelStyle),
                      const SizedBox(height: 4),
                      for (final f in SortField.values)
                        _RadioRow(
                          label: _sortLabel(f),
                          selected: sortField == f,
                          onTap: () {
                            ref
                                .read(sortFieldProvider.notifier)
                                .update(f);
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // 右：升序 / 降序（2 行，均匀分布在左 3 行的行间）
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('排序方向', style: labelStyle),
                      Expanded(
                        child: Column(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceAround,
                          children: [
                            _RadioRow(
                              label: '升序',
                              selected: sortAsc,
                              onTap: () {
                                ref
                                    .read(sortAscProvider.notifier)
                                    .update(true);
                              },
                            ),
                            _RadioRow(
                              label: '降序',
                              selected: !sortAsc,
                              onTap: () {
                                ref
                                    .read(sortAscProvider.notifier)
                                    .update(false);
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _sortLabel(SortField f) {
    switch (f) {
      case SortField.name:
        return '名称';
      case SortField.modified:
        return '修改时间';
      case SortField.size:
        return '大小';
    }
  }

  // ==================== 打开方式 ====================

  Widget _buildOpenModeSection(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(fileOpenModeProvider);
    final n = ref.read(fileOpenModeProvider.notifier);
    final s = Theme.of(context).colorScheme;

    Widget tile({
      required FileOpenMode value,
      required IconData icon,
      required String title,
      required String subtitle,
    }) {
      final selected = mode == value;
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
            Text(
              title,
              style: TextStyle(
                color: selected ? s.primary : null,
                fontWeight:
                    selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
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
      ],
    );
  }

  // ==================== 说明弹窗 ====================

  Future<void> _showHelp(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _SettingsHelpDialog(),
    );
  }
}

// ==================== 复用小部件 ====================

/// 一个皮肤色块：彩色圆圈 + 名字，选中时外面套一圈 + 打勾。
class _SkinDot extends StatelessWidget {
  const _SkinDot({
    required this.skin,
    required this.selected,
    required this.onTap,
  });

  final AppSkin skin;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: skin.seed,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? s.onSurface : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: selected
                  ? Icon(Icons.check,
                      color: Theme.of(context).colorScheme.onPrimary,
                      size: 20)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              skin.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.subtitle,
    this.dim = false,
  });

  final String title;
  final String? subtitle;
  final bool dim;

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
              color: dim ? s.onSurfaceVariant : s.primary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                color: s.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一行开关。`enabled = false` 时开关变灰不能点。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: enabled ? null : Theme.of(context).disabledColor,
            ),
          ),
        ),
        Switch(
          value: value,
          onChanged: enabled ? onChanged : null,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}

/// 一行颜色：标签 + 色值 + 色块（点色块打开取色板）。
class _ColorRow extends StatelessWidget {
  const _ColorRow({
    required this.label,
    required this.color,
    required this.onChanged,
  });

  final String label;
  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final argb = color.toARGB32();
    final hex = '#${argb.toRadixString(16).padLeft(8, '0').substring(2)}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Text(
            hex.toUpperCase(),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: s.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () async {
              final picked = await _pickColorDialog(context, color);
              if (picked != null) onChanged(picked);
            },
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(color: s.outline),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行滑块：标签 + 当前值 + 滑杆。
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(min, max).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
            Text(
              '${v.round()}$suffix',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        SizedBox(
          height: 28,
          child: Slider(
            value: v,
            min: min,
            max: max,
            divisions: (max - min).round(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// 取色弹窗。返回选中的颜色；取消返回 null。
Future<Color?> _pickColorDialog(BuildContext context, Color initial) async {
  var picked = initial;
  final argb = picked.toARGB32();
  final controller = TextEditingController(
    text: '#${argb.toRadixString(16).padLeft(8, '0').substring(2)}',
  );

  try {
    return await showDialog<Color>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialogState) => AlertDialog(
          insetPadding: const EdgeInsets.all(8),
          title: const Text('选择颜色'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ColorPicker(
                  pickerColor: picked,
                  onColorChanged: (color) {
                    picked = color;
                    controller.text = '#'
                        '${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
                  },
                  enableAlpha: false,
                  labelTypes: const [],
                  pickerAreaHeightPercent: 0.7,
                  displayThumbColor: true,
                  portraitOnly: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: '#RRGGBB',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (v) {
                    final text = v.trim().replaceFirst('#', '');
                    final n = int.tryParse(text, radix: 16);
                    if (n != null) {
                      picked = Color(0xFF000000 | n);
                      setDialogState(() {});
                    }
                  },
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
              onPressed: () => Navigator.pop(c, picked),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  } finally {
    controller.dispose();
  }
}

/// 一行字号控件：标签 + [-] [输入框] [+]
class _FontSizeRow extends StatefulWidget {
  const _FontSizeRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_FontSizeRow> createState() => _FontSizeRowState();
}

class _FontSizeRowState extends State<_FontSizeRow> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value.round().toString());
  }

  @override
  void didUpdateWidget(covariant _FontSizeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cur = widget.value.round().toString();
    if (_ctrl.text != cur) {
      _ctrl.text = cur;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _step(int delta) {
    final next = (widget.value.round() + delta).clamp(1, 38).toDouble();
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 2),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.remove, size: 18),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 28,
                minHeight: 28,
              ),
              onPressed: () => _step(-1),
            ),
            // 输入框缩窄：能容纳 5 个数字左右
            SizedBox(
              width: 44,
              child: TextFormField(
                controller: _ctrl,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 6,
                  ),
                ),
                onFieldSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (n == null) {
                    _ctrl.text = widget.value.round().toString();
                    return;
                  }
                  final clamped = n.clamp(1, 38).toDouble();
                  widget.onChanged(clamped);
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 28,
                minHeight: 28,
              ),
              onPressed: () => _step(1),
            ),
          ],
        ),
      ],
    );
  }
}

/// 一行单选项：圆圈 + 文字。
///
/// 选中时圆圈是主题色（紫），文字也跟随主题色并加粗。
class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              size: 20,
              color: selected ? s.primary : s.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: selected ? s.primary : null,
                fontWeight:
                    selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 说明弹窗（Tab 化，可编辑） ====================

class _SettingsHelpDialog extends ConsumerStatefulWidget {
  const _SettingsHelpDialog();

  @override
  ConsumerState<_SettingsHelpDialog> createState() =>
      _SettingsHelpDialogState();
}

class _SettingsHelpDialogState extends ConsumerState<_SettingsHelpDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  int _lastIndex = 0;

  List<BrowserHelpTab> _tabs = const [];
  bool _editing = false;

  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _contentCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final saved = ref.read(browserSettingsHelpProvider);
    _tabs = List<BrowserHelpTab>.from(saved);
    if (_tabs.isEmpty) _tabs = defaultBrowserHelpTabs();
    _tabCtrl = TabController(length: _tabs.length, vsync: this);
    _tabCtrl.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabCtrl.removeListener(_onTabChanged);
    _tabCtrl.dispose();
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_lastIndex == _tabCtrl.index) return;
    _lastIndex = _tabCtrl.index;
    if (mounted) setState(() {});
  }

  void _recreateTabCtrl(int length, int initial) {
    final old = _tabCtrl;
    old.removeListener(_onTabChanged);
    final newCtrl = TabController(
      length: length,
      initialIndex: length == 0 ? 0 : initial.clamp(0, length - 1),
      vsync: this,
    );
    newCtrl.addListener(_onTabChanged);
    _tabCtrl = newCtrl;
    _lastIndex = newCtrl.index;
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  Future<void> _persist() async {
    ref.read(browserSettingsHelpProvider.notifier).setAll(_tabs);
  }

  // ==================== 编辑 ====================

  void _enterEdit() {
    final idx = _tabCtrl.index;
    if (idx < 0 || idx >= _tabs.length) return;
    final t = _tabs[idx];
    _titleCtrl.text = t.title;
    _contentCtrl.text = t.content;
    setState(() => _editing = true);
  }

  void _cancelEdit() {
    setState(() => _editing = false);
  }

  Future<void> _saveEdit() async {
    final idx = _tabCtrl.index;
    if (idx < 0 || idx >= _tabs.length) return;
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _snack('Tab 名不能为空');
      return;
    }
    final next = List<BrowserHelpTab>.from(_tabs);
    next[idx] = next[idx].copyWith(
      title: title,
      content: _contentCtrl.text,
    );
    setState(() {
      _tabs = next;
      _editing = false;
    });
    await _persist();
    _snack('已保存');
  }

  // ==================== Tab 管理 ====================

  Future<void> _createTab() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('新建 Tab'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Tab 名',
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
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;

    final newTab = BrowserHelpTab(
      id: 'user_${DateTime.now().microsecondsSinceEpoch}',
      title: name.trim(),
      content: '',
    );
    final next = [..._tabs, newTab];
    setState(() => _tabs = next);
    _recreateTabCtrl(next.length, next.length - 1);
    await _persist();
    _enterEdit();
  }

  Future<void> _renameCurrent() async {
    final idx = _tabCtrl.index;
    if (idx < 0 || idx >= _tabs.length) return;
    final ctrl = TextEditingController(text: _tabs[idx].title);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名 Tab'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
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
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    final next = List<BrowserHelpTab>.from(_tabs);
    next[idx] = next[idx].copyWith(title: name.trim());
    setState(() => _tabs = next);
    await _persist();
  }

  Future<void> _deleteCurrent() async {
    if (_tabs.length <= 1) {
      _snack('至少保留一个 Tab');
      return;
    }
    final idx = _tabCtrl.index;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除「${_tabs[idx].title}」？'),
        content: const Text('此 Tab 的内容会一并删除，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final next = List<BrowserHelpTab>.from(_tabs)..removeAt(idx);
    final newIdx = idx >= next.length ? next.length - 1 : idx;
    setState(() => _tabs = next);
    _recreateTabCtrl(next.length, newIdx);
    await _persist();
  }

  Future<void> _moveCurrent(int delta) async {
    final idx = _tabCtrl.index;
    final j = idx + delta;
    if (j < 0 || j >= _tabs.length) return;
    final next = List<BrowserHelpTab>.from(_tabs);
    final t = next.removeAt(idx);
    next.insert(j, t);
    setState(() => _tabs = next);
    _recreateTabCtrl(next.length, j);
    await _persist();
  }

  Future<void> _confirmResetAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('恢复默认 Tab？'),
        content: const Text(
          '当前所有 Tab（包括你新建的、改过内容的）会被替换成 4 个默认 Tab。\n'
          '此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final next = defaultBrowserHelpTabs();
    setState(() => _tabs = next);
    _recreateTabCtrl(next.length, 0);
    await _persist();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  // ==================== build ====================

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.all(4),
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            // ---------- 标题栏 ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '浏览器 · 使用说明',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (_editing) ...[
                    TextButton(
                      onPressed: _cancelEdit,
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: _saveEdit,
                      child: const Text('保存'),
                    ),
                  ] else ...[
                    TextButton(
                      onPressed: _enterEdit,
                      child: const Text('编辑'),
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert),
                      onSelected: (v) {
                        switch (v) {
                          case 'create':
                            _createTab();
                          case 'rename':
                            _renameCurrent();
                          case 'delete':
                            _deleteCurrent();
                          case 'reset':
                            _confirmResetAll();
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'create',
                          child: Text('新建 Tab'),
                        ),
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('重命名 Tab'),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          enabled: _tabs.length > 1,
                          child: const Text('删除 Tab'),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'reset',
                          child: Text('恢复默认 Tab'),
                        ),
                      ],
                    ),
                  ],
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // ---------- TabBar ----------
            _buildTabBar(s),

            // ---------- 编辑态下的 Tab 名输入框 ----------
            if (_editing) _buildEditTitleBar(s),

            // ---------- 工具栏（非编辑态） ----------
            if (!_editing) _buildToolbar(),

            // ---------- 内容区 ----------
            Expanded(
              child: _editing
                  ? _buildEditor()
                  : _buildContent(s),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(ColorScheme s) {
    final bar = Container(
      color: s.surface,
      child: TabBar(
        controller: _tabCtrl,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        tabs: [
          for (final t in _tabs) Tab(text: t.title),
        ],
      ),
    );
    if (!_editing) return bar;
    return IgnorePointer(
      child: Opacity(opacity: 0.55, child: bar),
    );
  }

  Widget _buildEditTitleBar(ColorScheme s) {
    return Container(
      color: s.surfaceVariant.withValues(alpha: 0.3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        controller: _titleCtrl,
        decoration: const InputDecoration(
          labelText: 'Tab 名',
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final idx = _tabCtrl.index;
    final canLeft = idx > 0;
    final canRight = idx < _tabs.length - 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          _circleArrowButton(
            icon: Icons.arrow_back,
            tooltip: '左移此 Tab',
            onPressed: canLeft ? () => _moveCurrent(-1) : null,
          ),
          const SizedBox(width: 8),
          _circleArrowButton(
            icon: Icons.arrow_forward,
            tooltip: '右移此 Tab',
            onPressed: canRight ? () => _moveCurrent(1) : null,
          ),
        ],
      ),
    );
  }

  /// 带白色半透明圆形背景的箭头按钮。
  /// 视觉圆形 40×40，点击区域 64×44（横向更宽）。
  Widget _circleArrowButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: 64,
          height: 44,
          alignment: Alignment.center,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.5),
            ),
            child: Icon(
              icon,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  // ========== 改动：使用 Markdown 渲染 ==========
  Widget _buildContent(ColorScheme s) {
    final idx = _tabCtrl.index;
    if (idx < 0 || idx >= _tabs.length) return const SizedBox.shrink();
    final tab = _tabs[idx];

    if (tab.content.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SelectableText(
          '（此 Tab 还没有内容。点上方"编辑"写点什么。）',
        ),
      );
    }

    return Markdown(
      data: tab.content,
      selectable: true,
      padding: const EdgeInsets.all(12),
      styleSheet: MarkdownStyleSheet(
        h1: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          height: 1.5,
        ),
        h2: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.bold,
          height: 1.5,
        ),
        h3: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.5,
        ),
        p: const TextStyle(fontSize: 13.5, height: 1.65),
        listBullet: const TextStyle(fontSize: 13.5, height: 1.65),
        listIndent: 20,
        strong: const TextStyle(fontWeight: FontWeight.bold),
        em: const TextStyle(fontStyle: FontStyle.italic),
        code: TextStyle(
          fontSize: 13,
          fontFamily: 'monospace',
          backgroundColor: s.surfaceVariant.withValues(alpha: 0.4),
        ),
        codeblockDecoration: BoxDecoration(
          color: s.surfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(6),
        ),
        codeblockPadding: const EdgeInsets.all(10),
        blockquote: TextStyle(
          fontSize: 13,
          color: s.onSurfaceVariant,
          height: 1.6,
        ),
        blockquoteDecoration: BoxDecoration(
          color: s.surfaceVariant.withValues(alpha: 0.35),
          border: Border(
            left: BorderSide(color: s.primary, width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        tableBorder: TableBorder.all(
          color: s.outlineVariant,
          width: 0.5,
        ),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 6,
        ),
        tableHead: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
        tableBody: const TextStyle(fontSize: 13, height: 1.5),
        tableColumnWidth: const IntrinsicColumnWidth(),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: s.outlineVariant, width: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: _contentCtrl,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(
          fontSize: 13.5,
          height: 1.5,
          fontFamily: 'monospace',
        ),
        decoration: InputDecoration(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
          ),
          contentPadding: const EdgeInsets.all(12),
          hintText: '在这里编辑说明……',
        ),
      ),
    );
  }
}
