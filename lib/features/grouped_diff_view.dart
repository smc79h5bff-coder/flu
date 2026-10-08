// grouped_diff_view.dart
//
// 新视图：跨行相同块。
// 特点：把「左 1 行 = 右 N 行，忽略空白后相同」的多个行当成一块显示，
//      只高亮空白字符，不整行标红。
// 不影响现有 4 个视图。

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';
import 'line_height_calculator.dart';
import 'providers/diff_viewer_providers.dart';

// ==================== 数据模型 ====================

enum GroupedBlockKind {
  /// 完全相等（连空白都一样）
  equal,
  /// 忽略空白后相等（只差空格/换行）
  equalIgnoringWs,
  /// 有真正的差异
  different,
}

/// 一个块：左侧若干行、右侧若干行，视为一个整体。
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

  /// 左侧行范围 [leftStart, leftEnd)，行号基于原始 A 文本。
  final int leftStart;
  final int leftEnd;
  /// 右侧行范围 [rightStart, rightEnd)，行号基于原始 B 文本。
  final int rightStart;
  final int rightEnd;

  final GroupedBlockKind kind;

  /// 每行要高亮的字符位置，外层下标对应块内行偏移。
  /// 例如 [[0, 5], [2]] 表示块第 0 行位置 0、5 高亮，块第 1 行位置 2 高亮。
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
    c == 0x20 || // 空格
    c == 0x09 || // Tab
    c == 0x0A || // 换行
    c == 0x0D || // 回车
    c == 0x0B || // 垂直 Tab
    c == 0x0C;   // 换页

/// 主入口：算跨行块。
GroupedDiffData computeGroupedDiff(String a, String b) {
  final linesA = a.split('\n');
  final linesB = b.split('\n');

  // 1. 去空白 + 记录每个去空白字符属于哪一行
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

  // 2. 在去空白文本上做字符级 diff
  final dmp = DiffMatchPatch();
  final diffs = dmp.diff(
    String.fromCharCodes(normA),
    String.fromCharCodes(normB),
  );

  // 3. 把 diff 区间映射回行范围，合并成块
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
        leftStart: lStart,
        leftEnd: lEnd,
        rightStart: rStart,
        rightEnd: rEnd,
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
        leftStart: lStart,
        leftEnd: lEnd,
        rightStart: curLineB,
        rightEnd: curLineB,
        isEqual: false,
      ));
      curLineA = lEnd;
      posA += len;
    } else if (d.operation == DIFF_INSERT) {
      final rStart = curLineB;
      final rEnd = normBLine[posB + len - 1] + 1;
      rawBlocks.add(_RawBlock(
        leftStart: curLineA,
        leftEnd: curLineA,
        rightStart: rStart,
        rightEnd: rEnd,
        isEqual: false,
      ));
      curLineB = rEnd;
      posB += len;
    }
  }

  // 4. 合并相邻的「不同」块
  final merged = <_RawBlock>[];
  for (final rb in rawBlocks) {
    if (merged.isNotEmpty &&
        !merged.last.isEqual &&
        !rb.isEqual) {
      final last = merged.removeLast();
      merged.add(_RawBlock(
        leftStart: last.leftStart,
        leftEnd: rb.leftEnd,
        rightStart: last.rightStart,
        rightEnd: rb.rightEnd,
        isEqual: false,
      ));
    } else {
      merged.add(rb);
    }
  }

  // 5. 生成最终 GroupedBlock，加高亮信息
  final blocks = <GroupedBlock>[];
  for (final rb in merged) {
    final kind = rb.isEqual
        ? _classifyEqual(a, b, linesA, linesB, rb)
        : GroupedBlockKind.different;

    final leftHi = _highlightsFor(
      a: a,
      lines: linesA,
      start: rb.leftStart,
      end: rb.leftEnd,
      other: b,
      otherLines: linesB,
      otherStart: rb.rightStart,
      otherEnd: rb.rightEnd,
      kind: kind,
    );
    final rightHi = _highlightsFor(
      a: b,
      lines: linesB,
      start: rb.rightStart,
      end: rb.rightEnd,
      other: a,
      otherLines: linesA,
      otherStart: rb.leftStart,
      otherEnd: rb.leftEnd,
      kind: kind,
    );

    blocks.add(GroupedBlock(
      leftStart: rb.leftStart,
      leftEnd: rb.leftEnd,
      rightStart: rb.rightStart,
      rightEnd: rb.rightEnd,
      kind: kind,
      leftHighlights: leftHi,
      rightHighlights: rightHi,
    ));
  }

  return GroupedDiffData(linesA: linesA, linesB: linesB, blocks: blocks);
}

class _RawBlock {
  const _RawBlock({
    required this.leftStart,
    required this.leftEnd,
    required this.rightStart,
    required this.rightEnd,
    required this.isEqual,
  });
  final int leftStart, leftEnd, rightStart, rightEnd;
  final bool isEqual;
}

