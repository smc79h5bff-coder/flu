import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';

// ==================== Provider ====================

/// 行列表的当前文本。仅当前对比页会话内有效，离开对比页时由
/// DiffViewerScreen 重置为空。多次打开弹窗时共享同一份内容。
final lineListTextProvider = StateProvider<String>((ref) => '');

// ==================== 常量 ====================

const double _kFontSize = 14.0;
const double _kLineHeight = 22.0;
const double _kGutterWidth = 56.0;
const double _kEditorVPad = 8.0;

const Color _kSelectedBg = Color(0xFFBAF0FF);
const Color _kCheckColor = Color(0xFF00ABFF);
const Color _kLineNumSelected = Color(0xFF007DFF);
const Color _kLineNumNormal = Color(0xFF9E9E9E);

// ==================== 弹窗 ====================

class LineListDialog extends ConsumerStatefulWidget {
  const LineListDialog({super.key});

  @override
  ConsumerState<LineListDialog> createState() => _LineListDialogState();
}

class _LineListDialogState extends ConsumerState<LineListDialog> {
  late final TextEditingController _textCtrl;
  late final ScrollController _vertCtrl;
  final Set<int> _selectedLines = <int>{};
  int? _anchorLine;
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: ref.read(lineListTextProvider));
    _lastText = _textCtrl.text;
    _vertCtrl = ScrollController();
    _textCtrl.addListener(_onControllerChanged);
    _vertCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _textCtrl.removeListener(_onControllerChanged);
    _vertCtrl.removeListener(_onScroll);
    _textCtrl.dispose();
    _vertCtrl.dispose();
    super.dispose();
  }

  // ==================== 文本 / 选择联动 ====================

  void _onControllerChanged() {
    final newText = _textCtrl.text;
    var needRebuild = false;

    if (newText != _lastText) {
      // 文本变了：同步 provider，清理越界的选中行。
      _lastText = newText;
      ref.read(lineListTextProvider.notifier).state = newText;
      final count = _lineCount;
      final before = _selectedLines.length;
      _selectedLines.removeWhere((i) => i >= count);
      if (_selectedLines.length != before) needRebuild = true;
      if (_anchorLine != null && _anchorLine! >= count) {
        _anchorLine = null;
        needRebuild = true;
      }
      needRebuild = true;
    } else {
      // 只有光标 / 选区变了：清空行选择（互斥）。
      if (_selectedLines.isNotEmpty) {
        _selectedLines.clear();
        _anchorLine = null;
        needRebuild = true;
      }
    }

    if (needRebuild && mounted) setState(() {});
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  int get _lineCount {
    final t = _textCtrl.text;
    if (t.isEmpty) return 1;
    return '\n'.allMatches(t).length + 1;
  }

  List<String> get _lines => _textCtrl.text.split('\n');

  bool get _hasContent => _textCtrl.text.isNotEmpty;

  // ==================== 行选择 ====================

  /// 单击：切换该行的选中状态，并把锚点设为这一行。
  void _toggleLine(int i) {
    setState(() {
      if (_selectedLines.contains(i)) {
        _selectedLines.remove(i);
      } else {
        _selectedLines.add(i);
      }
      _anchorLine = i;
    });
  }

  /// 长按：从"已选中集合里离 i 最远的那一端"到 i，全选。
  /// 没有选中时，只选中这一行。
  void _rangeSelect(int i) {
    if (_selectedLines.isEmpty) {
      setState(() {
        _selectedLines.add(i);
        _anchorLine = i;
      });
      return;
    }
    final minSel = _selectedLines.reduce((a, b) => a < b ? a : b);
    final maxSel = _selectedLines.reduce((a, b) => a > b ? a : b);

    int lo;
    int hi;
    if (i > maxSel) {
      lo = minSel;
      hi = i;
    } else if (i < minSel) {
      lo = i;
      hi = maxSel;
    } else {
      // 落在已选中区间内部：什么都不做。
      return;
    }

    setState(() {
      for (var k = lo; k <= hi; k++) {
        _selectedLines.add(k);
      }
      _anchorLine = i;
    });
  }

  void _selectAll() {
    setState(() {
      _selectedLines.clear();
      for (var i = 0; i < _lineCount; i++) {
        _selectedLines.add(i);
      }
      _anchorLine = 0;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectedLines.clear();
      _anchorLine = null;
    });
  }

  // ==================== 工具条操作 ====================

  Future<void> _copySelected() async {
    if (_selectedLines.isEmpty) return;
    final sorted = _selectedLines.toList()..sort();
    final lines = _lines;
    final text = sorted
        .where((i) => i >= 0 && i < lines.length)
        .map((i) => lines[i])
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${sorted.length} 行')),
    );
  }

  void _deleteSelected() {
    if (_selectedLines.isEmpty) return;
    final remove = _selectedLines.toSet();
    final lines = _lines;
    final remaining = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (!remove.contains(i)) remaining.add(lines[i]);
    }
    _selectedLines.clear();
    _anchorLine = null;
    _textCtrl.text = remaining.join('\n');
    setState(() {});
  }

  // ==================== 应用 ====================

  void _apply(String side) {
    // 空行不参与应用（用户可能无意留了空行）。
    final entries = _lines.where((l) => l.isNotEmpty).toList();
    if (entries.isEmpty) {
      _toast('列表里没有可删除的内容');
      return;
    }

    var totalHits = 0;

    if (side == 'left' || side == 'both') {
      final cur = ref.read(preprocessedOriginalProvider);
      if (cur.isNotEmpty) {
        final result = _removeAll(cur, entries);
        totalHits += result.hits;
        if (result.hits > 0) {
          ref.read(editedOriginalProvider.notifier).state = result.text;
        }
      }
    }
    if (side == 'right' || side == 'both') {
      final cur = ref.read(preprocessedModifiedProvider);
      if (cur.isNotEmpty) {
        final result = _removeAll(cur, entries);
        totalHits += result.hits;
        if (result.hits > 0) {
          ref.read(editedModifiedProvider.notifier).state = result.text;
        }
      }
    }

    if (totalHits == 0) {
      _toast('文本里没有出现这些字符串');
      return;
    }

    // 走和工具栏按钮规则一样的通道，触发重算。
    ref.read(importRevisionProvider.notifier).state++;

    if (!mounted) return;
    Navigator.of(context).pop();
  }



  
  ({String text, int hits}) _removeAll(String text, List<String> entries) {
  if (text.isEmpty || entries.isEmpty) {
    return (text: text, hits: 0);
  }

  // 长模式优先，让更具体的匹配先命中。
  final sorted = List<String>.from(entries)
    ..sort((a, b) => b.length.compareTo(a.length));

  // 去掉空串（避免 AC 出错）。
  final cleaned = sorted.where((e) => e.isNotEmpty).toList();
  if (cleaned.isEmpty) return (text: text, hits: 0);

  final ac = AhoCorasick(
    patterns: cleaned,
    replacements: List<String>.filled(cleaned.length, ''),
    priorities: List<int>.generate(cleaned.length, (i) => i),
  );

  var hits = 0;
  ac.findAllMatches(text, (start, end, patternIndex) {
    hits++;
  });

  return (text: ac.replaceAll(text), hits: hits);
}




  
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(child: _buildEditorArea()),
            _buildToolbar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorArea() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildGutter(),
          Expanded(child: _buildTextField()),
        ],
      ),
    );
  }

  // ---------- 行号栏 ----------

  Widget _buildGutter() {
    return SizedBox(
      width: _kGutterWidth,
      child: ColoredBox(
        color: Colors.grey.shade50,
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final offset =
                  _vertCtrl.hasClients ? _vertCtrl.offset : 0.0;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var i = 0; i < _lineCount; i++)
                    _buildGutterRow(i, constraints.maxHeight, offset),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildGutterRow(int i, double maxHeight, double scrollOffset) {
    final top = _kEditorVPad + i * _kLineHeight - scrollOffset;
    if (top + _kLineHeight < 0 || top > maxHeight) {
      return const SizedBox.shrink();
    }
    final selected = _selectedLines.contains(i);
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      height: _kLineHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggleLine(i),
        onLongPress: () => _rangeSelect(i),
        child: ColoredBox(
          color: selected ? _kSelectedBg : Colors.transparent,
          child: Row(
            children: [
              const SizedBox(width: 6),
              _buildCheckbox(selected),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${i + 1}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: selected
                        ? _kLineNumSelected
                        : _kLineNumNormal,
                    fontWeight:
                        selected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCheckbox(bool selected) {
    return SizedBox(
      width: 16,
      height: 16,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? _kCheckColor : Colors.transparent,
          border: Border.all(
            color: selected ? _kCheckColor : Colors.grey.shade400,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(3),
        ),
        child: selected
            ? const Icon(Icons.check, size: 12, color: Colors.white)
            : null,
      ),
    );
  }

  // ---------- 文本编辑区 ----------

  Widget _buildTextField() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 估算内容需要的宽度，保证不折行。
        final style = const TextStyle(
          fontSize: _kFontSize,
          fontFamily: 'monospace',
        );

        double maxLineWidth = 0;
        for (final line in _lines) {
          double w = 0;
          for (final code in line.runes) {
            w += code < 128 ? _kFontSize * 0.6 : _kFontSize;
          }
          if (w > maxLineWidth) maxLineWidth = w;
        }
        final needWidth = maxLineWidth + 32;
        final width = needWidth > constraints.maxWidth
            ? needWidth
            : constraints.maxWidth;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: constraints.maxHeight,
            child: Stack(
              children: [
                ..._buildHighlightLayer(),
                TextField(
                  controller: _textCtrl,
                  scrollController: _vertCtrl,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  style: style,
                  strutStyle: const StrutStyle(
                    fontSize: _kFontSize,
                    height: _kLineHeight / _kFontSize,
                    forceStrutHeight: true,
                  ),
                  cursorColor: Colors.blue,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: _kEditorVPad,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildHighlightLayer() {
    if (_selectedLines.isEmpty) return const <Widget>[];
    final offset = _vertCtrl.hasClients ? _vertCtrl.offset : 0.0;
    final result = <Widget>[];
    for (final i in _selectedLines) {
      final top = _kEditorVPad + i * _kLineHeight - offset;
      result.add(
        Positioned(
          top: top,
          left: 0,
          right: 0,
          height: _kLineHeight,
          child: const IgnorePointer(
            child: ColoredBox(color: _kSelectedBg),
          ),
        ),
      );
    }
    return result;
  }

  // ---------- 工具条 ----------

  Widget _buildToolbar() {
    final hasContent = _hasContent;
    final hasSelection = _selectedLines.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _toolBtn(
                  icon: Icons.copy,
                  label: '复制行',
                  onTap: hasSelection ? _copySelected : null,
                ),
                _toolBtn(
                  icon: Icons.delete_outline,
                  label: '删除行',
                  onTap: hasSelection ? _deleteSelected : null,
                ),
                _toolBtn(
                  icon: Icons.select_all,
                  label: '全选',
                  onTap: hasContent ? _selectAll : null,
                ),
                _toolBtn(
                  icon: Icons.deselect,
                  label: '退出选择',
                  onTap: hasSelection ? _exitSelection : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _toolBtn(
                  icon: Icons.west,
                  label: '应用到左侧',
                  onTap: hasContent ? () => _apply('left') : null,
                ),
                _toolBtn(
                  icon: Icons.east,
                  label: '应用到右侧',
                  onTap: hasContent ? () => _apply('right') : null,
                ),
                _toolBtn(
                  icon: Icons.compare_arrows,
                  label: '应用到两侧',
                  onTap: hasContent ? () => _apply('both') : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolBtn({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: enabled ? s.onSurface : s.onSurface.withOpacity(0.3),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: enabled
                        ? s.onSurface
                        : s.onSurface.withOpacity(0.3),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
