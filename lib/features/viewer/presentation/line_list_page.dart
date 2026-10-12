import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/application/aho_corasick.dart';

// ==================== Provider ====================

final lineListTextProvider = StateProvider<String>((ref) => '');
final lineListMinLenProvider = StateProvider<int>((ref) => 7);

// ==================== 常量 ====================

const double _kFontSize = 14.0;
const double _kLineHeight = 22.0;
const double _kEditorVPad = 9.0;

const double _kBlockSize = 36.0;
const double _kBlockOffset = 36.0;
const double _kBlockAreaWidth = 76.0;

const double _kGutterWidth = 45.0;

const Color _kSelectedBg = Color(0xFFDCFFFF);
const Color _kCheckColor = Color(0xFF00ABFF);
const Color _kLineNumSelected = Color(0xFF007DFF);
const Color _kLineNumNormal = Color(0xFF9E9E9E);
const Color _kBlockBgNormal = Color(0xFFEDEDED);
const Color _kBlockBorderNormal = Color(0xFFBDBDBD);
const Color _kBlockTextNormal = Color(0xFF424242);
const Color _kConnectorColor = Color(0xFFBDBDBD);

// ==================== 页面 ====================

class LineListPage extends ConsumerStatefulWidget {
  const LineListPage({super.key});

  @override
  ConsumerState<LineListPage> createState() => _LineListPageState();
}

class _LineListPageState extends ConsumerState<LineListPage> {
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

