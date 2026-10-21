import 'dart:io';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart'
    hide colorToHex, hexToColor;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/storage/persistent_notifier.dart';
import '../../import/presentation/providers/import_providers.dart';
import 'providers/grouped_color_providers.dart';
import '../../file_browser/presentation/comparison_settings_screen.dart'
    show ruleSubtitle;
import '../../preprocessing/domain/preprocessing_rule.dart';
import 'providers/diff_viewer_providers.dart';
import 'providers/toolbar_rules_provider.dart';

// ==================== 四个视图统一的竖向滚动条 ====================

/// 四个视图（差异行+上下文 / 仅差异行 / 并排 / 合并）共用的竖向滚动条。
///
/// 想调样式只改这一处：
///   - 颜色 / 透明度
///   - 粗细 thickness
///   - 圆角 radius
///   - 最小长度 minThumbLength
///   - 是否显示轨道 trackVisibility
///
/// 三个双栏视图（前三个）只给右栏画、左栏不画，
/// 整屏只显示屏幕最右侧这一根滚动条。
Widget buildViewerScrollbar({
  required Widget child,
  ScrollController? controller,
}) {
  return ScrollbarTheme(
    data: ScrollbarThemeData(
      // #D4D4DC @ 40%。深浅模式都用这个颜色。
      thumbColor: WidgetStatePropertyAll(
        const Color(0xFFD4D4DC).withValues(alpha: 0.40),
      ),
      thickness: const WidgetStatePropertyAll(16),
      radius: const Radius.circular(8),
      minThumbLength: 40,
      trackVisibility: const WidgetStatePropertyAll(false),
    ),
    child: Scrollbar(
      controller: controller,
      interactive: true,
      child: child,
    ),
  );
}

// ==================== 显示设置底部面板 ====================

class DisplaySettingsSheet extends ConsumerWidget {
  const DisplaySettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showLine = ref.watch(showLineNumbersProvider);
    final bodySize = ref.watch(bodyFontSizeProvider);
    final gutterSize = ref.watch(gutterFontSizeProvider);
    // 「相同行字号」这个设置在"差异行+上下2行"视图和"跨行块"视图里都有效，
    // 这里取一下当前视图模式，决定该项是否显示。
    final viewMode = ref.watch(viewModeProvider);

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            // ---------- 顶部抓手（固定） ----------
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ---------- 可滚动的内容区 ----------
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ========== 显示行号 ==========
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示行号'),
                      subtitle: const Text(
                        '在每行左侧显示行号',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: showLine,
                      onChanged: (v) => ref
                          .read(showLineNumbersProvider.notifier)
                          .update(v),
                    ),
                    const Divider(height: 1),

