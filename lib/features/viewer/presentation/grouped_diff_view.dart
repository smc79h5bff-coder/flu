// grouped_diff_view.dart
//
// 新视图：跨行相同块。
// 算法：
//   1. 每行去空白 → 得到行签名
//   2. 在签名序列上做行级 diff（用 PUA 编码 + diff_match_patch）
//   3. 连续非 EQUAL 段：比较拼接后的去空白内容，判定"跨行相同"还是"真差异"
//   4. 单行 EQUAL：逐行再判断是完全相同还是只差空白
// 上下文按行算（前后各 N 行）。左右同步滚动。
//
// 调试：把 kGroupedDiffDebug 设为 true，看控制台日志 + 屏幕右上角日志按钮。

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';
import 'line_height_calculator.dart';
import 'providers/diff_viewer_providers.dart';

// ==================== 调试开关 ====================

/// true 时打印每一步的日志，并在屏幕右上角显示日志按钮。上线时改成 false。
const bool kGroupedDiffDebug = true;

/// 屏幕日志缓冲区（最多 300 条）。
final List<String> kGroupedDiffLogs = [];

void _log(String msg) {
  if (!kGroupedDiffDebug) return;
  debugPrint('[GroupedDiff] $msg');
  kGroupedDiffLogs.add(msg);
  if (kGroupedDiffLogs.length > 300) kGroupedDiffLogs.removeAt(0);
}

// ==================== 颜色 ====================

const Color _kEqualIgnoringWsBg = Color(0xFFF7FAFF);
const Color _kDiffLeftBg = Color(0xFFFFEEEE);
const Color _kDiffRightBg = Color(0xFFEEFFEE);
const Color _kCharHighlight = Color(0xFFEF6C00);
const Color _kWsHighlight = Color(0xFFFFD600);

// ==================== 数据模型 ====================

enum GroupedBlockKind {
  /// 两边完全一样（逐字符）
  equal,

  /// 忽略空白后一样（只差空格 / Tab / 换行）
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

  /// 左侧行范围 [leftStart, leftEnd)，左边可能为空（leftStart == leftEnd）
  final int leftStart, leftEnd;

  /// 右侧行范围 [rightStart, rightEnd)，右边可能为空
  final int rightStart, rightEnd;

  final GroupedBlockKind kind;

  /// 每行要高亮的字符位置。外层下标 = 块内行偏移。
  final List<List<int>> leftHighlights;
  final List<List<int>> rightHighlights;

  int get leftLength => leftEnd - leftStart;
  int get rightLength => rightEnd - rightStart;

  @override
  String toString() =>
      'GroupedBlock(${kind.name} L[$leftStart,$leftEnd) R[$rightStart,$rightEnd))';
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

  int get diffBlockCount =>
      blocks.where((b) => b.kind != GroupedBlockKind.equal).length;
}

// ==================== 空白判断 ====================

bool _isWhitespaceCode(int c) =>
    c == 0x20 || // 空格
    c == 0x09 || // Tab
    c == 0x0A || // LF
    c == 0x0D || // CR
    c == 0x0B || // VT
    c == 0x0C;   // FF

/// 去掉一行里所有空白字符。
String _strip(String s) {
  if (s.isEmpty) return '';
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (_isWhitespaceCode(c)) continue;
    buf.writeCharCode(c);
  }
  return buf.toString();
}

/// 一行是否全是空白（含空行）。
bool _isBlankLine(String s) => _strip(s).isEmpty;

// ==================== 主算法 ====================