  void _onControllerChanged() {
    final newText = _textCtrl.text;
    var needRebuild = false;

    if (newText != _lastText) {
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

  void _selectLongLines(int minLen) {
    final lines = _lines;
    setState(() {
      _selectedLines.clear();
      _anchorLine = null;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].runes.length > minLen) {
          _selectedLines.add(i);
        }
      }
    });
  }

  Future<void> _promptMinLen() async {
    final ctrl = TextEditingController(
      text: ref.read(lineListMinLenProvider).toString(),
    );
    final result = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(24),
        title: const Text('字数阈值', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '选大于多少字的行',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) {
            final n = int.tryParse(v.trim());
            if (n != null && n >= 0) Navigator.pop(c, n);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n != null && n >= 0) Navigator.pop(c, n);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    ref.read(lineListMinLenProvider.notifier).state = result;
    _selectLongLines(result);
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

    ref.read(importRevisionProvider.notifier).state++;

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  ({String text, int hits}) _removeAll(String text, List<String> entries) {
    if (text.isEmpty || entries.isEmpty) {
      return (text: text, hits: 0);
    }

    final cleaned = entries.where((e) => e.isNotEmpty).toList();
    if (cleaned.isEmpty) return (text: text, hits: 0);

    cleaned.sort((a, b) => b.length.compareTo(a.length));

    final ac = AhoCorasick(
      patterns: cleaned,
      replacements: List<String>.filled(cleaned.length, ''),
      priorities: List<int>.generate(cleaned.length, (i) => i),
    );

    var hits = 0;
    ac.findAllMatches(text, (_, __, ___) {
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
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildEditorArea()),
            _buildToolbar(),
          ],
        ),
      ),
    );
  }

  Widget _buildEditorArea() {
    return Container(
      margin: const EdgeInsets.fromLTRB(1, 6, 1, 0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildBlockArea(),
          _buildGutter(),
          Container(width: 1, color: Colors.grey.shade300),
          Expanded(child: _buildTextField()),
        ],
      ),
    );
  }

  // ---------- 方块区 ----------

  Widget _buildBlockArea() {
    return SizedBox(
      width: _kBlockAreaWidth,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final offset =
                _vertCtrl.hasClients ? _vertCtrl.offset : 0.0;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                CustomPaint(
                  size: Size(
                    _kBlockAreaWidth,
                    constraints.maxHeight,
                  ),
                  painter: _ConnectorLinePainter(
                    lineCount: _lineCount,
                    scrollOffset: offset,
                  ),
                ),
                for (var i = 0; i < _lineCount; i++)
                  _buildBlock(i, constraints.maxHeight, offset),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBlock(int i, double maxHeight, double scrollOffset) {
    final centerY = _kEditorVPad +
        i * _kLineHeight +
        _kLineHeight / 2 -
        scrollOffset;
    final top = centerY - _kBlockSize / 2;
    if (top + _kBlockSize < 0 || top > maxHeight) {
      return const SizedBox.shrink();
    }

    final left = i.isEven ? 0.0 : _kBlockOffset;
    final selected = _selectedLines.contains(i);

    return Positioned(
      left: left,
      top: top,
      width: _kBlockSize,
      height: _kBlockSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggleLine(i),
        onLongPress: () => _rangeSelect(i),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? _kCheckColor : _kBlockBgNormal,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: selected ? _kCheckColor : _kBlockBorderNormal,
              width: selected ? 2 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            '${i + 1}',
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              color: selected ? Colors.white : _kBlockTextNormal,
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 原行号栏 ----------

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
          child: Padding(
            padding: const EdgeInsets.only(left: 1, right: 1),
            child: Row(
              children: [
                _buildCheckbox(selected),
                const SizedBox(width: 1),
                Expanded(
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: selected
                          ? _kLineNumSelected
                          : _kLineNumNormal,
                      fontWeight: selected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCheckbox(bool selected) {
    return SizedBox(
      width: 14,
      height: 14,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? _kCheckColor : Colors.transparent,
          border: Border.all(
            color: selected ? _kCheckColor : Colors.grey.shade400,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(2),
        ),
        child: selected
            ? const Icon(Icons.check, size: 10, color: Colors.white)
            : null,
      ),
    );
  }

  // ---------- 编辑区 ----------

  Widget _buildTextField() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = const TextStyle(
          fontSize: _kFontSize,
          fontFamily: 'monospace',
        );

        double maxW = 0;
        for (final line in _lines) {
          double w = 0;
          for (final code in line.runes) {
            w += code < 128 ? _kFontSize * 0.6 : _kFontSize;
          }
          if (w > maxW) maxW = w;
        }
        final needW = maxW + 8;
        final width =
            needW > constraints.maxWidth ? needW : constraints.maxWidth;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: constraints.maxHeight,
            child: Stack(
              children: [
                ..._buildHighlightLayer(),
                Padding(
                  padding: const EdgeInsets.only(left: 1, right: 4),
                  child: TextField(
                    controller: _textCtrl,
                    scrollController: _vertCtrl,
                    maxLines: null,
                    expands: true,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
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
                      contentPadding: EdgeInsets.zero,
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
    return [
      for (final i in _selectedLines)
        Positioned(
          top: _kEditorVPad + i * _kLineHeight - offset,
          left: 0,
          right: 0,
          height: _kLineHeight,
          child: const IgnorePointer(
            child: ColoredBox(color: _kSelectedBg),
          ),
        ),
    ];
  }

  // ---------- 工具条 ----------

  Widget _buildToolbar() {
    final hasContent = _hasContent;
    final hasSelection = _selectedLines.isNotEmpty;
    final minLen = ref.watch(lineListMinLenProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: _toolBtn(
                icon: Icons.copy,
                label: '复制行',
                onTap: hasSelection ? _copySelected : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.delete_outline,
                label: '删除行',
                onTap: hasSelection ? _deleteSelected : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.select_all,
                label: '全选',
                onTap: hasContent ? _selectAll : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.deselect,
                label: '退出选择',
                onTap: hasSelection ? _exitSelection : null,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _toolBtn(
                icon: Icons.west,
                label: '应用到左侧',
                onTap: hasContent ? () => _apply('left') : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.east,
                label: '应用到右侧',
                onTap: hasContent ? () => _apply('right') : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.compare_arrows,
                label: '应用到两侧',
                onTap: hasContent ? () => _apply('both') : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.straighten,
                label: '选大于$minLen字',
                onTap: hasContent ? () => _selectLongLines(minLen) : null,
                onLongPress: hasContent ? _promptMinLen : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _toolBtn({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final enabled = onTap != null || onLongPress != null;
    final s = Theme.of(context).colorScheme;
    final color = enabled ? s.onSurface : s.onSurface.withOpacity(0.3);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== 连接线 ====================

class _ConnectorLinePainter extends CustomPainter {
  _ConnectorLinePainter({
    required this.lineCount,
    required this.scrollOffset,
  });

  final int lineCount;
  final double scrollOffset;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _kConnectorColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (var i = 0; i < lineCount; i++) {
      final centerY = _kEditorVPad +
          i * _kLineHeight +
          _kLineHeight / 2 -
          scrollOffset;
      if (centerY < -20 || centerY > size.height + 20) continue;

      final blockLeft = i.isEven ? 0.0 : _kBlockOffset;
      final blockCenterX = blockLeft + _kBlockSize / 2;

      // 从方块中心画到方块区右边缘。方块会画在线的上方，
      // 遮住方块内部那一段，视觉上就是"从方块右边缘伸出来一条线"。
      canvas.drawLine(
        Offset(blockCenterX, centerY),
        Offset(size.width, centerY),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ConnectorLinePainter old) {
    if (old.lineCount != lineCount) return true;
    if (old.scrollOffset != scrollOffset) return true;
    return false;
  }
}
