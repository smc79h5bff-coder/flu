// grouped_diff_view.dart
//
// 复用现有 diffResultProvider 的行级结果，做后处理：
// 连续的 delete+insert 段，去空白后若相等，合成「跨行相同块」。
// 不重算全文件 diff，速度与现有视图一致。
// 支持标记空格差异和换行差异（行尾显示 ↵）。

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../line_height_calculator.dart';
import 'providers/diff_viewer_providers.dart';

// ==================== 日志 ====================

const bool kGroupedLog = true;

final List<String> kGroupedLogs = [];

void _log(String msg) {
  if (!kGroupedLog) return;
  debugPrint('[GroupedDiff] $msg');
  kGroupedLogs.add(msg);
  if (kGroupedLogs.length > 500) kGroupedLogs.removeRange(0, 100);
}

// ==================== 颜色 ====================

const Color _kEqualIgnoringWsBg = Color(0xFFF7FAFF);
const Color _kDiffLeftBg = Color(0xFFFFEEEE);
const Color _kDiffRightBg = Color(0xFFEEFFEE);
const Color _kCharHighlight = Color(0xFFEF6C00);
const Color _kWsHighlight = Color(0xFFFFD600);

// ==================== 数据模型 ====================

enum GroupedBlockKind { equal, equalIgnoringWs, different }

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

  /// 每行要高亮的字符位置。外层下标 = 块内行偏移。
  /// 特殊值：等于该行长度表示"行尾换行符"。
  final List<List<int>> leftHighlights;
  final List<List<int>> rightHighlights;

  int get leftLength => leftEnd - leftStart;
  int get rightLength => rightEnd - rightStart;
  int get visualLength {
    final l = leftLength;
    final r = rightLength;
    return l > r ? l : r;
  }
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

// ==================== 工具 ====================

bool _isWs(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C;

String _strip(String s) {
  if (s.isEmpty) return '';
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (!_isWs(c)) buf.writeCharCode(c);
  }
  return buf.toString();
}

// ==================== 后处理：从 DiffResult 构建 ====================

GroupedDiffData buildGroupedData(
  DiffResult diff,
  String a,
  String b,
) {
  _log('=== buildGroupedData 开始 ===');

  final linesA = a.split('\n');
  final linesB = b.split('\n');

  _log('行数: A=${linesA.length} B=${linesB.length}');
  _log('entries 数: ${diff.entries.length}');

  final blocks = <GroupedBlock>[];

  var ai = 0, bi = 0, i = 0;
  final entries = diff.entries;

  while (i < entries.length) {
    final e = entries[i];

    if (e.operation == DiffOperation.equal) {
      if (ai >= linesA.length || bi >= linesB.length) break;
      final la = linesA[ai];
      final ra = linesB[bi];
      if (la == ra) {
        blocks.add(GroupedBlock(
          leftStart: ai, leftEnd: ai + 1,
          rightStart: bi, rightEnd: bi + 1,
          kind: GroupedBlockKind.equal,
          leftHighlights: [const <int>[]],
          rightHighlights: [const <int>[]],
        ));
      } else if (_strip(la) == _strip(ra)) {
        blocks.add(GroupedBlock(
          leftStart: ai, leftEnd: ai + 1,
          rightStart: bi, rightEnd: bi + 1,
          kind: GroupedBlockKind.equalIgnoringWs,
          leftHighlights: [_lineDiff(la, ra, true)],
          rightHighlights: [_lineDiff(ra, la, true)],
        ));
      } else {
        blocks.add(GroupedBlock(
          leftStart: ai, leftEnd: ai + 1,
          rightStart: bi, rightEnd: bi + 1,
          kind: GroupedBlockKind.different,
          leftHighlights: [_lineDiff(la, ra, false)],
          rightHighlights: [_lineDiff(ra, la, false)],
        ));
      }
      ai++; bi++; i++;
    } else {
      final startA = ai, startB = bi;
      while (i < entries.length &&
          entries[i].operation != DiffOperation.equal) {
        final op = entries[i].operation;
        if (op == DiffOperation.delete || op == DiffOperation.replace) ai++;
        if (op == DiffOperation.insert || op == DiffOperation.replace) bi++;
        i++;
      }
      final endA = ai, endB = bi;

      if (endA > startA && endB > startB) {
        final leftBlob = linesA.sublist(startA, endA).join('\n');
        final rightBlob = linesB.sublist(startB, endB).join('\n');
        final sameWs = _strip(leftBlob) == _strip(rightBlob);

        _log('差异段: A[$startA,$endA) B[$startB,$endB) '
            'sameWs=$sameWs');

        if (sameWs) {
          blocks.add(GroupedBlock(
            leftStart: startA, leftEnd: endA,
            rightStart: startB, rightEnd: endB,
            kind: GroupedBlockKind.equalIgnoringWs,
            leftHighlights: _blobHighlight(
              linesA.sublist(startA, endA), rightBlob, true),
            rightHighlights: _blobHighlight(
              linesB.sublist(startB, endB), leftBlob, true),
          ));
        } else {
          blocks.add(GroupedBlock(
            leftStart: startA, leftEnd: endA,
            rightStart: startB, rightEnd: endB,
            kind: GroupedBlockKind.different,
            leftHighlights: _blobHighlight(
              linesA.sublist(startA, endA), rightBlob, false),
            rightHighlights: _blobHighlight(
              linesB.sublist(startB, endB), leftBlob, false),
          ));
        }
      } else if (endA > startA) {
        _log('纯删除: A[$startA,$endA)');
        blocks.add(GroupedBlock(
          leftStart: startA, leftEnd: endA,
          rightStart: startB, rightEnd: startB,
          kind: GroupedBlockKind.different,
          leftHighlights: List.generate(endA - startA, (_) => <int>[]),
        ));
      } else if (endB > startB) {
        _log('纯新增: B[$startB,$endB)');
        blocks.add(GroupedBlock(
          leftStart: startA, leftEnd: startA,
          rightStart: startB, rightEnd: endB,
          kind: GroupedBlockKind.different,
          rightHighlights: List.generate(endB - startB, (_) => <int>[]),
        ));
      }
    }
  }

  final diffCount = blocks
      .where((b) => b.kind == GroupedBlockKind.different)
      .length;
  final wsCount = blocks
      .where((b) => b.kind == GroupedBlockKind.equalIgnoringWs)
      .length;
  final eqCount = blocks
      .where((b) => b.kind == GroupedBlockKind.equal)
      .length;
  _log('块数: total=${blocks.length} diff=$diffCount ws=$wsCount eq=$eqCount');
  _log('=== buildGroupedData 结束 ===');

  return GroupedDiffData(linesA: linesA, linesB: linesB, blocks: blocks);
}