GroupedDiffData computeGroupedDiff(String a, String b) {
  _log('=== computeGroupedDiff 开始 ===');
  _log('输入长度: A=${a.length} B=${b.length}');

  if (a.isEmpty && b.isEmpty) {
    _log('两边都为空，返回空结果');
    return const GroupedDiffData(linesA: [''], linesB: [''], blocks: []);
  }

  final linesA = a.split('\n');
  final linesB = b.split('\n');
  _log('行数: A=${linesA.length} B=${linesB.length}');

  final strippedA = linesA.map(_strip).toList();
  final strippedB = linesB.map(_strip).toList();

  // ---- 步骤 1：给每个唯一「去空白行」分配一个字符 ----
  final tokenMap = <String, int>{};
  var nextId = 0xE000;

  // 检查原文本里有没有 PUA 字符，有的话偏移起点避开。
  var base = 0xE000;
  for (var i = 0; i < a.length; i++) {
    final c = a.codeUnitAt(i);
    if (c >= 0xE000 && c <= 0xF8FF && c >= base) {
      base = c + 1;
    }
  }
  for (var i = 0; i < b.length; i++) {
    final c = b.codeUnitAt(i);
    if (c >= 0xE000 && c <= 0xF8FF && c >= base) {
      base = c + 1;
    }
  }
  nextId = base;
  _log('PUA 起始: 0x${base.toRadixString(16)}');

  int getId(String s) {
    var id = tokenMap[s];
    if (id == null) {
      if (nextId > 0xF8FF) {
        // PUA 用尽，返回一个"绝不相等"的临时 id（后面会降级）。
        id = 0xFFFF;
      } else {
        id = nextId++;
      }
      tokenMap[s] = id;
    }
    return id;
  }

  final bufA = StringBuffer();
  for (final s in strippedA) {
    final id = getId(s);
    if (id == 0xFFFF) {
      _log('唯一行数超过 PUA 容量，降级为整文件不同');
      return _fallbackAllDifferent(linesA, linesB);
    }
    bufA.writeCharCode(id);
  }
  final bufB = StringBuffer();
  for (final s in strippedB) {
    final id = getId(s);
    if (id == 0xFFFF) {
      _log('唯一行数超过 PUA 容量，降级为整文件不同');
      return _fallbackAllDifferent(linesA, linesB);
    }
    bufB.writeCharCode(id);
  }
  _log('唯一行数: ${tokenMap.length}');

  // ---- 步骤 2：行级 diff ----
  List<Diff> diffs;
  try {
    final dmp = DiffMatchPatch();
    diffs = dmp.diff(bufA.toString(), bufB.toString());
    dmp.diffCleanupSemantic(diffs);
  } catch (e, st) {
    _log('diff 抛异常: $e\n$st');
    return _fallbackAllDifferent(linesA, linesB);
  }
  _log('diff 段数: ${diffs.length}');

  // ---- 步骤 3：遍历 diff 段，生成块 ----
  final blocks = <GroupedBlock>[];
  var ai = 0, bi = 0;
  var i = 0;

  while (i < diffs.length) {
    final d = diffs[i];
    final n = d.text.length;

    if (d.operation == DIFF_EQUAL) {
      // 逐行拆开，每行独立判断。
      for (var k = 0; k < n; k++) {
        if (ai + k >= linesA.length || bi + k >= linesB.length) {
          _log('警告：EQUAL 段越界 (ai=${ai + k} bi=${bi + k})');
          break;
        }
        final la = linesA[ai + k];
        final ra = linesB[bi + k];
        if (la == ra) {
          blocks.add(GroupedBlock(
            leftStart: ai + k, leftEnd: ai + k + 1,
            rightStart: bi + k, rightEnd: bi + k + 1,
            kind: GroupedBlockKind.equal,
            leftHighlights: [const <int>[]],
            rightHighlights: [const <int>[]],
          ));
        } else {
          // 只差空白
          final leftHi = _diffPositionsInLine(la, ra, onlyWhitespace: true);
          final rightHi = _diffPositionsInLine(ra, la, onlyWhitespace: true);
          blocks.add(GroupedBlock(
            leftStart: ai + k, leftEnd: ai + k + 1,
            rightStart: bi + k, rightEnd: bi + k + 1,
            kind: GroupedBlockKind.equalIgnoringWs,
            leftHighlights: [leftHi],
            rightHighlights: [rightHi],
          ));
        }
      }
      ai += n;
      bi += n;
      i++;
    } else {
      // 收集连续的非 EQUAL 段
      var delStart = ai, delEnd = ai;
      var insStart = bi, insEnd = bi;
      while (i < diffs.length && diffs[i].operation != DIFF_EQUAL) {
        if (diffs[i].operation == DIFF_DELETE) {
          delEnd += diffs[i].text.length;
        } else if (diffs[i].operation == DIFF_INSERT) {
          insEnd += diffs[i].text.length;
        }
        i++;
      }

      // 边界保护
      if (delEnd > linesA.length) delEnd = linesA.length;
      if (insEnd > linesB.length) insEnd = linesB.length;

      final hasDel = delEnd > delStart;
      final hasIns = insEnd > insStart;

      if (hasDel && hasIns) {
        final sa = strippedA.sublist(delStart, delEnd).join();
        final sb = strippedB.sublist(insStart, insEnd).join();
        final leftBlob = linesA.sublist(delStart, delEnd).join('\n');
        final rightBlob = linesB.sublist(insStart, insEnd).join('\n');

        if (sa == sb) {
          // 跨行相同 → 只标空白
          blocks.add(GroupedBlock(
            leftStart: delStart, leftEnd: delEnd,
            rightStart: insStart, rightEnd: insEnd,
            kind: GroupedBlockKind.equalIgnoringWs,
            leftHighlights: _computeSideHighlights(
              selfBlob: leftBlob,
              selfLineCount: delEnd - delStart,
              otherBlob: rightBlob,
              onlyWhitespace: true,
            ),
            rightHighlights: _computeSideHighlights(
              selfBlob: rightBlob,
              selfLineCount: insEnd - insStart,
              otherBlob: leftBlob,
              onlyWhitespace: true,
            ),
          ));
        } else {
          // 真差异 → 标所有差异
          blocks.add(GroupedBlock(
            leftStart: delStart, leftEnd: delEnd,
            rightStart: insStart, rightEnd: insEnd,
            kind: GroupedBlockKind.different,
            leftHighlights: _computeSideHighlights(
              selfBlob: leftBlob,
              selfLineCount: delEnd - delStart,
              otherBlob: rightBlob,
              onlyWhitespace: false,
            ),
            rightHighlights: _computeSideHighlights(
              selfBlob: rightBlob,
              selfLineCount: insEnd - insStart,
              otherBlob: leftBlob,
              onlyWhitespace: false,
            ),
          ));
        }
      } else if (hasDel) {
        blocks.add(GroupedBlock(
          leftStart: delStart, leftEnd: delEnd,
          rightStart: insStart, rightEnd: insStart,
          kind: GroupedBlockKind.different,
          leftHighlights: List.generate(delEnd - delStart, (_) => <int>[]),
          rightHighlights: const [],
        ));
      } else if (hasIns) {
        blocks.add(GroupedBlock(
          leftStart: delStart, leftEnd: delStart,
          rightStart: insStart, rightEnd: insEnd,
          kind: GroupedBlockKind.different,
          leftHighlights: const [],
          rightHighlights: List.generate(insEnd - insStart, (_) => <int>[]),
        ));
      }
      // 都没有 = 空段，跳过

      ai = delEnd;
      bi = insEnd;
    }
  }

  // ---- 步骤 4：收尾 ----
  // 如果 diff 没覆盖到文件末尾（异常情况），补上剩余为 equal/different
  if (ai < linesA.length || bi < linesB.length) {
    _log('收尾：剩余 A=${linesA.length - ai} 行 B=${linesB.length - bi} 行');
    while (ai < linesA.length && bi < linesB.length) {
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
          leftHighlights: [_diffPositionsInLine(la, ra, onlyWhitespace: true)],
          rightHighlights: [_diffPositionsInLine(ra, la, onlyWhitespace: true)],
        ));
      } else {
        blocks.add(GroupedBlock(
          leftStart: ai, leftEnd: ai + 1,
          rightStart: bi, rightEnd: bi + 1,
          kind: GroupedBlockKind.different,
          leftHighlights: [_diffPositionsInLine(la, ra, onlyWhitespace: false)],
          rightHighlights: [_diffPositionsInLine(ra, la, onlyWhitespace: false)],
        ));
      }
      ai++;
      bi++;
    }
    while (ai < linesA.length) {
      blocks.add(GroupedBlock(
        leftStart: ai, leftEnd: ai + 1,
        rightStart: bi, rightEnd: bi,
        kind: GroupedBlockKind.different,
        leftHighlights: [const <int>[]],
        rightHighlights: const [],
      ));
      ai++;
    }
    while (bi < linesB.length) {
      blocks.add(GroupedBlock(
        leftStart: ai, leftEnd: ai,
        rightStart: bi, rightEnd: bi + 1,
        kind: GroupedBlockKind.different,
        leftHighlights: const [],
        rightHighlights: [const <int>[]],
      ));
      bi++;
    }
  }

  _log('生成块数: ${blocks.length}');
  final diffCount = blocks.where((b) => b.kind != GroupedBlockKind.equal).length;
  final sameWsCount = blocks.where((b) => b.kind == GroupedBlockKind.equalIgnoringWs).length;
  _log('  差异块=$diffCount 仅空白块=$sameWsCount');
  _log('=== computeGroupedDiff 结束 ===');

  return GroupedDiffData(linesA: linesA, linesB: linesB, blocks: blocks);
}

