// grouped_diff_view.dart

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../diff/domain/diff_operation.dart';
import '../../diff/domain/diff_result.dart';
import '../../import/presentation/providers/import_providers.dart';
import 'line_height_calculator.dart';
import 'providers/diff_viewer_providers.dart';
import 'viewer_widgets.dart';

// ==================== 固定颜色 ====================

const Color _kEqualIgnoringWsBg = Color(0xFFF7FAFF);
const Color _kWsHighlight = Color(0xFFFFD600);
const Color _kFindYellow = Color(0xFFFFF59D);
const Color _kFindPink = Color(0xFFFF4081);

const int _kMaxLinesPerChunk = 25;

// ==================== 数据模型 ====================

enum GroupedBlockKind { equal, equalIgnoringWs, different }

class GroupedBlock {
  const GroupedBlock({
    required this.leftStart,
    required this.leftEnd,
    required this.rightStart,
    required this.rightEnd,
    required this.kind,
  });
  final int leftStart, leftEnd, rightStart, rightEnd;
  final GroupedBlockKind kind;
  int get leftLength => leftEnd - leftStart;
  int get rightLength => rightEnd - rightStart;
  int get visualLength {
    final l = leftLength, r = rightLength;
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

// ==================== 算法 ====================

GroupedDiffData buildGroupedData(DiffResult diff, String a, String b) {
  final linesA = a.split('\n');
  final linesB = b.split('\n');
  final raw = <GroupedBlock>[];
  var ai = 0, bi = 0, i = 0;
  final entries = diff.entries;

  while (i < entries.length) {
    final e = entries[i];
    if (e.operation == DiffOperation.equal) {
      if (ai >= linesA.length || bi >= linesB.length) break;
      final la = linesA[ai], ra = linesB[bi];
      if (la == ra) {
        raw.add(GroupedBlock(leftStart: ai, leftEnd: ai + 1,
          rightStart: bi, rightEnd: bi + 1, kind: GroupedBlockKind.equal));
      } else if (_strip(la) == _strip(ra)) {
        raw.add(GroupedBlock(leftStart: ai, leftEnd: ai + 1,
          rightStart: bi, rightEnd: bi + 1,
          kind: GroupedBlockKind.equalIgnoringWs));
      } else {
        raw.add(GroupedBlock(leftStart: ai, leftEnd: ai + 1,
          rightStart: bi, rightEnd: bi + 1,
          kind: GroupedBlockKind.different));
      }
      ai++; bi++; i++;
    } else {
      final sA = ai, sB = bi;
      while (i < entries.length &&
          entries[i].operation != DiffOperation.equal) {
        final op = entries[i].operation;
        if (op == DiffOperation.delete || op == DiffOperation.replace) ai++;
        if (op == DiffOperation.insert || op == DiffOperation.replace) bi++;
        i++;
      }
      final eA = ai, eB = bi;
      if (eA > sA && eB > sB) {
        final lBlob = linesA.sublist(sA, eA).join('\n');
        final rBlob = linesB.sublist(sB, eB).join('\n');
        final sameWs = _strip(lBlob) == _strip(rBlob);
        raw.add(GroupedBlock(leftStart: sA, leftEnd: eA,
          rightStart: sB, rightEnd: eB,
          kind: sameWs
              ? GroupedBlockKind.equalIgnoringWs
              : GroupedBlockKind.different));
      } else if (eA > sA) {
        raw.add(GroupedBlock(leftStart: sA, leftEnd: eA,
          rightStart: sB, rightEnd: sB, kind: GroupedBlockKind.different));
      } else if (eB > sB) {
        raw.add(GroupedBlock(leftStart: sA, leftEnd: sA,
          rightStart: sB, rightEnd: eB, kind: GroupedBlockKind.different));
      }
    }
  }

  final blocks = <GroupedBlock>[];
  for (final b in raw) {
    if (b.visualLength <= _kMaxLinesPerChunk) {
      blocks.add(b);
      continue;
    }
    var l = b.leftStart, r = b.rightStart;
    while (l < b.leftEnd || r < b.rightEnd) {
      final lRem = b.leftEnd - l, rRem = b.rightEnd - r;
      final lTake = lRem > _kMaxLinesPerChunk ? _kMaxLinesPerChunk : lRem;
      final rTake = rRem > _kMaxLinesPerChunk ? _kMaxLinesPerChunk : rRem;
      blocks.add(GroupedBlock(leftStart: l, leftEnd: l + lTake,
        rightStart: r, rightEnd: r + rTake, kind: b.kind));
      l += lTake;
      r += rTake;
    }
  }
  return GroupedDiffData(linesA: linesA, linesB: linesB, blocks: blocks);
}

final Map<String, List<List<int>>> _hlCache = {};
const int _hlCacheMax = 200;

String _hlKey(String self, String other) =>
    '${self.length}:${other.length}:${self.hashCode}:${other.hashCode}';

List<List<int>> _hlCached(String selfBlob, int selfLines,
    String otherBlob, bool onlyWs) {
  final key = _hlKey(selfBlob, otherBlob) + ':$onlyWs';
  final hit = _hlCache[key];
  if (hit != null) return hit;
  if (_hlCache.length >= _hlCacheMax) {
    _hlCache.remove(_hlCache.keys.first);
  }
  final r = _blobHighlight(selfBlob, selfLines, otherBlob, onlyWs);
  _hlCache[key] = r;
  return r;
}

List<List<int>> _blobHighlight(
    String selfBlob, int selfLines, String otherBlob, bool onlyWs) {
  final r = List.generate(selfLines, (_) => <int>[]);
  if (selfBlob.isEmpty) return r;
  if (selfBlob.length > 100000 || otherBlob.length > 100000) return r;
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
            if (starts[mid] <= p) { lo = mid; } else { hi = mid - 1; }
          }
          final li = lo;
          final col = p - starts[li];
          if (li < selfLines && col <= lengths[li]) r[li].add(col);
        }
        pos += len;
      }
    }
  } catch (_) {}
  return r;
}

