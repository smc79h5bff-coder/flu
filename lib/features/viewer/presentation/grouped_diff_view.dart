// grouped_diff_view.dart
//
// 新视图：跨行相同块。
// 相同行拆成单行块；跨行相同的多行（忽略空白后一致）保留整块；
// 真差异块保留整块做字符级 diff。
// 上下文按行算（前后各 2 行）。左右同步滚动。
// 不影响现有 4 个视图。

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';
import 'line_height_calculator.dart';
import 'providers/diff_viewer_providers.dart';

// ==================== 颜色 ====================

/// 忽略空白后相同的块底色（很浅的蓝）
const Color _kEqualIgnoringWsBg = Color(0xFFF0F6FF);

/// 差异块底色
const Color _kDiffLeftBg = Color(0xFFFFEEEE);
const Color _kDiffRightBg = Color(0xFFEEFFEE);

/// 差异字符高亮（深橙，配黑字）
const Color _kCharHighlight = Color(0xFFFFA000);

/// 空白字符差异高亮（高饱和黄）
const Color _kWsHighlight = Color(0xFFFFEB3B);

// ==================== 数据模型 ====================

enum GroupedBlockKind {
  /// 完全相等
  equal,
  /// 忽略空白后相等
  equalIgnoringWs,
  /// 有真正的差异
  different,
}

class GroupedBlock {
  const GroupedBlock({
    required this.leftStart,
    required this.leftEnd,
    required this.rightStart,
    required this.rightEnd,
    required this.kind,
    this.leftHighlights = const [],
    this.rightHighlights = const [],
  });

  final int leftStart, leftEnd, rightStart, rightEnd;
  final GroupedBlockKind kind;
  final List<List<int>> leftHighlights;
  final List<List<int>> rightHighlights;

  int get leftLength => leftEnd - leftStart;
  int get rightLength => rightEnd - rightStart;
}

class GroupedDiffData {
  const GroupedDiffData({
    required this.linesA,
    required this.linesB,
    required this.blocks,
  });

  final List<String> linesA;
  final List<String> linesB;
  final List<GroupedBlock> blocks;
}

// ==================== 算法 ====================

bool _isWhitespace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C;