/// PUA 用尽时的降级：整文件标成 different。
GroupedDiffData _fallbackAllDifferent(
  List<String> linesA,
  List<String> linesB,
) {
  final blocks = <GroupedBlock>[];
  if (linesA.isNotEmpty || linesB.isNotEmpty) {
    blocks.add(GroupedBlock(
      leftStart: 0, leftEnd: linesA.length,
      rightStart: 0, rightEnd: linesB.length,
      kind: GroupedBlockKind.different,
      leftHighlights: List.generate(linesA.length, (_) => <int>[]),
      rightHighlights: List.generate(linesB.length, (_) => <int>[]),
    ));
  }
  return GroupedDiffData(linesA: linesA, linesB: linesB, blocks: blocks);
}

// ==================== 字符级高亮 ====================

/// 单行 vs 单行：本侧独有字符的位置。
List<int> _diffPositionsInLine(
  String self,
  String other, {
  required bool onlyWhitespace,
}) {
  if (self.isEmpty) return const [];
  try {
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
          if (p >= self.length) break;
          if (onlyWhitespace && !_isWhitespaceCode(self.codeUnitAt(p))) {
            continue;
          }
          result.add(p);
        }
        pos += len;
      }
      // DIFF_INSERT：对侧独有，本侧不高亮
    }
    return result;
  } catch (e) {
    _log('_diffPositionsInLine 异常: $e');
    return const [];
  }
}