List<int> _lineDiff(String self, String other, bool onlyWs) {
  if (self.isEmpty) return const [];
  if (self.length > 100000) {
    _log('_lineDiff: 行过长(${self.length})，跳过');
    return const [];
  }
  try {
    final dmp = DiffMatchPatch()..diffTimeout = 1.0;
    final diffs = dmp.diff(self, other);
    final r = <int>[];
    var pos = 0;
    for (final d in diffs) {
      final len = d.text.length;
      if (d.operation == DIFF_EQUAL) {
        pos += len;
      } else if (d.operation == DIFF_DELETE) {
        for (var k = 0; k < len; k++) {
          final p = pos + k;
          if (p >= self.length) break;
          if (onlyWs && !_isWs(self.codeUnitAt(p))) continue;
          r.add(p);
        }
        pos += len;
      }
    }
    return r;
  } catch (e) {
    _log('_lineDiff 异常: $e');
    return const [];
  }
}

List<List<int>> _blobHighlight(
  List<String> lines,
  String otherBlob,
  bool onlyWs,
) {
  final r = List.generate(lines.length, (_) => <int>[]);
  final selfBlob = lines.join('\n');
  if (selfBlob.isEmpty) return r;

  _log('_blobHighlight: lines=${lines.length} '
      'selfBlob=${selfBlob.length} other=${otherBlob.length} onlyWs=$onlyWs');

  if (selfBlob.length > 100000 || otherBlob.length > 100000) {
    _log('  → 超过 10 万字符，跳过高亮');
    return r;
  }

  try {
    final dmp = DiffMatchPatch()..diffTimeout = 2.0;
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
        for (var k = 0; k < len; k++) {
          final p = pos + k;
          if (p >= selfBlob.length) break;
          if (onlyWs && !_isWs(selfBlob.codeUnitAt(p))) continue;

          var lo = 0, hi = starts.length - 1;
          while (lo < hi) {
            final mid = (lo + hi + 1) >> 1;
            if (starts[mid] <= p) {
              lo = mid;
            } else {
              hi = mid - 1;
            }
          }
          final li = lo;
          final col = p - starts[li];
          // col == lengths[li] 表示行尾的换行符位置
          if (li < lines.length && col <= lengths[li]) {
            r[li].add(col);
          }
        }
        pos += len;
      }
    }
  } catch (e) {
    _log('_blobHighlight 异常: $e');
  }
  return r;
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
  DiffResult? _dataForDiff;
  List<GroupedBlock>? _visible;
  LineHeightTable? _table;
  double? _tableWidth;
  double? _tableFont;

  late final ScrollController _leftCtrl;
  late final ScrollController _rightCtrl;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _leftCtrl = widget.controller ?? ScrollController();
    _rightCtrl = ScrollController();
    _leftCtrl.addListener(_syncL);
    _rightCtrl.addListener(_syncR);
  }

  @override
  void dispose() {
    _leftCtrl.removeListener(_syncL);
    _rightCtrl.removeListener(_syncR);
    if (widget.controller == null) _leftCtrl.dispose();
    _rightCtrl.dispose();
    super.dispose();
  }

  void _syncL() {
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

  void _syncR() {
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
    final diffAsync = ref.watch(diffResultProvider);
    final a = ref.watch(preprocessedOriginalProvider);
    final b = ref.watch(preprocessedModifiedProvider);

    return diffAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('错误：$e')),
      data: (diff) {
        if (diff == null) {
          return const Center(child: Text('请先导入两份文档'));
        }
        if (!identical(_dataForDiff, diff)) {
          _dataForDiff = diff;
          _data = buildGroupedData(diff, a, b);
          _visible = null;
          _table = null;
        }
        return _buildBody(context, _data!);
      },
    );
  }

  Widget _buildBody(BuildContext context, GroupedDiffData data) {
    final showLine = widget.showLineNumbers;
    final fontSize = widget.bodyFontSize;
    final mq = MediaQuery.of(context);
    final viewportW = mq.size.width;
    final halfW = (viewportW - 1) / 2;
    final contentW = halfW - (showLine ? 42.0 : 12.0);

    _visible ??= _filter(data.blocks, widget.contextLines);
    final visible = _visible!;
    _log('可见块数: ${visible.length}');

    if (_table == null || _tableWidth != contentW || _tableFont != fontSize) {
      _table = _buildTable(data, visible, contentW, fontSize, mq.textScaler);
      _tableWidth = contentW;
      _tableFont = fontSize;
    }
    final table = _table!;
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    if (visible.isEmpty) {
      return const Center(child: Text('两份文档完全相同'));
    }

    final content = Row(
      children: [
        Expanded(
          child: _SidePane(
            data: data, blocks: visible, table: table,
            side: _Side.left, controller: _leftCtrl,
            showLineNumbers: showLine, bodyFontSize: fontSize,
            gutterFontSize: widget.gutterFontSize,
          ),
        ),
        divider,
        Expanded(
          child: _SidePane(
            data: data, blocks: visible, table: table,
            side: _Side.right, controller: _rightCtrl,
            showLineNumbers: showLine, bodyFontSize: fontSize,
            gutterFontSize: widget.gutterFontSize,
          ),
        ),
      ],
    );

    if (!kGroupedLog) return content;

    return Stack(
      children: [
        content,
        Positioned(
          right: 4,
          top: 4,
          child: GestureDetector(
            onTap: () => _showLogs(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '日志 ${kGroupedLogs.length}',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showLogs(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: const Text('GroupedDiff 日志',
            style: TextStyle(fontSize: 14)),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.7,
          child: kGroupedLogs.isEmpty
              ? const Center(child: Text('还没有日志'))
              : ListView.builder(
                  itemCount: kGroupedLogs.length,
                  itemBuilder: (ctx, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(
                      kGroupedLogs[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              kGroupedLogs.clear();
              Navigator.pop(c);
            },
            child: const Text('清空'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 保留差异块 + 前后各 contextLines 行上下文。
  List<GroupedBlock> _filter(List<GroupedBlock> blocks, int ctx) {
    final diffIdx = <int>[];
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].kind != GroupedBlockKind.equal) diffIdx.add(i);
    }
    if (diffIdx.isEmpty) return const [];

    final keep = <int>{};
    for (final di in diffIdx) {
      keep.add(di);
      var acc = 0;
      for (var j = di - 1; j >= 0 && acc < ctx; j--) {
        keep.add(j);
        final v = blocks[j].visualLength;
        acc += v == 0 ? 1 : v;
      }
      acc = 0;
      for (var j = di + 1; j < blocks.length && acc < ctx; j++) {
        keep.add(j);
        final v = blocks[j].visualLength;
        acc += v == 0 ? 1 : v;
      }
    }
    final sorted = keep.toList()..sort();
    return [for (final i in sorted) blocks[i]];
  }

  LineHeightTable _buildTable(
    GroupedDiffData data,
    List<GroupedBlock> blocks,
    double width,
    double fontSize,
    TextScaler scaler,
  ) {
    final heights = <double>[];
    final style = TextStyle(fontSize: fontSize, height: 1.35);
    const pad = 8.0;
    final blankH = measureTextHeight(
      text: ' ', maxWidth: width, style: style, textScaler: scaler);

    for (final b in blocks) {
      double lh = 0, rh = 0;
      for (var i = b.leftStart; i < b.leftEnd; i++) {
        if (i < 0 || i >= data.linesA.length) continue;
        lh += measureTextHeight(
          text: data.linesA[i].isEmpty ? ' ' : data.linesA[i],
          maxWidth: width, style: style, textScaler: scaler);
      }
      for (var i = b.rightStart; i < b.rightEnd; i++) {
        if (i < 0 || i >= data.linesB.length) continue;
        rh += measureTextHeight(
          text: data.linesB[i].isEmpty ? ' ' : data.linesB[i],
          maxWidth: width, style: style, textScaler: scaler);
      }
      if (lh == 0) lh = blankH;
      if (rh == 0) rh = blankH;
      heights.add((lh > rh ? lh : rh) + pad);
    }
    return LineHeightTable.fromHeights(heights);
  }
}

enum _Side { left, right }

class _SidePane extends StatelessWidget {
  const _SidePane({
    required this.data, required this.blocks, required this.table,
    required this.side, required this.controller,
    required this.showLineNumbers, required this.bodyFontSize,
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
      itemExtentBuilder: (i, _) =>
          i < table.length ? table.heightOf(i) : 24.0,
      itemBuilder: (ctx, i) => _BlockTile(
        block: blocks[i], data: data, side: side,
        showLineNumbers: showLineNumbers,
        bodyFontSize: bodyFontSize, gutterFontSize: gutterFontSize,
      ),
    );
  }
}

class _BlockTile extends StatelessWidget {
  const _BlockTile({
    required this.block, required this.data, required this.side,
    required this.showLineNumbers, required this.bodyFontSize,
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
    final start = isLeft ? block.leftStart : block.rightStart;
    final end = isLeft ? block.leftEnd : block.rightEnd;
    final lines = isLeft ? data.linesA : data.linesB;
    final hi = isLeft ? block.leftHighlights : block.rightHighlights;
    final bg = _bg();
    final fg = Theme.of(context).textTheme.bodyMedium?.color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : Colors.black);
    final outline = Theme.of(context).colorScheme.outline;
    final base = TextStyle(fontSize: bodyFontSize, color: fg, height: 1.35);

    final rows = <Widget>[];
    for (var li = start; li < end; li++) {
      if (li < 0 || li >= lines.length) continue;
      final local = li - start;
      final marks =
          local >= 0 && local < hi.length ? hi[local].toSet() : <int>{};
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLineNumbers) ...[
            SizedBox(
              width: 30,
              child: Text('${li + 1}',
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: gutterFontSize, color: outline)),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text.rich(TextSpan(children: _spans(lines[li], marks, base))),
          ),
        ],
      ));
    }
    if (rows.isEmpty) {
      rows.add(SizedBox(height: bodyFontSize * 1.35));
    }

    return ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );
  }

  Color _bg() {
    switch (block.kind) {
      case GroupedBlockKind.equal:
        return Colors.transparent;
      case GroupedBlockKind.equalIgnoringWs:
        return _kEqualIgnoringWsBg;
      case GroupedBlockKind.different:
        return side == _Side.left ? _kDiffLeftBg : _kDiffRightBg;
    }
  }

  List<InlineSpan> _spans(String text, Set<int> marks, TextStyle base) {
    final lineEndMarked = marks.contains(text.length);
    final innerMarks = marks.where((m) => m < text.length).toSet();

    final out = <InlineSpan>[];

    if (text.isEmpty) {
      out.add(TextSpan(text: ' ', style: base));
    } else if (innerMarks.isEmpty) {
      out.add(TextSpan(text: text, style: base));
    } else {
      var i = 0;
      while (i < text.length) {
        final marked = innerMarks.contains(i);
        var j = i;
        while (j < text.length && innerMarks.contains(j) == marked) j++;
        final chunk = text.substring(i, j);
        if (marked) {
          final c = _isWs(text.codeUnitAt(i)) ? _kWsHighlight : _kCharHighlight;
          out.add(TextSpan(
            text: chunk,
            style: base.copyWith(
              backgroundColor: c,
              fontWeight: FontWeight.bold,
            ),
          ));
        } else {
          out.add(TextSpan(text: chunk, style: base));
        }
        i = j;
      }
    }

    if (lineEndMarked) {
      out.add(TextSpan(
        text: '↵',
        style: base.copyWith(
          backgroundColor: _kWsHighlight,
          fontWeight: FontWeight.bold,
        ),
      ));
    }

    return out;
  }
}
