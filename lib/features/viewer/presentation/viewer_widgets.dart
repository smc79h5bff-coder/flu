import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart'
    hide colorToHex, hexToColor;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/storage/persistent_notifier.dart';
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

                    // ========== 工具栏行数 ==========
                    const Divider(height: 32),
                    Text(
                      '工具栏行数',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Builder(
                      builder: (context) {
                        final rowCount = ref.watch(toolbarRowCountProvider);
                        return Row(
                          children: [
                            const Text(
                              '按钮栏行数：',
                              style: TextStyle(fontSize: 13),
                            ),
                            const Spacer(),
                            SegmentedButton<int>(
                              showSelectedIcon: false,
                              style: const ButtonStyle(
                                visualDensity: VisualDensity.compact,
                              ),
                              segments: const [
                                ButtonSegment(value: 1, label: Text('1')),
                                ButtonSegment(value: 2, label: Text('2')),
                                ButtonSegment(value: 3, label: Text('3')),
                              ],
                              selected: {rowCount.clamp(1, 3)},
                              onSelectionChanged: (sel) => ref
                                  .read(toolbarRowCountProvider.notifier)
                                  .setCount(sel.first),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '快捷按钮栏分几行显示，每行行尾的 + 会在该行新建按钮',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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

                    // ========== 差异颜色 ==========
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

/// 排序对话框扁平列表里的一个条目：组标题或按钮。
class _OrderEntry {
  const _OrderEntry.header(this.row) : rule = null;
  const _OrderEntry.item(PreprocessingRule this.rule) : row = null;

  /// 组标题的行号（仅标题条目有值）。
  final int? row;

  /// 按钮条目（仅按钮条目有值）。
  final PreprocessingRule? rule;

  bool get isHeader => rule == null;
}

class ToolbarOrderDialog extends ConsumerStatefulWidget {
  const ToolbarOrderDialog({super.key, required this.rules});

  final List<PreprocessingRule> rules;

  @override
  ConsumerState<ToolbarOrderDialog> createState() =>
      _ToolbarOrderDialogState();
}

class _ToolbarOrderDialogState extends ConsumerState<ToolbarOrderDialog> {
  late List<PreprocessingRule> _rules;

  /// 本地工作副本：按钮 id → 行号（1~3）。保存时统一写回。
  late Map<String, int> _rows;

  // ---- 界面状态（都不持久化）----
  bool _compact = false; // 紧凑模式
  bool _multiSelect = false; // 多选模式
  bool _pickingTarget = false; // 「选择目标按钮」进行中
  final Set<String> _selectedIds = <String>{};
  final Set<int> _collapsed = <int>{}; // 多行模式下折叠的行号
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _rules = List<PreprocessingRule>.from(widget.rules);
    final savedRows = ref.read(toolbarButtonRowsProvider);
    _rows = {
      for (final r in widget.rules) r.id: savedRows[r.id] ?? 1,
    };
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ==================== 小工具 ====================

  /// 是否多行模式（行数设置 >= 2）。
  bool _isMultiRow() => ref.read(toolbarRowCountProvider) >= 2;

  bool _matchesSearch(PreprocessingRule r) {
    if (_searchQuery.isEmpty) return true;
    return r.name.toLowerCase().contains(_searchQuery.toLowerCase());
  }

  bool _canDrag() =>
      !_multiSelect && !_pickingTarget && _searchQuery.isEmpty;

  int _rowOf(String id) => _rows[id] ?? 1;

  int _countOfRow(int row) => _rules.where((r) => _rowOf(r.id) == row).length;

  /// 选中态底色：浅黄绿（dark 下暗黄绿）。
  Color get _selBg => Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF2B3320)
      : const Color(0xFFF1FBDE);

  /// 选中态边框/粗条：粉色（dark 下亮粉）。
  Color get _selLine => Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFFF6FAE)
      : const Color(0xFFFF3D8F);

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
      );
  }

  // ==================== 整体结构 ====================

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: _buildTitle(),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            if (_pickingTarget) _buildTargetBanner(),
            if (_compact) _buildSearchBox(),
            Expanded(child: _buildList()),
            if (_multiSelect) ...[
              const Divider(height: 1),
              _buildMultiSelectBar(),
            ],
          ],
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

  /// 顶栏：普通 = 标题 + 紧凑切换 + 多选；多选 = 已选 N 项 + 完成。
  Widget _buildTitle() {
    if (_multiSelect) {
      return Row(
        children: [
          Expanded(child: Text('已选 ${_selectedIds.length} 项')),
          TextButton(
            onPressed: () {
              setState(() {
                _multiSelect = false;
                _pickingTarget = false;
                _selectedIds.clear();
              });
            },
            child: const Text('完成'),
          ),
        ],
      );
    }
    return Row(
      children: [
        const Expanded(child: Text('按钮排序')),
        IconButton(
          tooltip: _compact ? '舒适模式' : '紧凑模式',
          icon: Icon(_compact ? Icons.view_day : Icons.view_headline),
          onPressed: () => setState(() {
            _compact = !_compact;
            if (!_compact) {
              // 搜索框只在紧凑模式显示，退出时一并清掉过滤条件，
              // 否则过滤会残留且无法关闭。
              _searchQuery = '';
              _searchCtrl.clear();
            }
          }),
        ),
        TextButton(
          onPressed: () => setState(() => _multiSelect = true),
          child: const Text('多选'),
        ),
      ],
    );
  }

  /// 「选择目标按钮」进行中的提示条。
  Widget _buildTargetBanner() {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
      color: s.tertiaryContainer,
      child: Row(
        children: [
          Expanded(
            child: Text(
              '请点一个目标按钮（移动已选的 ${_selectedIds.length} 个）',
              style: TextStyle(fontSize: 12, color: s.onTertiaryContainer),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _pickingTarget = false),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// 紧凑模式的顶部搜索框（按名称过滤）。
  Widget _buildSearchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: TextField(
        controller: _searchCtrl,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索按钮名称',
          prefixIcon: const Icon(Icons.search, size: 18),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onChanged: (v) => setState(() => _searchQuery = v.trim()),
      ),
    );
  }

  /// 列表主体：多行模式按行分组，单行模式和旧版一致。
  Widget _buildList() {
    final rowCount = ref.watch(toolbarRowCountProvider);
    if (rowCount >= 2) return _buildGroupedList(rowCount);
    return _buildSingleList();
  }

  // ==================== 单行模式（与旧版一致） ====================

  Widget _buildSingleList() {
    final items = _rules.where(_matchesSearch).toList();
    // 非紧凑、非多选时保持旧版的默认拖拽方式（长按整行拖动）。
    final useDefaultHandles = !_compact && !_multiSelect;
    return ReorderableListView.builder(
      buildDefaultDragHandles: useDefaultHandles,
      itemCount: items.length,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          // 搜索过滤时已禁拖，不会走到这里；保险起见只在未过滤时移动。
          if (items.length != _rules.length) return;
          if (oldIndex < 0 || oldIndex >= _rules.length) return;
          final item = _rules.removeAt(oldIndex);
          _rules.insert(newIndex.clamp(0, _rules.length), item);
        });
      },
      itemBuilder: (ctx, i) {
        final r = items[i];
        if (_compact) {
          return _buildCompactItem(r: r, index: i, canDrag: _canDrag());
        }
        return _buildComfortItem(
          r: r,
          index: i,
          canDrag: _canDrag(),
          useDefaultHandles: useDefaultHandles,
        );
      },
    );
  }

  // ==================== 多行模式（按行分组） ====================

  Widget _buildGroupedList(int rowCount) {
    final entries = _buildEntries();
    return ReorderableListView(
      buildDefaultDragHandles: false,
      onReorder: _onReorderMultiRow,
      children: [
        for (var i = 0; i < entries.length; i++)
          entries[i].isHeader
              ? _groupHeaderTile(
                  key: ValueKey<String>('hdr:${entries[i].row}'),
                  row: entries[i].row!,
                  hidden: entries[i].row! > rowCount,
                )
              : _buildGroupedItem(entries[i].rule!, i),
      ],
    );
  }

  /// 扁平条目：行 1~3 的组标题 + 组内按钮交错；折叠的组只留标题。
  List<_OrderEntry> _buildEntries() {
    final entries = <_OrderEntry>[];
    for (var row = 1; row <= 3; row++) {
      entries.add(_OrderEntry.header(row));
      if (_collapsed.contains(row)) continue;
      for (final r in _rules) {
        if (_rowOf(r.id) != row) continue;
        if (!_matchesSearch(r)) continue;
        entries.add(_OrderEntry.item(r));
      }
    }
    return entries;
  }

  /// 组标题：可点击折叠/展开，本身不带拖拽手柄。
  Widget _groupHeaderTile({
    required Key key,
    required int row,
    required bool hidden,
  }) {
    final s = Theme.of(context).colorScheme;
    const names = <String>['第一行', '第二行', '第三行'];
    final collapsed = _collapsed.contains(row);
    final count = _countOfRow(row);
    return InkWell(
      key: key,
      onTap: () {
        setState(() {
          if (collapsed) {
            _collapsed.remove(row);
          } else {
            _collapsed.add(row);
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        color: s.surfaceVariant.withOpacity(0.45),
        child: Row(
          children: [
            Icon(
              collapsed ? Icons.expand_more : Icons.expand_less,
              size: 16,
              color: s.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              names[row - 1],
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            if (!_compact) ...[
              const SizedBox(width: 6),
              Text(
                '· $count 个',
                style: TextStyle(fontSize: 11, color: s.onSurfaceVariant),
              ),
            ],
            if (hidden) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: s.surfaceVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '未显示',
                  style: TextStyle(fontSize: 10, color: s.onSurfaceVariant),
                ),
              ),
            ],
            if (_compact) ...[
              const Spacer(),
              Text(
                '$count 个',
                style: TextStyle(fontSize: 11, color: s.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGroupedItem(PreprocessingRule r, int index) {
    if (_compact) {
      return _buildCompactItem(r: r, index: index, canDrag: _canDrag());
    }
    return _buildComfortItem(
      r: r,
      index: index,
      canDrag: _canDrag(),
      useDefaultHandles: false,
    );
  }

  /// 多行模式的跨行拖拽：落点在哪一组，就把按钮的行号改成那一组。
  void _onReorderMultiRow(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final entries = _buildEntries();
      if (oldIndex < 0 || oldIndex >= entries.length) return;
      final dragged = entries[oldIndex];
      if (dragged.isHeader) return; // 标题没有手柄，正常不会走到这里
      final draggedRule = dragged.rule!;

      // 拖走被拖项后剩下的条目（与 onReorder 的落点索引对齐）。
      final rest = List<_OrderEntry>.from(entries)..removeAt(oldIndex);

      // 落点所在行：看落点前一个条目（按钮按它的行号，组标题按标题行号）。
      int targetRow;
      if (newIndex <= 0 || rest.isEmpty) {
        targetRow = 1;
      } else {
        final i = (newIndex - 1).clamp(0, rest.length - 1);
        final before = rest[i];
        targetRow = before.isHeader ? before.row! : _rowOf(before.rule!.id);
      }

      // 目标行内的插入位置 = 落点之前目标行的按钮数。
      var offset = 0;
      final limit = newIndex.clamp(0, rest.length);
      for (var i = 0; i < limit; i++) {
        final e = rest[i];
        if (!e.isHeader && _rowOf(e.rule!.id) == targetRow) offset++;
      }

      // 重建每行列表，把被拖项插到目标行对应位置。
      final moving =
          _rules.firstWhere((r) => r.id == draggedRule.id);
      final rowLists = List.generate(3, (_) => <PreprocessingRule>[]);
      for (final r in _rules) {
        if (r.id == draggedRule.id) continue;
        rowLists[_rowOf(r.id) - 1].add(r);
      }
      rowLists[targetRow - 1].insert(
        offset.clamp(0, rowLists[targetRow - 1].length),
        moving,
      );
      _rows[draggedRule.id] = targetRow;
      _rules = [...rowLists[0], ...rowLists[1], ...rowLists[2]];
    });
  }

  // ==================== 两种条目样式 ====================

  /// 舒适模式条目：ListTile（名称 + 副标题 + 调色板 + 删除）。
  /// [useDefaultHandles] 为 true 时完全保持旧版写法。
  Widget _buildComfortItem({
    required PreprocessingRule r,
    required int index,
    required bool canDrag,
    required bool useDefaultHandles,
  }) {
    final selected = _selectedIds.contains(r.id);
    final tapEnabled = _multiSelect || _pickingTarget;
    final itemKey = ValueKey<String>('order:${r.id}');
    final tile = ListTile(
      leading: _multiSelect
          ? Icon(
              selected ? Icons.check_box : Icons.check_box_outline_blank,
              color: selected
                  ? _selLine
                  : Theme.of(context).colorScheme.outline,
            )
          : (useDefaultHandles
              ? const Icon(Icons.drag_handle)
              : ReorderableDragStartListener(
                  index: index,
                  enabled: canDrag,
                  child: const Icon(Icons.drag_handle),
                )),
      title: Text(r.name),
      subtitle: Text(
        ruleSubtitle(r),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      onTap: tapEnabled ? () => _onRowTap(r) : null,
      trailing: _multiSelect
          ? null
          : Row(
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
                  onPressed: () => setState(() => _rules.remove(r)),
                ),
              ],
            ),
    );
    if (_multiSelect && selected) {
      return _selectionWrap(key: itemKey, child: tile);
    }
    return KeyedSubtree(key: itemKey, child: tile);
  }

  /// 紧凑模式条目：单行（手柄 + 名称 + 调色板 + 删除），无副标题。
  Widget _buildCompactItem({
    required PreprocessingRule r,
    required int index,
    required bool canDrag,
  }) {
    final s = Theme.of(context).colorScheme;
    final selected = _selectedIds.contains(r.id);
    final tapEnabled = _multiSelect || _pickingTarget;
    final itemKey = ValueKey<String>('order:${r.id}');
    final content = Container(
      height: 36,
      padding: const EdgeInsets.only(right: 2),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            enabled: canDrag,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(
                Icons.drag_handle,
                size: 18,
                color: s.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              r.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (_multiSelect)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Icon(
                selected ? Icons.check_box : Icons.check_box_outline_blank,
                size: 18,
                color: selected ? _selLine : s.outline,
              ),
            )
          else ...[
            IconButton(
              tooltip: '设置颜色',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: const Icon(Icons.palette),
              onPressed: () => _openColorPanel(r),
            ),
            IconButton(
              tooltip: '删除',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(() => _rules.remove(r)),
            ),
          ],
        ],
      ),
    );
    final row = GestureDetector(
      onTap: tapEnabled ? () => _onRowTap(r) : null,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
    if (_multiSelect && selected) {
      return _selectionWrap(key: itemKey, child: row);
    }
    return KeyedSubtree(key: itemKey, child: row);
  }

  /// 多选选中样式：浅黄绿底 + 粉色边框 + 左侧 4px 粉色粗条。
  Widget _selectionWrap({required Key key, required Widget child}) {
    return Container(
      key: key,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _selBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _selLine),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 4, color: _selLine),
          Expanded(child: child),
        ],
      ),
    );
  }

  // ==================== 点击行为 ====================

  void _onRowTap(PreprocessingRule r) {
    if (_pickingTarget) {
      if (_selectedIds.contains(r.id)) {
        _toast('目标不能是已选中的按钮');
        return;
      }
      _showBeforeAfterChoice(r);
      return;
    }
    if (_multiSelect) {
      setState(() {
        if (_selectedIds.contains(r.id)) {
          _selectedIds.remove(r.id);
        } else {
          _selectedIds.add(r.id);
        }
      });
    }
  }

  /// 点了目标按钮后，问放在它前面还是后面。
  Future<void> _showBeforeAfterChoice(PreprocessingRule target) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '把 ${_selectedIds.length} 个按钮移到「${target.name}」的：',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.vertical_align_top),
              title: const Text('放在它前面'),
              onTap: () => Navigator.pop(c, 'before'),
            ),
            ListTile(
              leading: const Icon(Icons.vertical_align_bottom),
              title: const Text('放在它后面'),
              onTap: () => Navigator.pop(c, 'after'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(c),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice != 'before' && choice != 'after') return;
    setState(() {
      _moveSelectedAround(target.id, before: choice == 'before');
      _pickingTarget = false;
    });
  }

  // ==================== 多选操作 ====================

  /// 底部固定操作条：全选 ▾ / 删除 / 移到… / 取消。
  Widget _buildMultiSelectBar() {
    final s = Theme.of(context).colorScheme;
    final hasSel = _selectedIds.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
      child: Row(
        children: [
          PopupMenuButton<String>(
            tooltip: '全选',
            onSelected: _selectAllMenu,
            itemBuilder: (c) => [
              if (_isMultiRow()) ...[
                PopupMenuItem(
                  value: 'row1',
                  child: Text('全选第一行（${_countOfRow(1)}）'),
                ),
                PopupMenuItem(
                  value: 'row2',
                  child: Text('全选第二行（${_countOfRow(2)}）'),
                ),
                PopupMenuItem(
                  value: 'row3',
                  child: Text('全选第三行（${_countOfRow(3)}）'),
                ),
              ],
              PopupMenuItem(
                value: 'all',
                child: Text('全选所有行（${_rules.length}）'),
              ),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('全选 ▾', style: TextStyle(fontSize: 13)),
            ),
          ),
          const Spacer(),
          OutlinedButton(
            onPressed: hasSel ? _confirmDeleteSelected : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red.shade700,
              side: BorderSide(color: Colors.red.shade700),
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('删除'),
          ),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: '移到…',
            enabled: hasSel,
            onSelected: _moveMenuSelected,
            padding: EdgeInsets.zero,
            itemBuilder: (c) => _buildMoveMenuItems(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: hasSel ? s.primary : s.onSurface.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '移到…',
                style: TextStyle(
                  fontSize: 13,
                  color: hasSel ? s.onPrimary : s.onSurface.withOpacity(0.38),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: () {
              setState(() {
                _multiSelect = false;
                _pickingTarget = false;
                _selectedIds.clear();
              });
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// 全选菜单（带各行的数量）。
  void _selectAllMenu(String value) {
    setState(() {
      if (value == 'all') {
        for (final r in _rules) {
          _selectedIds.add(r.id);
        }
      } else if (value == 'row1' || value == 'row2' || value == 'row3') {
        final row = int.parse(value.substring(3));
        for (final r in _rules) {
          if (_rowOf(r.id) == row) _selectedIds.add(r.id);
        }
      }
    });
  }

  /// 「移到…」菜单：移到第 2/3 行末尾（该行显示时才有）+ 选择目标按钮。
  List<PopupMenuEntry<String>> _buildMoveMenuItems() {
    final rowCount = ref.read(toolbarRowCountProvider);
    return [
      if (rowCount >= 2)
        const PopupMenuItem(value: 'row2', child: Text('移到第二行末尾')),
      if (rowCount >= 3)
        const PopupMenuItem(value: 'row3', child: Text('移到第三行末尾')),
      const PopupMenuItem(value: 'pick', child: Text('选择目标按钮…')),
    ];
  }

  void _moveMenuSelected(String value) {
    if (_selectedIds.isEmpty) return;
    if (value == 'row2') {
      setState(() => _moveSelectedToRowEnd(2));
    } else if (value == 'row3') {
      setState(() => _moveSelectedToRowEnd(3));
    } else if (value == 'pick') {
      setState(() => _pickingTarget = true);
    }
  }

  /// 把选中的按钮移到第 [row] 行末尾（保持它们之间的相对顺序）。
  void _moveSelectedToRowEnd(int row) {
    final moving =
        _rules.where((r) => _selectedIds.contains(r.id)).toList();
    if (moving.isEmpty) return;
    final others =
        _rules.where((r) => !_selectedIds.contains(r.id)).toList();
    for (final m in moving) {
      _rows[m.id] = row;
    }
    final result = <PreprocessingRule>[];
    for (final r in others) {
      if (_rowOf(r.id) < row) result.add(r);
    }
    for (final r in others) {
      if (_rowOf(r.id) == row) result.add(r);
    }
    result.addAll(moving);
    for (final r in others) {
      if (_rowOf(r.id) > row) result.add(r);
    }
    _rules = result;
  }

  /// 把选中的按钮插到目标按钮前面/后面，行号改成目标按钮的行。
  void _moveSelectedAround(String targetId, {required bool before}) {
    final moving =
        _rules.where((r) => _selectedIds.contains(r.id)).toList();
    if (moving.isEmpty) return;
    final targetRow = _rowOf(targetId);
    for (final m in moving) {
      _rows[m.id] = targetRow;
    }
    final others =
        _rules.where((r) => !_selectedIds.contains(r.id)).toList();
    final result = <PreprocessingRule>[];
    for (final r in others) {
      if (before && r.id == targetId) result.addAll(moving);
      result.add(r);
      if (!before && r.id == targetId) result.addAll(moving);
    }
    _rules = result;
  }

  /// 删除选中的按钮，先弹确认框（逐条列出名字）。
  Future<void> _confirmDeleteSelected() async {
    final targets =
        _rules.where((r) => _selectedIds.contains(r.id)).toList();
    if (targets.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除这 ${targets.length} 个按钮？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final r in targets)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF3D8F),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          r.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              Text(
                '删除后无法恢复。',
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _rules.removeWhere((r) => _selectedIds.contains(r.id));
      _selectedIds.clear();
    });
  }

  // ==================== 保存 ====================

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
    // 写回每行归属（行号 1~3）。
    ref.read(toolbarButtonRowsProvider.notifier).setMany(_rows);

    final newIds = _rules.map((r) => r.id).toSet();
    final oldIds = widget.rules.map((r) => r.id).toSet();
    final removedIds = oldIds.difference(newIds);
    for (final id in removedIds) {
      ref.read(toolbarButtonColorsProvider.notifier).remove(id);
      ref.read(toolbarButtonRowsProvider.notifier).remove(id);
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
