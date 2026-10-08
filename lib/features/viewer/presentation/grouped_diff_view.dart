// grouped_diff_view.dart
//
// 新视图：跨行相同块。
// 核心：忽略空白（空格、Tab、换行）后内容相同的多个行，视为一块，
//      只高亮空白字符本身，不整行标红。
// 真正有差异的块，做字符级 diff，只高亮不同的字符。
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
  /// 忽略空白后相等（只差空格 / Tab / 换行）
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

  final int leftStart;
  final int leftEnd;
  final int rightStart;
  final int rightEnd;
  final GroupedBlockKind kind;

  /// 每行要高亮的字符位置。外层下标对应块内行偏移。
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
    c == 0x20 ||
    c == 0x09 ||
    c == 0x0A ||
    c == 0x0D ||
    c == 0x0B ||
    c == 0x0C;

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

  // 3. 把 diff 段映射回行范围
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
    if (merged.isNotEmpty && !merged.last.isEqual && !rb.isEqual) {
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

  // 5. 生成最终 GroupedBlock + 高亮
  final blocks = <GroupedBlock>[];
  for (final rb in merged) {
    final kind = rb.isEqual
        ? _classifyEqual(linesA, linesB, rb)
        : GroupedBlockKind.different;

    List<List<int>> leftHi = const [];
    List<List<int>> rightHi = const [];

    if (kind != GroupedBlockKind.equal) {
      final leftBlob =
          linesA.sublist(rb.leftStart, rb.leftEnd).join('\n');
      final rightBlob =
          linesB.sublist(rb.rightStart, rb.rightEnd).join('\n');

      leftHi = _computeSideHighlights(
        selfBlob: leftBlob,
        selfLineCount: rb.leftEnd - rb.leftStart,
        otherBlob: rightBlob,
      );
      rightHi = _computeSideHighlights(
        selfBlob: rightBlob,
        selfLineCount: rb.rightEnd - rb.rightStart,
        otherBlob: leftBlob,
      );
    } else {
      leftHi = List.generate(rb.leftEnd - rb.leftStart, (_) => <int>[]);
      rightHi = List.generate(rb.rightEnd - rb.rightStart, (_) => <int>[]);
    }

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

GroupedBlockKind _classifyEqual(
  List<String> linesA,
  List<String> linesB,
  _RawBlock rb,
) {
  final leftText = linesA.sublist(rb.leftStart, rb.leftEnd).join('\n');
  final rightText = linesB.sublist(rb.rightStart, rb.rightEnd).join('\n');
  if (leftText == rightText) return GroupedBlockKind.equal;
  return GroupedBlockKind.equalIgnoringWs;
}

/// 计算某一侧的每行高亮位置。
///
/// 做的是「本侧 vs 对侧」的字符级 diff：
///   - DIFF_DELETE 段 = 本侧独有 → 标记
///   - DIFF_INSERT 段 = 对侧独有 → 跳过
/// 这样不论空白还是非空白差异，都能精确定位到字符。
///
/// 换行符位置（行末那一列）会被跳过，因为它不是可显示的字符。
List<List<int>> _computeSideHighlights({
  required String selfBlob,
  required int selfLineCount,
  required String otherBlob,
}) {
  final result = List.generate(selfLineCount, (_) => <int>[]);
  if (selfBlob.isEmpty) return result;

  final dmp = DiffMatchPatch();
  final diffs = dmp.diff(selfBlob, otherBlob);

  // 预计算行起始 + 行长度
  final starts = <int>[0];
  for (var i = 0; i < selfBlob.length; i++) {
    if (selfBlob.codeUnitAt(i) == 0x0A) starts.add(i + 1);
  }
  final lengths = <int>[];
  for (var i = 0; i < starts.length; i++) {
    final end =
        i + 1 < starts.length ? starts[i + 1] - 1 : selfBlob.length;
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
        // 二分找行
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
    // DIFF_INSERT：对侧独有，本侧不高亮
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
  double? _heightWidth;
  double? _heightFont;

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

    if (_heightTable == null ||
        _heightWidth != contentW ||
        _heightFont != fontSize) {
      _heightTable = _buildHeightTable(
        data,
        contentW,
        fontSize,
        mq.textScaler,
      );
      _heightWidth = contentW;
      _heightFont = fontSize;
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
    required this.table,
    required this.side,
    required this.controller,
    required this.showLineNumbers,
    required this.bodyFontSize,
    required this.gutterFontSize,
  });

  final GroupedDiffData data;
  final LineHeightTable table;
  final _Side side;
  final ScrollController? controller;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;

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

  static const Color _wsHighlight = Color(0xFFFFF59D);
  static const Color _charHighlight = Color(0xFFFFB74D);

  @override
  Widget build(BuildContext context) {
    final isLeft = side == _Side.left;
    final startLine = isLeft ? block.leftStart : block.rightStart;
    final endLine = isLeft ? block.leftEnd : block.rightEnd;
    final lines = isLeft ? data.linesA : data.linesB;
    final highlights =
        isLeft ? block.leftHighlights : block.rightHighlights;

    final bg = _bgColor(context);
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
        kind: block.kind,
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
                style: TextStyle(
                  fontSize: gutterFontSize,
                  color: outline,
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text.rich(TextSpan(children: spans)),
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
          children: rowWidgets,
        ),
      ),
    );
  }

  Color _bgColor(BuildContext context) {
    switch (block.kind) {
      case GroupedBlockKind.equal:
        return Colors.transparent;
      case GroupedBlockKind.equalIgnoringWs:
        return const Color(0xFFE3F2FD); // 淡蓝：忽略空白后相同
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
    required GroupedBlockKind kind,
  }) {
    if (text.isEmpty) {
      return [TextSpan(text: ' ', style: baseStyle)];
    }
    if (markPositions.isEmpty) {
      return [TextSpan(text: text, style: baseStyle)];
    }

    // equalIgnoringWs：标黄（空白）；different：标橙（真差异）
    final hlColor = kind == GroupedBlockKind.equalIgnoringWs
        ? _wsHighlight
        : _charHighlight;

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
            backgroundColor: hlColor,
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