GroupedDiffData computeGroupedDiff(String a, String b) {
  final linesA = a.split('\n');
  final linesB = b.split('\n');

  // 1. 去空白 + 记录每个字符属于哪一行
  final normA = <int>[];
  final normALine = <int>[];
  var line = 0;
  for (var i = 0; i < a.length; i++) {
    final c = a.codeUnitAt(i);
    if (c == 0x0A) {
      line++;
      continue;
    }
    if (_isWhitespace(c)) continue;
    normA.add(c);
    normALine.add(line);
  }
  final normB = <int>[];
  final normBLine = <int>[];
  line = 0;
  for (var i = 0; i < b.length; i++) {
    final c = b.codeUnitAt(i);
    if (c == 0x0A) {
      line++;
      continue;
    }
    if (_isWhitespace(c)) continue;
    normB.add(c);
    normBLine.add(line);
  }

  // 2. 去空白字符流上做 diff
  final dmp = DiffMatchPatch();
  final diffs = dmp.diff(
    String.fromCharCodes(normA),
    String.fromCharCodes(normB),
  );

  // 3. 段 → 行范围
  final rawBlocks = <_RawBlock>[];
  var posA = 0, posB = 0;
  var curLineA = 0, curLineB = 0;

  for (final d in diffs) {
    final len = d.text.length;
    if (len == 0) continue;

    if (d.operation == DIFF_EQUAL) {
      final lStart = curLineA;
      final lEnd = normALine[posA + len - 1] + 1;
      final rStart = curLineB;
      final rEnd = normBLine[posB + len - 1] + 1;
      rawBlocks.add(_RawBlock(
        leftStart: lStart, leftEnd: lEnd,
        rightStart: rStart, rightEnd: rEnd,
        isEqual: true,
      ));
      curLineA = lEnd;
      curLineB = rEnd;
      posA += len;
      posB += len;
    } else if (d.operation == DIFF_DELETE) {
      final lStart = curLineA;
      final lEnd = normALine[posA + len - 1] + 1;
      rawBlocks.add(_RawBlock(
        leftStart: lStart, leftEnd: lEnd,
        rightStart: curLineB, rightEnd: curLineB,
        isEqual: false,
      ));
      curLineA = lEnd;
      posA += len;
    } else if (d.operation == DIFF_INSERT) {
      final rStart = curLineB;
      final rEnd = normBLine[posB + len - 1] + 1;
      rawBlocks.add(_RawBlock(
        leftStart: curLineA, leftEnd: curLineA,
        rightStart: rStart, rightEnd: rEnd,
        isEqual: false,
      ));
      curLineB = rEnd;
      posB += len;
    }
  }

  // 4. 合并相邻 different 块
  final merged = <_RawBlock>[];
  for (final rb in rawBlocks) {
    if (merged.isNotEmpty && !merged.last.isEqual && !rb.isEqual) {
      final last = merged.removeLast();
      merged.add(_RawBlock(
        leftStart: last.leftStart, leftEnd: rb.leftEnd,
        rightStart: last.rightStart, rightEnd: rb.rightEnd,
        isEqual: false,
      ));
    } else {
      merged.add(rb);
    }
  }

  // 5. 生成最终块
  final blocks = <GroupedBlock>[];
  for (final rb in merged) {
    if (rb.isEqual) {
      final leftLen = rb.leftEnd - rb.leftStart;
      final rightLen = rb.rightEnd - rb.rightStart;

      if (leftLen == rightLen && leftLen > 0) {
        // 行数相同 → 逐行拆
        for (var k = 0; k < leftLen; k++) {
          final la = linesA[rb.leftStart + k];
          final ra = linesB[rb.rightStart + k];
          if (la == ra) {
            blocks.add(GroupedBlock(
              leftStart: rb.leftStart + k, leftEnd: rb.leftStart + k + 1,
              rightStart: rb.rightStart + k, rightEnd: rb.rightStart + k + 1,
              kind: GroupedBlockKind.equal,
              leftHighlights: [<int>[]],
              rightHighlights: [<int>[]],
            ));
          } else {
            // 只差空白（非空白字符可能也乱，但我们只标空白）
            final leftHi = _diffPositionsInLine(la, ra, onlyWhitespace: true);
            final rightHi = _diffPositionsInLine(ra, la, onlyWhitespace: true);
            blocks.add(GroupedBlock(
              leftStart: rb.leftStart + k, leftEnd: rb.leftStart + k + 1,
              rightStart: rb.rightStart + k, rightEnd: rb.rightStart + k + 1,
              kind: GroupedBlockKind.equalIgnoringWs,
              leftHighlights: [leftHi],
              rightHighlights: [rightHi],
            ));
          }
        }
      } else {
        // 行数不同 → 整块 equalIgnoringWs
        final leftBlob = linesA.sublist(rb.leftStart, rb.leftEnd).join('\n');
        final rightBlob = linesB.sublist(rb.rightStart, rb.rightEnd).join('\n');
        blocks.add(GroupedBlock(
          leftStart: rb.leftStart, leftEnd: rb.leftEnd,
          rightStart: rb.rightStart, rightEnd: rb.rightEnd,
          kind: GroupedBlockKind.equalIgnoringWs,
          leftHighlights: _computeSideHighlights(
            selfBlob: leftBlob,
            selfLineCount: leftLen,
            otherBlob: rightBlob,
            onlyWhitespace: true,
          ),
          rightHighlights: _computeSideHighlights(
            selfBlob: rightBlob,
            selfLineCount: rightLen,
            otherBlob: leftBlob,
            onlyWhitespace: true,
          ),
        ));
      }
    } else {
      // 真差异块
      final leftBlob = linesA.sublist(rb.leftStart, rb.leftEnd).join('\n');
      final rightBlob = linesB.sublist(rb.rightStart, rb.rightEnd).join('\n');
      blocks.add(GroupedBlock(
        leftStart: rb.leftStart, leftEnd: rb.leftEnd,
        rightStart: rb.rightStart, rightEnd: rb.rightEnd,
        kind: GroupedBlockKind.different,
        leftHighlights: _computeSideHighlights(
          selfBlob: leftBlob,
          selfLineCount: rb.leftEnd - rb.leftStart,
          otherBlob: rightBlob,
          onlyWhitespace: false,
        ),
        rightHighlights: _computeSideHighlights(
          selfBlob: rightBlob,
          selfLineCount: rb.rightEnd - rb.rightStart,
          otherBlob: leftBlob,
          onlyWhitespace: false,
        ),
      ));
    }
  }

  return GroupedDiffData(linesA: linesA, linesB: linesB, blocks: blocks);
}