// ==================== 视图 ====================
class GroupedDiffView extends ConsumerStatefulWidget {
  const GroupedDiffView({super.key});

  @override
  ConsumerState<GroupedDiffView> createState() => GroupedDiffViewState();
}

class GroupedDiffViewState extends ConsumerState<GroupedDiffView> {
  late final ScrollController _leftCtrl;
  late final ScrollController _rightCtrl;
  bool _syncing = false;

  GroupedDiffData? _data;
  DiffResult? _dataForDiff;
  List<GroupedBlock>? _visible;
  final Map<int, double> _chunkHeights = {};
  double? _cacheWidth;
  double? _cacheFont;
  TextScaler? _cacheScaler;

  String _findQuery = '';
  List<({int blockIdx, bool isLeft})> _matches = const [];
  int _matchPos = -1;

  @override
  void initState() {
    super.initState();
    _leftCtrl = ScrollController();
    _rightCtrl = ScrollController();
    _leftCtrl.addListener(_syncL);
    _rightCtrl.addListener(_syncR);
  }

  @override
  void dispose() {
    _leftCtrl.removeListener(_syncL);
    _rightCtrl.removeListener(_syncR);
    _leftCtrl.dispose();
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
        _rightCtrl.position.maxScrollExtent));
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
        _leftCtrl.position.maxScrollExtent));
    } catch (_) {}
    _syncing = false;
  }

  // ==================== 公开方法 ====================

  void pageUp() {
    if (!_leftCtrl.hasClients) return;
    final p = _leftCtrl.position;
    final t = (p.pixels - p.viewportDimension * 0.95)
        .clamp(0.0, p.maxScrollExtent);
    if ((t - p.pixels).abs() < 0.5) return;
    _leftCtrl.jumpTo(t);
  }

  void pageDown() {
    if (!_leftCtrl.hasClients) return;
    final p = _leftCtrl.position;
    final t = (p.pixels + p.viewportDimension * 0.95)
        .clamp(0.0, p.maxScrollExtent);
    if ((t - p.pixels).abs() < 0.5) return;
    _leftCtrl.jumpTo(t);
  }

  void jumpToTop() {
    if (_leftCtrl.hasClients) _leftCtrl.jumpTo(0);
  }

  void jumpToBottom() {
    if (_leftCtrl.hasClients) {
      _leftCtrl.jumpTo(_leftCtrl.position.maxScrollExtent);
    }
  }

  void jumpToNextDiff() {
    final visible = _visible;
    if (visible == null || !_leftCtrl.hasClients) return;
    final cur = _currentBlockIdx() ?? -1;
    for (var i = cur + 1; i < visible.length; i++) {
      if (visible[i].kind != GroupedBlockKind.equal) {
        _leftCtrl.jumpTo(_blockOffset(i)
            .clamp(0, _leftCtrl.position.maxScrollExtent));
        return;
      }
    }
    _toast('到底了');
  }

  void jumpToPrevDiff() {
    final visible = _visible;
    if (visible == null || !_leftCtrl.hasClients) return;
    final cur = _currentBlockIdx() ?? visible.length;
    for (var i = cur - 1; i >= 0; i--) {
      if (visible[i].kind != GroupedBlockKind.equal) {
        _leftCtrl.jumpTo(_blockOffset(i)
            .clamp(0, _leftCtrl.position.maxScrollExtent));
        return;
      }
    }
    _toast('到顶了');
  }

  void updateFindQuery(String q) {
    _findQuery = q;
    final data = _data;
    final visible = _visible;
    if (data == null || visible == null || q.isEmpty) {
      setState(() { _matches = const []; _matchPos = -1; });
      return;
    }
    final list = <({int blockIdx, bool isLeft})>[];
    for (var i = 0; i < visible.length; i++) {
      final b = visible[i];
      var hitL = false;
      for (var li = b.leftStart; li < b.leftEnd; li++) {
        if (li < 0 || li >= data.linesA.length) continue;
        if (data.linesA[li].contains(q)) { hitL = true; break; }
      }
      if (hitL) list.add((blockIdx: i, isLeft: true));
      var hitR = false;
      for (var li = b.rightStart; li < b.rightEnd; li++) {
        if (li < 0 || li >= data.linesB.length) continue;
        if (data.linesB[li].contains(q)) { hitR = true; break; }
      }
      if (hitR) list.add((blockIdx: i, isLeft: false));
    }
    setState(() {
      _matches = list;
      _matchPos = list.isEmpty ? -1 : 0;
    });
    if (list.isNotEmpty) _scrollToMatch(0);
  }

  void nextMatch() {
    if (_matches.isEmpty) return;
    setState(() => _matchPos = (_matchPos + 1) % _matches.length);
    _scrollToMatch(_matchPos);
  }

  void prevMatch() {
    if (_matches.isEmpty) return;
    setState(() => _matchPos = (_matchPos - 1 + _matches.length) % _matches.length);
    _scrollToMatch(_matchPos);
  }

  void clearFind() {
    _findQuery = '';
    setState(() { _matches = const []; _matchPos = -1; });
  }

  // ==================== 内部 ====================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  double _blockOffset(int idx) {
    final visible = _visible;
    if (visible == null) return 0;
    final lineH = ref.read(bodyFontSizeProvider) * 1.35 + 2;
    double acc = 0;
    for (var i = 0; i < idx && i < visible.length; i++) {
      acc += _chunkHeights[i] ?? (visible[i].visualLength * lineH + 8);
    }
    return acc;
  }

  int? _currentBlockIdx() {
    if (!_leftCtrl.hasClients || _visible == null) return null;
    final off = _leftCtrl.offset;
    final lineH = ref.read(bodyFontSizeProvider) * 1.35 + 2;
    double acc = 0;
    for (var i = 0; i < _visible!.length; i++) {
      final h = _chunkHeights[i] ?? (_visible![i].visualLength * lineH + 8);
      if (off < acc + h) return i;
      acc += h;
    }
    return _visible!.length - 1;
  }

  void _scrollToMatch(int idx) {
    if (idx < 0 || idx >= _matches.length) return;
    final off = _blockOffset(_matches[idx].blockIdx);
    if (_leftCtrl.hasClients) {
      _leftCtrl.jumpTo(off.clamp(0, _leftCtrl.position.maxScrollExtent));
    }
  }

  Future<void> _onLineLongPress(int lineIdx, bool isLeft) async {
    final provider = isLeft
        ? preprocessedOriginalProvider
        : preprocessedModifiedProvider;
    final current = ref.read(provider);
    if (current.isEmpty) return;
    final lines = current.split('\n');
    if (lineIdx < 0 || lineIdx >= lines.length) return;

    final ctrl = TextEditingController(text: lines[lineIdx]);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: Text('编辑第 ${lineIdx + 1} 行（${isLeft ? "左" : "右"}）',
            style: const TextStyle(fontSize: 14)),
        content: TextField(
          controller: ctrl,
          maxLines: null,
          autofocus: true,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    lines[lineIdx] = ctrl.text;
    final newText = lines.join('\n');
    if (isLeft) {
      ref.read(editedOriginalProvider.notifier).state = newText;
    } else {
      ref.read(editedModifiedProvider.notifier).state = newText;
    }
    ref.read(importRevisionProvider.notifier).state++;
    _dataForDiff = null;
    if (mounted) setState(() {});
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
          _chunkHeights.clear();
        }
        return _buildBody(_data!);
      },
    );
  }

  Widget _buildBody(GroupedDiffData data) {
    final showLine = ref.watch(showLineNumbersProvider);
    final bodyFs = ref.watch(bodyFontSizeProvider);
    final gutterFs = ref.watch(gutterFontSizeProvider);
    final ctxFs = ref.watch(contextFontSizeProvider);

    final colors = _Colors(
      diffLeftBg: ref.watch(replaceLeftBgProvider),
      diffRightBg: ref.watch(replaceRightBgProvider),
      charDeleteBg: ref.watch(charDeleteBgProvider),
      charDeleteFg: ref.watch(charDeleteFgProvider),
      charInsertBg: ref.watch(charInsertBgProvider),
      charInsertFg: ref.watch(charInsertFgProvider),
    );

    final mq = MediaQuery.of(context);
    final viewportW = mq.size.width;
    final halfW = (viewportW - 1) / 2;
    final contentW = halfW - (showLine ? 42.0 : 8.0);

    if (_cacheWidth != contentW ||
        _cacheFont != bodyFs ||
        _cacheScaler != mq.textScaler) {
      _chunkHeights.clear();
      _cacheWidth = contentW;
      _cacheFont = bodyFs;
      _cacheScaler = mq.textScaler;
    }

    _visible ??= _filter(data.blocks);
    final visible = _visible!;
    if (visible.isEmpty) {
      return const Center(child: Text('两份文档完全相同'));
    }

    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    return Row(
      children: [
        Expanded(child: _SidePane(
          data: data, blocks: visible, side: _Side.left,
          controller: _leftCtrl, showLineNumbers: showLine,
          bodyFontSize: bodyFs, contextFontSize: ctxFs,
          gutterFontSize: gutterFs,
          heightForBlock: _heightForBlock,
          findQuery: _findQuery,
          currentMatchBlock: _matchPos >= 0 && _matchPos < _matches.length
              ? _matches[_matchPos].blockIdx : null,
          currentMatchIsLeft: _matchPos >= 0 && _matchPos < _matches.length
              ? _matches[_matchPos].isLeft : null,
          colors: colors,
          onLineLongPress: _onLineLongPress,
        )),
        divider,
        Expanded(child: _SidePane(
          data: data, blocks: visible, side: _Side.right,
          controller: _rightCtrl, showLineNumbers: showLine,
          bodyFontSize: bodyFs, contextFontSize: ctxFs,
          gutterFontSize: gutterFs,
          heightForBlock: _heightForBlock,
          findQuery: _findQuery,
          currentMatchBlock: _matchPos >= 0 && _matchPos < _matches.length
              ? _matches[_matchPos].blockIdx : null,
          currentMatchIsLeft: _matchPos >= 0 && _matchPos < _matches.length
              ? _matches[_matchPos].isLeft : null,
          colors: colors,
          onLineLongPress: _onLineLongPress,
        )),
      ],
    );
  }

  double _heightForBlock(int blockIndex) {
    final cached = _chunkHeights[blockIndex];
    if (cached != null) return cached;
    final visible = _visible;
    final data = _data;
    if (visible == null || data == null ||
        blockIndex < 0 || blockIndex >= visible.length) return 24.0;

    final b = visible[blockIndex];
    final isContext = b.kind == GroupedBlockKind.equal;
    final fs = isContext
        ? ref.read(contextFontSizeProvider)
        : ref.read(bodyFontSizeProvider);
    final width = _cacheWidth ?? 100.0;
    final scaler = _cacheScaler ?? TextScaler.noScaling;
    final style = TextStyle(fontSize: fs, height: 1.35);

    double lh = 0;
    for (var i = b.leftStart; i < b.leftEnd; i++) {
      if (i < 0 || i >= data.linesA.length) continue;
      lh += measureTextHeight(
        text: data.linesA[i].isEmpty ? ' ' : data.linesA[i],
        maxWidth: width, style: style, textScaler: scaler);
    }
    double rh = 0;
    for (var i = b.rightStart; i < b.rightEnd; i++) {
      if (i < 0 || i >= data.linesB.length) continue;
      rh += measureTextHeight(
        text: data.linesB[i].isEmpty ? ' ' : data.linesB[i],
        maxWidth: width, style: style, textScaler: scaler);
    }
    final blank = measureTextHeight(
      text: ' ', maxWidth: width, style: style, textScaler: scaler);
    if (lh == 0) lh = blank;
    if (rh == 0) rh = blank;
    final h = (lh > rh ? lh : rh) + 8;
    _chunkHeights[blockIndex] = h;
    return h;
  }

  List<GroupedBlock> _filter(List<GroupedBlock> blocks) {
    const ctx = 2;
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
}