/// 多行 blob vs blob：本侧独有字符的位置，按行分组。
List<List<int>> _computeSideHighlights({
  required String selfBlob,
  required int selfLineCount,
  required String otherBlob,
  required bool onlyWhitespace,
}) {
  final result = List.generate(selfLineCount, (_) => <int>[]);
  if (selfBlob.isEmpty || selfLineCount == 0) return result;

  List<Diff> diffs;
  try {
    final dmp = DiffMatchPatch();
    diffs = dmp.diff(selfBlob, otherBlob);
  } catch (e) {
    _log('_computeSideHighlights diff 异常: $e');
    return result;
  }

  // 预计算每行的起始位置和长度（不含换行）
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
        if (onlyWhitespace && !_isWhitespaceCode(selfBlob.codeUnitAt(p))) {
          continue;
        }

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
    } catch (e) {
      _log('左→右同步异常: $e');
    }
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
    } catch (e) {
      _log('右→左同步异常: $e');
    }
    _syncing = false;
  }

  @override
  Widget build(BuildContext context) {
    final a = ref.watch(preprocessedOriginalProvider);
    final b = ref.watch(preprocessedModifiedProvider);

    final key = '${a.length}|${b.length}|${a.hashCode}|${b.hashCode}';
    if (_key != key || _data == null) {
      _log('数据变化，重算。key=$key');
      _key = key;
      try {
        _data = computeGroupedDiff(a, b);
      } catch (e, st) {
        _log('computeGroupedDiff 崩溃: $e\n$st');
        _data = GroupedDiffData(
          linesA: a.split('\n'),
          linesB: b.split('\n'),
          blocks: const [],
        );
      }
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
      _log('可见块数: ${_visibleBlocks!.length}');
    }
    final visible = _visibleBlocks!;

    if (_heightTable == null ||
        _heightWidth != contentW ||
        _heightFont != fontSize) {
      try {
        _heightTable = _buildHeightTable(
          data, visible, contentW, fontSize, mq.textScaler,
        );
      } catch (e, st) {
        _log('高度表异常: $e\n$st');
        _heightTable = LineHeightTable.fromHeights(
          List<double>.filled(visible.length, 24.0),
        );
      }
      _heightWidth = contentW;
      _heightFont = fontSize;
    }

    final table = _heightTable!;
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    if (visible.isEmpty) {
      return const Center(child: Text('两份文档完全相同'));
    }

    final content = Row(
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

    if (!kGroupedDiffDebug) return content;

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
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '日志 ${kGroupedDiffLogs.length}',
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
        title: const Text('GroupedDiff 日志', style: TextStyle(fontSize: 14)),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.7,
          child: kGroupedDiffLogs.isEmpty
              ? const Center(child: Text('还没有日志'))
              : ListView.builder(
                  itemCount: kGroupedDiffLogs.length,
                  itemBuilder: (ctx, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(
                      kGroupedDiffLogs[i],
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
              kGroupedDiffLogs.clear();
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

      var acc = 0;
      for (var j = di - 1; j >= 0 && acc < contextLines; j--) {
        keep.add(j);
        acc += blocks[j].leftLength;
      }
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
    final blankH = measureTextHeight(
      text: ' ', maxWidth: width, style: style, textScaler: scaler,
    );

    for (final block in blocks) {
      double leftH = 0;
      for (var i = block.leftStart; i < block.leftEnd; i++) {
        if (i < 0 || i >= data.linesA.length) continue;
        leftH += measureTextHeight(
          text: data.linesA[i].isEmpty ? ' ' : data.linesA[i],
          maxWidth: width,
          style: style,
          textScaler: scaler,
        );
      }
      double rightH = 0;
      for (var i = block.rightStart; i < block.rightEnd; i++) {
        if (i < 0 || i >= data.linesB.length) continue;
        rightH += measureTextHeight(
          text: data.linesB[i].isEmpty ? ' ' : data.linesB[i],
          maxWidth: width,
          style: style,
          textScaler: scaler,
        );
      }
      if (leftH == 0) leftH = blankH;
      if (rightH == 0) rightH = blankH;
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
      itemExtentBuilder: (index, dimensions) {
        if (index < 0 || index >= table.length) return 24.0;
        return table.heightOf(index);
      },
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
      if (li < 0 || li >= lines.length) continue;
      final localIdx = li - startLine;
      final marks = localIdx >= 0 && localIdx < highlights.length
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

    // 空块（一侧为空）也要占位，保证高度一致。
    if (rowWidgets.isEmpty) {
      rowWidgets.add(SizedBox(
        height: bodyFontSize * 1.35,
        child: const SizedBox.shrink(),
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
        final c = _isWhitespaceCode(text.codeUnitAt(i))
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