class _RawBlock {
  const _RawBlock({
    required this.leftStart, required this.leftEnd,
    required this.rightStart, required this.rightEnd,
    required this.isEqual,
  });
  final int leftStart, leftEnd, rightStart, rightEnd;
  final bool isEqual;
}

/// 单行 vs 单行：本侧独有字符的位置。
List<int> _diffPositionsInLine(
  String self,
  String other, {
  required bool onlyWhitespace,
}) {
  if (self.isEmpty) return const [];
  final dmp = DiffMatchPatch();
  final diffs = dmp.diff(self, other);
  final result = <int>[];
  var pos = 0;
  for (final d in diffs) {
    final len = d.text.length;
    if (d.operation == DIFF_EQUAL) {
      pos += len;
    } else if (d.operation == DIFF_DELETE) {
      for (var i = 0; i < len; i++) {
        final p = pos + i;
        if (onlyWhitespace && !_isWhitespace(self.codeUnitAt(p))) continue;
        result.add(p);
      }
      pos += len;
    }
  }
  return result;
}

/// 多行 blob vs blob：本侧独有字符的位置，按行分组。
List<List<int>> _computeSideHighlights({
  required String selfBlob,
  required int selfLineCount,
  required String otherBlob,
  required bool onlyWhitespace,
}) {
  final result = List.generate(selfLineCount, (_) => <int>[]);
  if (selfBlob.isEmpty) return result;

  final dmp = DiffMatchPatch();
  final diffs = dmp.diff(selfBlob, otherBlob);

  final starts = <int>[0];
  for (var i = 0; i < selfBlob.length; i++) {
    if (selfBlob.codeUnitAt(i) == 0x0A) starts.add(i + 1);
  }
  final lengths = <int>[];
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] - 1 : selfBlob.length;
    lengths.add(end - starts[i]);
  }

  var pos = 0;
  for (final d in diffs) {
    final len = d.text.length;
    if (d.operation == DIFF_EQUAL) {
      pos += len;
    } else if (d.operation == DIFF_DELETE) {
      for (var i = 0; i < len; i++) {
        final p = pos + i;
        if (p >= selfBlob.length) break;
        if (onlyWhitespace && !_isWhitespace(selfBlob.codeUnitAt(p))) continue;

        var lo = 0, hi = starts.length - 1;
        while (lo < hi) {
          final mid = (lo + hi + 1) >> 1;
          if (starts[mid] <= p) {
            lo = mid;
          } else {
            hi = mid - 1;
          }
        }
        final lineIdx = lo;
        final col = p - starts[lineIdx];
        if (lineIdx < selfLineCount && col < lengths[lineIdx]) {
          result[lineIdx].add(col);
        }
      }
      pos += len;
    }
  }

  return result;
}

// ==================== 视图 ====================

class GroupedDiffView extends ConsumerStatefulWidget {
  const GroupedDiffView({
    super.key,
    this.controller,
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
    this.contextLines = 2,
  });

  final ScrollController? controller;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
  final int contextLines;

  @override
  ConsumerState<GroupedDiffView> createState() => _GroupedDiffViewState();
}

class _GroupedDiffViewState extends ConsumerState<GroupedDiffView> {
  GroupedDiffData? _data;
  LineHeightTable? _heightTable;
  List<GroupedBlock>? _visibleBlocks;
  String? _key;
  double? _heightWidth;
  double? _heightFont;