class _Colors {
  const _Colors({
    required this.diffLeftBg,
    required this.diffRightBg,
    required this.charDeleteBg,
    required this.charDeleteFg,
    required this.charInsertBg,
    required this.charInsertFg,
  });
  final Color diffLeftBg, diffRightBg;
  final Color charDeleteBg, charDeleteFg;
  final Color charInsertBg, charInsertFg;
}

enum _Side { left, right }

class _SidePane extends StatelessWidget {
  const _SidePane({
    required this.data, required this.blocks, required this.side,
    required this.controller, required this.showLineNumbers,
    required this.bodyFontSize, required this.contextFontSize,
    required this.gutterFontSize, required this.heightForBlock,
    required this.findQuery, required this.currentMatchBlock,
    required this.currentMatchIsLeft, required this.colors,
    required this.onLineLongPress,
  });

  final GroupedDiffData data;
  final List<GroupedBlock> blocks;
  final _Side side;
  final ScrollController? controller;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double contextFontSize;
  final double gutterFontSize;
  final double Function(int) heightForBlock;
  final String findQuery;
  final int? currentMatchBlock;
  final bool? currentMatchIsLeft;
  final _Colors colors;
  final void Function(int lineIdx, bool isLeft) onLineLongPress;

  @override
  Widget build(BuildContext context) {
    final list = ListView.builder(
      controller: controller,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      cacheExtent: 300,
      itemCount: blocks.length,
      itemBuilder: (ctx, i) {
        final h = heightForBlock(i);
        return SizedBox(
          height: h,
          child: _BlockTile(
            block: blocks[i], data: data, side: side,
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            contextFontSize: contextFontSize,
            gutterFontSize: gutterFontSize,
            findQuery: findQuery,
            isCurrentMatch: currentMatchBlock == i &&
                currentMatchIsLeft == (side == _Side.left),
            colors: colors,
            onLineLongPress: onLineLongPress,
          ),
        );
      },
    );

    // 右栏加滚动条，跟"仅差异视图"一样
    if (side == _Side.right) {
      return buildViewerScrollbar(child: list, controller: controller);
    }
    return list;
  }
}

