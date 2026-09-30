import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart'
    hide colorToHex, hexToColor;
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

final contextSize = ref.watch(contextFontSizeProvider);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
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
        ref.read(bodyFontSizeProvider.notifier).update(v);
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
        ref.read(bodyFontSizeProvider.notifier).update(v);
      },
    ),
  ],
),
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
        ref.read(gutterFontSizeProvider.notifier).update(v);
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
        ref.read(gutterFontSizeProvider.notifier).update(v);
      },
    ),
  ],
),
Text(
  '差异上下文视图的相同行的字号：${contextSize.toStringAsFixed(0)}',
  style: Theme.of(context).textTheme.labelMedium,
),
Row(
  children: [
    IconButton(
      icon: const Icon(Icons.remove),
      tooltip: '减 1',
      visualDensity: VisualDensity.compact,
      onPressed: () {
        final v = (contextSize - 1).clamp(1.0, 60.0);
        ref.read(contextFontSizeProvider.notifier).update(v);
      },
    ),
    Expanded(
      child: Slider(
        min: 1,
        max: 60,
        divisions: 59,
        value: contextSize.clamp(1.0, 60.0),
        label: contextSize.toStringAsFixed(0),
        onChanged: (v) => ref
            .read(contextFontSizeProvider.notifier)
            .update(v),
      ),
    ),
    IconButton(
      icon: const Icon(Icons.add),
      tooltip: '加 1',
      visualDensity: VisualDensity.compact,
      onPressed: () {
        final v = (contextSize + 1).clamp(1.0, 60.0);
        ref.read(contextFontSizeProvider.notifier).update(v);
      },
    ),
  ],
),
                    const Divider(height: 32),
                    Text(
                      '差异颜色',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
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
                    const SizedBox(height: 24),
                  
                
              
            ],
          ),
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