/// 判断「相等」块是严格相等还是只忽略空白后相等。
GroupedBlockKind _classifyEqual(
  String a, String b,
  List<String> linesA, List<String> linesB,
  _RawBlock rb,
) {
  // 取两侧原文
  final leftText = linesA.sublist(rb.leftStart, rb.leftEnd).join('\n');
  final rightText = linesB.sublist(rb.rightStart, rb.rightEnd).join('\n');
  if (leftText == rightText) return GroupedBlockKind.equal;
  return GroupedBlockKind.equalIgnoringWs;
}

/// 计算某一侧的每行高亮位置。
///
/// - equalIgnoringWs：把该侧所有空白字符位置标出来
/// - different：把该侧与对侧真正不同的字符标出来
List<List<int>> _highlightsFor({
  required String a,
  required List<String> lines,
  required int start,
  required int end,
  required String other,
  required List<String> otherLines,
  required int otherStart,
  required int otherEnd,
  required GroupedBlockKind kind,
}) {
  final result = <List<int>>[];
  if (end <= start) return result;

  if (kind == GroupedBlockKind.equalIgnoringWs) {
    // 把每行内的空白字符位置全部标出
    for (var li = start; li < end; li++) {
      final text = lines[li];
      final positions = <int>[];
      for (var i = 0; i < text.length; i++) {
        if (_isWhitespace(text.codeUnitAt(i))) positions.add(i);
      }
      result.add(positions);
    }
    return result;
  }

  if (kind == GroupedBlockKind.different) {
    // 该块内：把两侧对应文本拼接后做字符级 diff，找出真正的差异位置
    final sideText = lines.sublist(start, end).join('\n');
    final otherText = otherLines.sublist(otherStart, otherEnd).join('\n');
    final dmp = DiffMatchPatch();
    final diffs = dmp.diff(otherText, sideText); // 顺序：对面在前，本侧在后

    // 每个本侧 diff 段（DELETE/INSERT）都标记为差异
    // 注意：dmp.diff(other, self) 里 DELETE 表示 other 独有，
    // INSERT 表示 self 独有。self 里要标的是 INSERT。
    final perLine = <int>{};
    for (var i = 0; i < end - start; i++) perLine.add(i);
    final lineMarks = <int, Set<int>>{};
    for (final k in perLine.keys) lineMarks[k] = <int>{};

    // 本侧文本相对本侧行起始的字符位置
    // 简化：把 self 文本遍历一遍，遇到 INSERT 段就标在该位置
    var selfPos = 0;
    for (final d in diffs) {
      final len = d.text.length;
      if (d.operation == DIFF_EQUAL || d.operation == DIFF_DELETE) {
        // 属于 other 侧，跳过
        if (d.operation == DIFF_DELETE) continue;
        selfPos += len;
      } else if (d.operation == DIFF_INSERT) {
        // 本侧独有 → 标记为差异
        for (var i = 0; i < len; i++) {
          // 把 selfPos + i 映射到行、列
          var acc = 0;
          var lineOffset = -1;
          for (var k = 0; k < end - start; k++) {
            final lineLen = lines[start + k].length + 1; // +1 是换行
            if (selfPos + i < acc + lineLen) {
              lineOffset = k;
              break;
            }
            acc += lineLen;
          }
          if (lineOffset >= 0) {
            final col = selfPos + i - acc;
            lineMarks[lineOffset]!.add(col);
          }
        }
        selfPos += len;
      }
    }

    for (var k = 0; k < end - start; k++) {
      final marks = lineMarks[k]!.toList()..sort();
      result.add(marks);
    }
    return result;
  }

  // equal：无高亮
  for (var i = 0; i < end - start; i++) {
    result.add(const []);
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
  });

  final ScrollController? controller;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;

  @override
  ConsumerState<GroupedDiffView> createState() => _GroupedDiffViewState();
}

class _GroupedDiffViewState extends ConsumerState<GroupedDiffView> {
  GroupedDiffData? _data;
  LineHeightTable? _heightTable;
  String? _key;