class _BlockTile extends StatelessWidget {
  const _BlockTile({
    required this.block, required this.data, required this.side,
    required this.showLineNumbers, required this.bodyFontSize,
    required this.contextFontSize, required this.gutterFontSize,
    required this.findQuery, required this.isCurrentMatch,
    required this.colors, required this.onLineLongPress,
  });

  final GroupedBlock block;
  final GroupedDiffData data;
  final _Side side;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double contextFontSize;
  final double gutterFontSize;
  final String findQuery;
  final bool isCurrentMatch;
  final _Colors colors;
  final void Function(int lineIdx, bool isLeft) onLineLongPress;

  @override
  Widget build(BuildContext context) {
    final isLeft = side == _Side.left;
    final start = isLeft ? block.leftStart : block.rightStart;
    final end = isLeft ? block.leftEnd : block.rightEnd;
    final lines = isLeft ? data.linesA : data.linesB;
    final otherLines = isLeft ? data.linesB : data.linesA;
    final otherStart = isLeft ? block.rightStart : block.leftStart;
    final otherEnd = isLeft ? block.rightEnd : block.leftEnd;

    List<List<int>> hi;
    if (block.kind == GroupedBlockKind.equal || end <= start) {
      hi = List.generate(end - start, (_) => <int>[], growable: false);
    } else {
      final selfBlob = lines.sublist(start, end).join('\n');
      final otherBlob = otherLines.sublist(otherStart, otherEnd).join('\n');
      final onlyWs = block.kind == GroupedBlockKind.equalIgnoringWs;
      hi = _hlCached(selfBlob, end - start, otherBlob, onlyWs);
    }

    final isContext = block.kind == GroupedBlockKind.equal;
    final fs = isContext ? contextFontSize : bodyFontSize;
    final bg = _bg();
    final fg = Theme.of(context).textTheme.bodyMedium?.color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white : Colors.black);
    final outline = Theme.of(context).colorScheme.outline;
    final base = TextStyle(fontSize: fs, color: fg, height: 1.35);