  late final ScrollController _leftCtrl;
  late final ScrollController _rightCtrl;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _leftCtrl = widget.controller ?? ScrollController();
    _rightCtrl = ScrollController();
    _leftCtrl.addListener(_syncFromLeft);
    _rightCtrl.addListener(_syncFromRight);
  }

  @override
  void dispose() {
    _leftCtrl.removeListener(_syncFromLeft);
    _rightCtrl.removeListener(_syncFromRight);
    if (widget.controller == null) _leftCtrl.dispose();
    _rightCtrl.dispose();
    super.dispose();
  }

  void _syncFromLeft() {
    if (_syncing) return;
    if (!_leftCtrl.hasClients || !_rightCtrl.hasClients) return;
    final o = _leftCtrl.offset;
    if ((_rightCtrl.offset - o).abs() < 0.5) return;
    _syncing = true;
    try {
      _rightCtrl.jumpTo(o.clamp(
        _rightCtrl.position.minScrollExtent,
        _rightCtrl.position.maxScrollExtent,
      ));
    } catch (_) {}
    _syncing = false;
  }

  void _syncFromRight() {
    if (_syncing) return;
    if (!_leftCtrl.hasClients || !_rightCtrl.hasClients) return;
    final o = _rightCtrl.offset;
    if ((_leftCtrl.offset - o).abs() < 0.5) return;
    _syncing = true;
    try {
      _leftCtrl.jumpTo(o.clamp(
        _leftCtrl.position.minScrollExtent,
        _leftCtrl.position.maxScrollExtent,
      ));
    } catch (_) {}
    _syncing = false;
  }

  @override
  Widget build(BuildContext context) {
    final a = ref.watch(preprocessedOriginalProvider);
    final b = ref.watch(preprocessedModifiedProvider);

    final key = '${a.length}|${b.length}|${a.hashCode}|${b.hashCode}';
    if (_key != key || _data == null) {
      _key = key;
      _data = computeGroupedDiff(a, b);
      _heightTable = null;
      _visibleBlocks = null;
    }

    final data = _data!;
    final showLine = widget.showLineNumbers;
    final fontSize = widget.bodyFontSize;
    final mq = MediaQuery.of(context);
    final viewportW = mq.size.width;
    final halfW = (viewportW - 1) / 2;
    final contentW = halfW - (showLine ? 42.0 : 12.0);

    if (_visibleBlocks == null) {
      _visibleBlocks = _filterVisible(
        data.blocks,
        contextLines: widget.contextLines,
      );
    }
    final visible = _visibleBlocks!;

    if (_heightTable == null ||
        _heightWidth != contentW ||
        _heightFont != fontSize) {
      _heightTable = _buildHeightTable(
        data, visible, contentW, fontSize, mq.textScaler,
      );
      _heightWidth = contentW;
      _heightFont = fontSize;
    }

    final table = _heightTable!;
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    if (visible.isEmpty) {
      return const Center(child: Text('两份文档完全相同'));
    }

    return Row(
      children: [
        Expanded(
          child: _SidePane(
            data: data,
            blocks: visible,
            table: table,
            side: _Side.left,
            controller: _leftCtrl,
            showLineNumbers: showLine,
            bodyFontSize: fontSize,
            gutterFontSize: widget.gutterFontSize,
          ),
        ),
        divider,
        Expanded(
          child: _SidePane(
            data: data,
            blocks: visible,
            table: table,
            side: _Side.right,
            controller: _rightCtrl,
            showLineNumbers: showLine,
            bodyFontSize: fontSize,
            gutterFontSize: widget.gutterFontSize,
          ),
        ),
      ],
    );
  }

  /// 只保留差异块 + 前后各 contextLines 行上下文。
  List<GroupedBlock> _filterVisible(
    List<GroupedBlock> blocks, {
    required int contextLines,
  }) {
    final diffIdx = <int>[];
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].kind != GroupedBlockKind.equal) diffIdx.add(i);
    }
    if (diffIdx.isEmpty) return const [];

    final keep = <int>{};
    for (final di in diffIdx) {
      keep.add(di);

      // 往前扩
      var acc = 0;
      for (var j = di - 1; j >= 0 && acc < contextLines; j--) {
        keep.add(j);
        acc += blocks[j].leftLength;
      }
      // 往后扩
      acc = 0;
      for (var j = di + 1; j < blocks.length && acc < contextLines; j++) {
        keep.add(j);
        acc += blocks[j].leftLength;
      }
    }
    final sorted = keep.toList()..sort();
    return [for (final i in sorted) blocks[i]];
  }

  LineHeightTable _buildHeightTable(
    GroupedDiffData data,
    List<GroupedBlock> blocks,
    double width,
    double fontSize,
    TextScaler scaler,
  ) {
    final heights = <double>[];
    final style = TextStyle(fontSize: fontSize, height: 1.35);
    const extraPad = 8.0;

    for (final block in blocks) {
      double leftH = 0;
      for (var i = block.leftStart; i < block.leftEnd; i++) {
        leftH += measureTextHeight(
          text: data.linesA[i].isEmpty ? ' ' : data.linesA[i],
          maxWidth: width,
          style: style,
          textScaler: scaler,
        );
      }
      double rightH = 0;
      for (var i = block.rightStart; i < block.rightEnd; i++) {
        rightH += measureTextHeight(
          text: data.linesB[i].isEmpty ? ' ' : data.linesB[i],
          maxWidth: width,
          style: style,
          textScaler: scaler,
        );
      }
      heights.add((leftH > rightH ? leftH : rightH) + extraPad);
    }
    return LineHeightTable.fromHeights(heights);
  }
}