                    // ========== 正文字号 ==========
                    const SizedBox(height: 8),
                    Text(
                      '正文字号：${bodySize.toStringAsFixed(0)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove),
                          tooltip: '减 1',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            final v = (bodySize - 1).clamp(1.0, 60.0);
                            ref
                                .read(bodyFontSizeProvider.notifier)
                                .update(v);
                          },
                        ),
                        Expanded(
                          child: Slider(
                            min: 1,
                            max: 60,
                            divisions: 59,
                            value: bodySize.clamp(1.0, 60.0),
                            label: bodySize.toStringAsFixed(0),
                            onChanged: (v) =>
                                ref.read(bodyFontSizeProvider.notifier).update(v),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: '加 1',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            final v = (bodySize + 1).clamp(1.0, 60.0);
                            ref
                                .read(bodyFontSizeProvider.notifier)
                                .update(v);
                          },
                        ),
                      ],
                    ),

                    // ========== 行号字号 ==========
                    Text(
                      '行号字号：${gutterSize.toStringAsFixed(0)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove),
                          tooltip: '减 1',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            final v = (gutterSize - 1).clamp(1.0, 60.0);
                            ref
                                .read(gutterFontSizeProvider.notifier)
                                .update(v);
                          },
                        ),
                        Expanded(
                          child: Slider(
                            min: 1,
                            max: 60,
                            divisions: 59,
                            value: gutterSize.clamp(1.0, 60.0),
                            label: gutterSize.toStringAsFixed(0),
                            onChanged: (v) => ref
                                .read(gutterFontSizeProvider.notifier)
                                .update(v),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: '加 1',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            final v = (gutterSize + 1).clamp(1.0, 60.0);
                            ref
                                .read(gutterFontSizeProvider.notifier)
                                .update(v);
                          },
                        ),
                      ],
                    ),

                    // ========== 相同行字号 ==========
                    // "差异行+上下2行"视图和"跨行块"视图都会用到这个字号，
                    // 其它视图（合并 / 并排 / 仅差异行）都不读它，
                    // 因此只在这两个视图下显示，避免误导。
                    if (viewMode == ViewMode.diffOnly ||
                        viewMode == ViewMode.grouped)
                      Builder(
                        builder: (context) {
                          final contextSize =
                              ref.watch(contextFontSizeProvider);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '相同行字号：${contextSize.toStringAsFixed(0)}',
                                style:
                                    Theme.of(context).textTheme.labelMedium,
                              ),
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.remove),
                                    tooltip: '减 1',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () {
                                      final v = (contextSize - 1)
                                          .clamp(1.0, 60.0);
                                      ref
                                          .read(contextFontSizeProvider
                                              .notifier)
                                          .update(v);
                                    },
                                  ),
                                  Expanded(
                                    child: Slider(
                                      min: 1,
                                      max: 60,
                                      divisions: 59,
                                      value: contextSize.clamp(1.0, 60.0),
                                      label:
                                          contextSize.toStringAsFixed(0),
                                      onChanged: (v) => ref
                                          .read(contextFontSizeProvider
                                              .notifier)
                                          .update(v),
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.add),
                                    tooltip: '加 1',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () {
                                      final v = (contextSize + 1)
                                          .clamp(1.0, 60.0);
                                      ref
                                          .read(contextFontSizeProvider
                                              .notifier)
                                          .update(v);
                                    },
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),

                    // ========== 悬浮下翻页按钮 ==========
                    const Divider(height: 32),
                    Text(
                      '悬浮下翻页按钮',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示'),
                      subtitle: const Text(
                        '空心的正方形框，点击向下翻一屏',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: ref.watch(floatingPageDownEnabledProvider),
                      onChanged: (v) => ref
                          .read(floatingPageDownEnabledProvider.notifier)
                          .update(v),
                    ),
                    if (ref.watch(floatingPageDownEnabledProvider))
                      _FloatingButtonSettings(
                        xProvider: floatingPageDownXProvider,
                        yProvider: floatingPageDownYProvider,
                        sizeProvider: floatingPageDownSizeProvider,
                        opacityProvider: floatingPageDownOpacityProvider,
                        borderProvider: floatingPageDownBorderWidthProvider,
                        colorProvider: floatingPageDownColorProvider,
                        defaultX: 75,
                        defaultY: 58,
                        defaultSize: 110,
                        defaultOpacity: 60,
                        defaultBorder: 2,
                      ),

                    // ========== 悬浮上翻页按钮 ==========
                    const Divider(height: 32),
                    Text(
                      '悬浮上翻页按钮',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示'),
                      subtitle: const Text(
                        '空心的正方形框，点击向上翻一屏',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: ref.watch(floatingPageUpEnabledProvider),
                      onChanged: (v) => ref
                          .read(floatingPageUpEnabledProvider.notifier)
                          .update(v),
                    ),
                    if (ref.watch(floatingPageUpEnabledProvider))
                      _FloatingButtonSettings(
                        xProvider: floatingPageUpXProvider,
                        yProvider: floatingPageUpYProvider,
                        sizeProvider: floatingPageUpSizeProvider,
                        opacityProvider: floatingPageUpOpacityProvider,
                        borderProvider: floatingPageUpBorderWidthProvider,
                        colorProvider: floatingPageUpColorProvider,
                        defaultX: 75,
                        defaultY: 42,
                        defaultSize: 110,
                        defaultOpacity: 60,
                        defaultBorder: 2,
                      ),

                    // ========== 工具栏 ==========
                    const Divider(height: 32),
                    Text(
                      '工具栏',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示'),
                      subtitle: const Text(
                        '差异视图顶部的快捷操作按钮栏',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: ref.watch(toolbarVisibleProvider),
                      onChanged: (v) => ref
                          .read(toolbarVisibleProvider.notifier)
                          .update(v),
                    ),

                    // ========== 差异颜色 ==========
                    const Divider(height: 32),
                    Text(
                      '差异颜色',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    // 合并视图配色固定，12 个差异颜色都调不了，
                    // 原位置显示提示，避免用户调了没效果的困惑。
                    if (viewMode == ViewMode.merged)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '当前视图为「全文上下合并」，配色固定，不支持自定义颜色。切换到其他视图后即可调节。',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.5,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      _colorRow(context, ref, '左文件独有行 · 整行底色',
                          deleteRowBgProvider),
                      _colorRow(context, ref, '左文件独有行 · 文字颜色',
                          deleteRowFgProvider),
                      _colorRow(context, ref, '右文件独有行 · 整行底色',
                          insertRowBgProvider),
                      _colorRow(context, ref, '右文件独有行 · 文字颜色',
                          insertRowFgProvider),
                      _colorRow(context, ref, '被改行（左）· 整行底色',
                          replaceLeftBgProvider),
                      _colorRow(context, ref, '被改行（左）· 文字颜色',
                          replaceLeftFgProvider),
                      _colorRow(context, ref, '被改行（右）· 整行底色',
                          replaceRightBgProvider),
                      _colorRow(context, ref, '被改行（右）· 文字颜色',
                          replaceRightFgProvider),
                      _colorRow(context, ref, '左侧行内改动字 · 底色',
                          charDeleteBgProvider),
                      _colorRow(context, ref, '左侧行内改动字 · 文字颜色',
                          charDeleteFgProvider),
                      _colorRow(context, ref, '右侧行内改动字 · 底色',
                          charInsertBgProvider),
                      _colorRow(context, ref, '右侧行内改动字 · 文字颜色',
                          charInsertFgProvider),
                    ],

                    // ========== 跨行块视图专属颜色 ==========
                    if (ref.watch(viewModeProvider) == ViewMode.grouped) ...[
                      const Divider(height: 32),
                      Text(
                        '跨行块视图专属颜色',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      _colorRow(context, ref, '忽略空白相同的块 · 底色',
                          groupedEqualIgnoringWsBgProvider),
                      _colorRow(context, ref, '空白差异高亮（含行尾 ↵）',
                          groupedWsHighlightProvider),
                      _colorRow(context, ref, '查找命中 · 底色',
                          groupedFindYellowProvider),
                      _colorRow(context, ref, '当前查找命中 · 底色',
                          groupedFindPinkProvider),
                    ],

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _colorRow(
    BuildContext context,
    WidgetRef ref,
    String label,
    NotifierProvider<ColorPrefNotifier, Color> provider,
  ) {
    final color = ref.watch(provider);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            colorToHex(color),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => _pickColor(context, ref, label, provider),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _numInput({
    required BuildContext context,
    required String label,
    required double value,
    required String hint,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    String suffix = '',
    bool showDecimal = false,
  }) {
    final display = showDecimal && value != value.roundToDouble()
        ? value.toStringAsFixed(1)
        : value.round().toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          SizedBox(
            width: 76,
            child: TextFormField(
              key: ValueKey('$label-$display'),
              initialValue: display,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                suffixText: suffix.isEmpty ? null : suffix,
              ),
              onFieldSubmitted: (raw) {
                final n = double.tryParse(raw.trim());
                if (n == null) return;
                onChanged(n.clamp(min, max));
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hint,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickColor(
    BuildContext context,
    WidgetRef ref,
    String label,
    NotifierProvider<ColorPrefNotifier, Color> provider,
  ) async {
    var picked = ref.read(provider);
    final controller = TextEditingController(text: colorToHex(picked));

    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialogState) => AlertDialog(
          title: Text(label),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ColorPicker(
                  pickerColor: picked,
                  onColorChanged: (color) {
                    picked = color;
                    controller.text = colorToHex(color);
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
                    final parsed = hexToColor(v.trim());
                    if (parsed != null) {
                      picked = parsed;
                      setDialogState(() {});
                    }
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  '拖动上面的色板选颜色，或手动输入 #RRGGBB',
                  style: Theme.of(c).textTheme.labelSmall,
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
              onPressed: () {
                ref.read(provider.notifier).update(picked);
                Navigator.pop(c);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 按钮排序对话框 ====================

class ToolbarOrderDialog extends ConsumerStatefulWidget {
  const ToolbarOrderDialog({super.key, required this.rules});

  final List<PreprocessingRule> rules;

  @override
  ConsumerState<ToolbarOrderDialog> createState() =>
      _ToolbarOrderDialogState();
}

class _ToolbarOrderDialogState extends ConsumerState<ToolbarOrderDialog> {
  late List<PreprocessingRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = List<PreprocessingRule>.from(widget.rules);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: const Text('按钮排序'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.7,
        child: ReorderableListView.builder(
          itemCount: _rules.length,
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final item = _rules.removeAt(oldIndex);
              _rules.insert(newIndex, item);
            });
          },
          itemBuilder: (ctx, i) {
            final r = _rules[i];
            return ListTile(
              key: ValueKey<String>('order:${r.id}'),
              leading: const Icon(Icons.drag_handle),
              title: Text(r.name),
              subtitle: Text(
                ruleSubtitle(r),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '设置颜色',
                    icon: const Icon(Icons.palette),
                    onPressed: () => _openColorPanel(r),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() => _rules.removeAt(i));
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _openColorPanel(PreprocessingRule r) {
    showDialog<void>(
      context: context,
      builder: (_) => ButtonColorDialog(
        ruleId: r.id,
        ruleName: r.name,
      ),
    );
  }

  void _save() {
    ref
        .read(toolbarOrderProvider.notifier)
        .setAll(_rules.map((r) => r.id).toList());
    ref.read(toolbarRulesProvider.notifier).setAll(_rules);

    final newIds = _rules.map((r) => r.id).toSet();
    final oldIds = widget.rules.map((r) => r.id).toSet();
    final removedIds = oldIds.difference(newIds);
    for (final id in removedIds) {
      ref.read(toolbarButtonColorsProvider.notifier).remove(id);
    }

    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
  }
}

// ==================== 按钮颜色面板 ====================

class ButtonColorDialog extends ConsumerStatefulWidget {
  const ButtonColorDialog({
    super.key,
    required this.ruleId,
    required this.ruleName,
  });

  final String ruleId;
  final String ruleName;

  @override
  ConsumerState<ButtonColorDialog> createState() =>
      _ButtonColorDialogState();
}

class _ButtonColorDialogState extends ConsumerState<ButtonColorDialog> {
  @override
  Widget build(BuildContext context) {
    final all = ref.watch(toolbarButtonColorsProvider);
    final c = all[widget.ruleId] ?? const ToolbarButtonColor();
    final s = Theme.of(context).colorScheme;

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: Text(
        '${widget.ruleName} · 按钮颜色',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _colorRow(
              context: context,
              label: '背景色',
              isSet: c.bg != null,
              color: c.bg ?? Colors.white,
              onPick: (v) => _setBg(v),
            ),
            _colorRow(
              context: context,
              label: '文字色',
              isSet: c.fg != null,
              color: c.fg ?? Colors.black,
              onPick: (v) => _setFg(v),
            ),
            _colorRow(
              context: context,
              label: '边框色',
              isSet: c.border != null,
              color: c.border ?? Colors.black.withOpacity(0.5),
              onPick: (v) => _setBorder(v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  void _setBg(Color? color) {
    final all = ref.read(toolbarButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const ToolbarButtonColor();
    ref.read(toolbarButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          ToolbarButtonColor(bg: color, fg: cur.fg, border: cur.border),
        );
  }

  void _setFg(Color? color) {
    final all = ref.read(toolbarButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const ToolbarButtonColor();
    ref.read(toolbarButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          ToolbarButtonColor(bg: cur.bg, fg: color, border: cur.border),
        );
  }

  void _setBorder(Color? color) {
    final all = ref.read(toolbarButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const ToolbarButtonColor();
    ref.read(toolbarButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          ToolbarButtonColor(bg: cur.bg, fg: cur.fg, border: color),
        );
  }

  Widget _colorRow({
    required BuildContext context,
    required String label,
    required bool isSet,
    required Color color,
    required void Function(Color?) onPick,
  }) {
    final s = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isSet ? colorToHex(color) : '默认',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: isSet ? s.onSurface : s.outline,
            ),
          ),
          const SizedBox(width: 4),
          if (isSet)
            SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: '清空（回到默认）',
                icon: const Icon(Icons.close, size: 14),
                onPressed: () => onPick(null),
              ),
            ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () async {
              final picked = await pickColorDialog(context, color);
              if (picked != null) onPick(picked);
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

/// 通用取色弹窗。返回选中的颜色；用户取消返回 null。
Future<Color?> pickColorDialog(BuildContext context, Color initial) async {
  var picked = initial;
  final controller = TextEditingController(text: colorToHex(picked));

  return showDialog<Color>(
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
                  controller.text = colorToHex(color);
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
                  final parsed = hexToColor(v.trim());
                  if (parsed != null) {
                    picked = parsed;
                    setDialogState(() {});
                  }
                },
              ),
              const SizedBox(height: 8),
              Text(
                '拖动上面的色板选颜色，或手动输入 #RRGGBB',
                style: Theme.of(c).textTheme.labelSmall,
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
}

// ==================== 查找历史弹窗 ====================

class FindHistoryDialog extends ConsumerWidget {
  const FindHistoryDialog({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(findHistoryProvider);

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: const Text('查找历史'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.7,
        child: history.isEmpty
            ? const Center(child: Text('还没有查找记录'))
            : ListView.builder(
                itemCount: history.length,
                itemBuilder: (ctx, i) {
                  final q = history[i];
                  return ListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    title: Text(
                      q,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: '删除',
                      onPressed: () {
                        ref.read(findHistoryProvider.notifier).remove(q);
                      },
                    ),
                    onTap: () {
                      onPick(q);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

// ==================== 悬浮翻页按钮的设置面板（上下共用） ====================

/// 悬浮下翻页 / 上翻页按钮共用的设置面板。
///
/// 上下两个按钮的逻辑一模一样，只是 provider 不同，
/// 所以把这个面板泛化：所有 provider 从参数传入。
class _FloatingButtonSettings extends ConsumerStatefulWidget {
  const _FloatingButtonSettings({
    required this.xProvider,
    required this.yProvider,
    required this.sizeProvider,
    required this.opacityProvider,
    required this.borderProvider,
    required this.colorProvider,
    required this.defaultX,
    required this.defaultY,
    required this.defaultSize,
    required this.defaultOpacity,
    required this.defaultBorder,
  });

  final NotifierProvider<DoublePrefNotifier, double> xProvider;
  final NotifierProvider<DoublePrefNotifier, double> yProvider;
  final NotifierProvider<DoublePrefNotifier, double> sizeProvider;
  final NotifierProvider<DoublePrefNotifier, double> opacityProvider;
  final NotifierProvider<DoublePrefNotifier, double> borderProvider;
  final NotifierProvider<ColorPrefNotifier, Color> colorProvider;

  final double defaultX;
  final double defaultY;
  final double defaultSize;
  final double defaultOpacity;
  final double defaultBorder;

  @override
  ConsumerState<_FloatingButtonSettings> createState() =>
      _FloatingButtonSettingsState();
}

class _FloatingButtonSettingsState
    extends ConsumerState<_FloatingButtonSettings> {
  late final TextEditingController _xCtrl;
  late final TextEditingController _yCtrl;
  late final TextEditingController _sizeCtrl;
  late final TextEditingController _opacityCtrl;
  late final TextEditingController _borderCtrl;

  @override
  void initState() {
    super.initState();
    _xCtrl = TextEditingController(
        text: ref.read(widget.xProvider).round().toString());
    _yCtrl = TextEditingController(
        text: ref.read(widget.yProvider).round().toString());
    _sizeCtrl = TextEditingController(
        text: ref.read(widget.sizeProvider).round().toString());
    _opacityCtrl = TextEditingController(
        text: ref.read(widget.opacityProvider).round().toString());
    _borderCtrl = TextEditingController(
        text: ref.read(widget.borderProvider).toString());
  }

  @override
  void dispose() {
    _xCtrl.dispose();
    _yCtrl.dispose();
    _sizeCtrl.dispose();
    _opacityCtrl.dispose();
    _borderCtrl.dispose();
    super.dispose();
  }

  void _apply() {
    final x = double.tryParse(_xCtrl.text.trim());
    if (x != null) {
      ref.read(widget.xProvider.notifier).update(x.clamp(-10, 110));
    }
    final y = double.tryParse(_yCtrl.text.trim());
    if (y != null) {
      ref.read(widget.yProvider.notifier).update(y.clamp(-10, 110));
    }
    final size = double.tryParse(_sizeCtrl.text.trim());
    if (size != null) {
      ref.read(widget.sizeProvider.notifier).update(size.clamp(5, 300));
    }
    final opacity = double.tryParse(_opacityCtrl.text.trim());
    if (opacity != null) {
      ref
          .read(widget.opacityProvider.notifier)
          .update(opacity.clamp(0, 100));
    }
    final border = double.tryParse(_borderCtrl.text.trim());
    if (border != null) {
      ref
          .read(widget.borderProvider.notifier)
          .update(border.clamp(0.1, 20));
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已应用'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _reset() {
    setState(() {
      _xCtrl.text = widget.defaultX.round().toString();
      _yCtrl.text = widget.defaultY.round().toString();
      _sizeCtrl.text = widget.defaultSize.round().toString();
      _opacityCtrl.text = widget.defaultOpacity.round().toString();
      _borderCtrl.text = widget.defaultBorder.toString();
    });
  }

  Widget _input({
    required String label,
    required TextEditingController ctrl,
    required String hint,
    String suffix = '',
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          SizedBox(
            width: 76,
            child: TextField(
              controller: ctrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                suffixText: suffix.isEmpty ? null : suffix,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hint,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = ref.watch(widget.colorProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        _input(
          label: 'X 坐标',
          ctrl: _xCtrl,
          hint: '-10 ~ 110，距屏幕左边百分比',
          suffix: '%',
        ),
        _input(
          label: 'Y 坐标',
          ctrl: _yCtrl,
          hint: '-10 ~ 110，距屏幕顶部百分比',
          suffix: '%',
        ),
        _input(
          label: '大小',
          ctrl: _sizeCtrl,
          hint: '5 ~ 300 像素（建议 40 以上）',
          suffix: 'px',
        ),
        _input(
          label: '透明度',
          ctrl: _opacityCtrl,
          hint: '0 ~ 100%（0 = 完全透明，仍可点击）',
          suffix: '%',
        ),
        _input(
          label: '边框粗细',
          ctrl: _borderCtrl,
          hint: '0.1 ~ 20 像素',
          suffix: 'px',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              const SizedBox(
                width: 80,
                child: Text('边框颜色',
                    style: TextStyle(fontSize: 13)),
              ),
              Text(
                colorToHex(color),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () async {
                  final picked = await pickColorDialog(context, color);
                  if (picked != null) {
                    ref
                        .read(widget.colorProvider.notifier)
                        .update(picked);
                  }
                },
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _reset,
                child: const Text('恢复默认值'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.check, size: 18),
                label: const Text('应用'),
                onPressed: _apply,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ==================== 跳转指示器（公共版） ====================

enum JumpDirection { up, down }

/// 跳转遮罩用的指示器：呼吸环 + 环上旋转点 + 中心方向箭头。
class JumpIndicator extends StatefulWidget {
  const JumpIndicator({
    super.key,
    required this.direction,
    this.size = 64,
  });

  final JumpDirection direction;
  final double size;

  @override
  State<JumpIndicator> createState() => _JumpIndicatorState();
}

class _JumpIndicatorState extends State<JumpIndicator>
    with TickerProviderStateMixin {
  late final AnimationController _rotation;
  late final AnimationController _breath;

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _rotation.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_rotation, _breath]),
        builder: (_, __) => Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: Size.square(widget.size),
              painter: JumpRingPainter(
                rotation: _rotation.value,
                breath: _breath.value,
                color: color,
              ),
            ),
            Icon(
              widget.direction == JumpDirection.up
                  ? Icons.keyboard_double_arrow_up
                  : Icons.keyboard_double_arrow_down,
              size: widget.size * 0.38,
              color: color.withValues(alpha: 0.85),
            ),
          ],
        ),
      ),
    );
  }
}

class JumpRingPainter extends CustomPainter {
  JumpRingPainter({
    required this.rotation,
    required this.breath,
    required this.color,
  });

  final double rotation;
  final double breath;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 4;

    // 底环（呼吸：透明度 12% ↔ 20%）
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color.withValues(alpha: 0.12 + 0.08 * breath);
    canvas.drawCircle(center, radius, bg);

    // 旋转的点
    final angle = rotation * 2 * math.pi;
    final dot = Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(dot, 4, dotPaint);

    // 点后面拖的短弧，让它看起来"在跑"
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.5);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      angle - 0.6,
      0.6,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(JumpRingPainter old) =>
      old.rotation != rotation ||
      old.breath != breath ||
      old.color != color;
}

// ==================== 视图顶部的文件名栏（四个视图共用） ====================
//
// 色条按左右区分：左红右绿。
// 背景中性灰，深浅色各有档，不吃主题色。
// 长按 / 点右上圆圈叹号 → 弹文件信息（路径、大小、修改时间、编码）。
// onDelete 为 null 时不显示"删除此文件"按钮，其余功能正常。

class ViewerPaneHeader extends ConsumerWidget {
  const ViewerPaneHeader({
    super.key,
    required this.fileName,
    required this.isLeft,
    this.onDelete,
    this.fontSize = 12,
    this.iconSize = 14,
    this.height = 34,
  });

  final String fileName;
  final bool isLeft;
  final VoidCallback? onDelete;
  final double fontSize;
  final double iconSize;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final bg = cs.surfaceContainerLow;
    final fg = isDark ? const Color(0xFFE0E0E0) : const Color(0xFF333333);
    final bar = isLeft
        ? (isDark ? const Color(0xFFE57373) : const Color(0xFFD9534F)) // 红
        : (isDark ? const Color(0xFF81C784) : const Color(0xFF4CAF50)); // 绿

    return GestureDetector(
      onLongPress: () => _showInfo(context, ref),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: bg,
          border: Border(
            bottom: BorderSide(
              color: cs.outlineVariant,
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: bar),
            const SizedBox(width: 8),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showInfo(context, ref),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  Icons.error_outline,
                  size: iconSize,
                  color: fg.withValues(alpha: 0.7),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Future<void> _showInfo(BuildContext context, WidgetRef ref) async {
    final path = ref.read(
        isLeft ? originalFilePathProvider : modifiedFilePathProvider);
    final encoding = ref.read(
        isLeft ? originalEncodingProvider : modifiedEncodingProvider);

    String sizeStr = '—';
    String timeStr = '—';
    if (path != null) {
      try {
        final st = await File(path).stat();
        final s = st.size;
        if (s < 1024) {
          sizeStr = '$s B';
        } else if (s < 1024 * 1024) {
          sizeStr = '${(s / 1024).toStringAsFixed(1)} KB';
        } else if (s < 1024 * 1024 * 1024) {
          sizeStr = '${(s / 1024 / 1024).toStringAsFixed(1)} MB';
        } else {
          sizeStr = '${(s / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
        }
        final t = st.modified;
        String two(int n) => n < 10 ? '0$n' : '$n';
        timeStr = '${t.year}-${two(t.month)}-${two(t.day)} '
            '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
      } catch (_) {}
    }

    if (!context.mounted) return;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 2),
              SelectableText(value),
            ],
          ),
        );

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: Text(
          fileName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row('路径', path ?? '（没有路径，来自剪贴板或粘贴）'),
              row('大小', sizeStr),
              row('修改时间', timeStr),
              row('编码', encoding),
            ],
          ),
        ),
        actions: [
          if (onDelete != null)
            TextButton(
              onPressed: () {
                Navigator.pop(c);
                onDelete!();
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('删除此文件'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