  @override
  Widget build(BuildContext context) {
    final a = ref.watch(preprocessedOriginalProvider);
    final b = ref.watch(preprocessedModifiedProvider);

    final key = '${a.length}|${b.length}|${a.hashCode}|${b.hashCode}';
    if (_key != key || _data == null) {
      _key = key;
      _data = computeGroupedDiff(a, b);
      _heightTable = null;
    }

    final data = _data!;
    final showLine = widget.showLineNumbers;
    final fontSize = widget.bodyFontSize;
    final mq = MediaQuery.of(context);
    final viewportW = mq.size.width;
    final halfW = (viewportW - 1) / 2;
    final contentW = halfW - (showLine ? 42.0 : 12.0);

    // 高度表：每一块的高度 = max(左侧行数, 右侧行数) × 单行高
    if (_heightTable == null) {
      _heightTable = _buildHeightTable(data, contentW, fontSize, mq.textScaler);
    }

    final table = _heightTable!;
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    return Row(
      children: [
        Expanded(
          child: _SidePane(
            data: data,
            table: table,
            side: _Side.left,
            controller: widget.controller,
            showLineNumbers: showLine,
            bodyFontSize: fontSize,
            gutterFontSize: widget.gutterFontSize,
            contentWidth: contentW,
          ),
        ),
        divider,
        Expanded(
          child: _SidePane(
            data: data,
            table: table,
            side: _Side.right,
            controller: null,
            showLineNumbers: showLine,
            bodyFontSize: fontSize,
            gutterFontSize: widget.gutterFontSize,
            contentWidth: contentW,
          ),
        ),
      ],
    );
  }

  LineHeightTable _buildHeightTable(
    GroupedDiffData data,
    double width,
    double fontSize,
    TextScaler scaler,
  ) {
    final heights = <double>[];
    final style = TextStyle(fontSize: fontSize, height: 1.35);
    const extraPad = 8.0;

    for (final block in data.blocks) {
      final leftRows = block.leftLength;
      final rightRows = block.rightLength;
      final rows = leftRows > rightRows ? leftRows : rightRows;
      // 粗算：每行按最长行的折行高度；块高度 = 行数 × 单行高 + padding
      final sample = rows > 0 && leftRows > 0
          ? data.linesA[block.leftStart]
          : (rightRows > 0 ? data.linesB[block.rightStart] : '');
      final h = measureTextHeight(
        text: sample.isEmpty ? 'M' : sample,
        maxWidth: width,
        style: style,
        textScaler: scaler,
      );
      heights.add(h * rows + extraPad);
    }
    return LineHeightTable.fromHeights(heights);
  }
}

enum _Side { left, right }

class _SidePane extends StatelessWidget {
  const _SidePane({
    required this.data,
    required this.table,
    required this.side,
    required this.controller,
    required this.showLineNumbers,
    required this.bodyFontSize,
    required this.gutterFontSize,
    required this.contentWidth,
  });

  final GroupedDiffData data;
  final LineHeightTable table;
  final _Side side;
  final ScrollController? controller;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
  final double contentWidth;

  @override
  Widget build(BuildContext context) {
    final blocks = data.blocks;

    return ListView.builder(
      controller: controller,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      cacheExtent: 100,
      itemCount: blocks.length,
      itemExtentBuilder: (index, dimensions) => table.heightOf(index),
      itemBuilder: (ctx, i) {
        final block = blocks[i];
        return _BlockTile(
          block: block,
          data: data,
          side: side,
          showLineNumbers: showLineNumbers,
          bodyFontSize: bodyFontSize,
          gutterFontSize: gutterFontSize,
          contentWidth: contentWidth,
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
    required this.contentWidth,
  });

  final GroupedBlock block;
  final GroupedDiffData data;
  final _Side side;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
  final double contentWidth;

  @override
  Widget build(BuildContext context) {
    final isLeft = side == _Side.left;
    final startLine = isLeft ? block.leftStart : block.rightStart;
    final endLine = isLeft ? block.leftEnd : block.rightEnd;
    final lines = isLeft ? data.linesA : data.linesB;
    final highlights = isLeft ? block.leftHighlights : block.rightHighlights;

    final bg = _bgColor(context);
    final defaultFg = Theme.of(context).textTheme.bodyMedium?.color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : Colors.black);
    final outline = Theme.of(context).colorScheme.outline;

    final children = <Widget>[];
    for (var li = startLine; li < endLine; li++) {
      final localIdx = li - startLine;
      final marks = localIdx < highlights.length
          ? highlights[localIdx].toSet()
          : const <int>{};
      final lineText = lines[li];
      final spans = _buildSpans(
        text: lineText,
        markPositions: marks,
        baseStyle: TextStyle(
          fontSize: bodyFontSize,
          color: defaultFg,
          height: 1.35,
        ),
      );

      children.add(Row(
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
          Expanded(
            child: Text.rich(
              TextSpan(children: spans),
            ),
          ),
        ],
      ));
    }

    return ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Color _bgColor(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    switch (block.kind) {
      case GroupedBlockKind.equal:
        return Colors.transparent;
      case GroupedBlockKind.equalIgnoringWs:
        // 淡蓝，标记「忽略空白后相同」
        return const Color(0xFFE3F2FD);
      case GroupedBlockKind.different:
        return side == _Side.left
            ? const Color(0xFFFFEEEE)
            : const Color(0xFFEEFFEE);
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
        spans.add(TextSpan(
          text: chunk,
          style: baseStyle.copyWith(
            backgroundColor: const Color(0xFFFFF59D),
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