enum _Side { left, right }

class _SidePane extends StatelessWidget {
  const _SidePane({
    required this.data,
    required this.blocks,
    required this.table,
    required this.side,
    required this.controller,
    required this.showLineNumbers,
    required this.bodyFontSize,
    required this.gutterFontSize,
  });

  final GroupedDiffData data;
  final List<GroupedBlock> blocks;
  final LineHeightTable table;
  final _Side side;
  final ScrollController? controller;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      cacheExtent: 100,
      itemCount: blocks.length,
      itemExtentBuilder: (index, dimensions) => table.heightOf(index),
      itemBuilder: (ctx, i) {
        return _BlockTile(
          block: blocks[i],
          data: data,
          side: side,
          showLineNumbers: showLineNumbers,
          bodyFontSize: bodyFontSize,
          gutterFontSize: gutterFontSize,
        );
      },
    );
  }
}

class _BlockTile extends StatelessWidget {
  const _BlockTile({
    required this.block,
    required this.data,
    required this.side,
    required this.showLineNumbers,
    required this.bodyFontSize,
    required this.gutterFontSize,
  });

  final GroupedBlock block;
  final GroupedDiffData data;
  final _Side side;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;

  @override
  Widget build(BuildContext context) {
    final isLeft = side == _Side.left;
    final startLine = isLeft ? block.leftStart : block.rightStart;
    final endLine = isLeft ? block.leftEnd : block.rightEnd;
    final lines = isLeft ? data.linesA : data.linesB;
    final highlights = isLeft ? block.leftHighlights : block.rightHighlights;

    final bg = _bgColor();
    final defaultFg = Theme.of(context).textTheme.bodyMedium?.color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : Colors.black);
    final outline = Theme.of(context).colorScheme.outline;

    final baseStyle = TextStyle(
      fontSize: bodyFontSize,
      color: defaultFg,
      height: 1.35,
    );

    final rowWidgets = <Widget>[];
    for (var li = startLine; li < endLine; li++) {
      final localIdx = li - startLine;
      final marks = localIdx < highlights.length
          ? highlights[localIdx].toSet()
          : const <int>{};

      final spans = _buildSpans(
        text: lines[li],
        markPositions: marks,
        baseStyle: baseStyle,
      );

      rowWidgets.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLineNumbers) ...[
            SizedBox(
              width: 30,
              child: Text(
                '${li + 1}',
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: gutterFontSize, color: outline),
              ),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(child: Text.rich(TextSpan(children: spans))),
        ],
      ));
    }

    return ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rowWidgets,
        ),
      ),
    );
  }

  Color _bgColor() {
    switch (block.kind) {
      case GroupedBlockKind.equal:
        return Colors.transparent;
      case GroupedBlockKind.equalIgnoringWs:
        return _kEqualIgnoringWsBg;
      case GroupedBlockKind.different:
        return side == _Side.left ? _kDiffLeftBg : _kDiffRightBg;
    }
  }

  List<InlineSpan> _buildSpans({
    required String text,
    required Set<int> markPositions,
    required TextStyle baseStyle,
  }) {
    if (text.isEmpty) {
      return [TextSpan(text: ' ', style: baseStyle)];
    }
    if (markPositions.isEmpty) {
      return [TextSpan(text: text, style: baseStyle)];
    }

    final spans = <InlineSpan>[];
    var i = 0;
    while (i < text.length) {
      final marked = markPositions.contains(i);
      var j = i;
      while (j < text.length && markPositions.contains(j) == marked) {
        j++;
      }
      final chunk = text.substring(i, j);
      if (marked) {
        // 是空白 → 黄；非空白 → 深橙
        final c = _isWhitespace(text.codeUnitAt(i))
            ? _kWsHighlight
            : _kCharHighlight;
        spans.add(TextSpan(
          text: chunk,
          style: baseStyle.copyWith(
            backgroundColor: c,
            fontWeight: FontWeight.bold,
          ),
        ));
      } else {
        spans.add(TextSpan(text: chunk, style: baseStyle));
      }
      i = j;
    }
    return spans;
  }
}