    final rows = <Widget>[];
    for (var li = start; li < end; li++) {
      if (li < 0 || li >= lines.length) continue;
      final local = li - start;
      final marks = local >= 0 && local < hi.length
          ? hi[local].toSet() : <int>{};
      rows.add(GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => onLineLongPress(li, isLeft),
        child: Row(
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
            Expanded(child: Text.rich(TextSpan(children: _spans(
              lines[li], marks, base, findQuery, isCurrentMatch, isLeft)))),
          ],
        ),
      ));
    }
    if (rows.isEmpty) rows.add(SizedBox(height: fs * 1.35));

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
        return side == _Side.left ? colors.diffLeftBg : colors.diffRightBg;
    }
  }

  List<InlineSpan> _spans(
    String text, Set<int> marks, TextStyle base,
    String findQuery, bool isCurrentMatch, bool isLeft,
  ) {
    final lineEndMarked = marks.contains(text.length);
    final innerMarks = marks.where((m) => m < text.length).toSet();
    final out = <InlineSpan>[];

    final diffCharBg = isLeft ? colors.charDeleteBg : colors.charInsertBg;
    final diffCharFg = isLeft ? colors.charDeleteFg : colors.charInsertFg;

    if (text.isEmpty) {
      out.add(TextSpan(text: ' ', style: base));
    } else if (innerMarks.isEmpty) {
      _appendWithFind(out, text, base, findQuery, isCurrentMatch);
    } else {
      var i = 0;
      while (i < text.length) {
        final marked = innerMarks.contains(i);
        var j = i;
        while (j < text.length && innerMarks.contains(j) == marked) j++;
        final chunk = text.substring(i, j);
        if (marked) {
          final isWs = _isWs(text.codeUnitAt(i));
          out.add(TextSpan(
            text: chunk,
            style: base.copyWith(
              backgroundColor: isWs ? _kWsHighlight : diffCharBg,
              color: isWs ? base.color : diffCharFg,
              fontWeight: FontWeight.bold,
            ),
          ));
        } else {
          _appendWithFind(out, chunk, base, findQuery, isCurrentMatch);
        }
        i = j;
      }
    }

    if (lineEndMarked) {
      out.add(TextSpan(
        text: '↵',
        style: base.copyWith(
          backgroundColor: _kWsHighlight, fontWeight: FontWeight.bold),
      ));
    }
    return out;
  }

  void _appendWithFind(List<InlineSpan> out, String text, TextStyle base,
      String q, bool isCurrentMatch) {
    if (q.isEmpty || !text.contains(q)) {
      out.add(TextSpan(text: text, style: base));
      return;
    }
    final bg = isCurrentMatch ? _kFindPink : _kFindYellow;
    var s = 0;
    int idx;
    while ((idx = text.indexOf(q, s)) != -1) {
      if (idx > s) out.add(TextSpan(text: text.substring(s, idx), style: base));
      out.add(TextSpan(text: q, style: base.copyWith(
        backgroundColor: bg, fontWeight: FontWeight.bold)));
      s = idx + q.length;
    }
    if (s < text.length) {
      out.add(TextSpan(text: text.substring(s), style: base));
    }
  }
}
