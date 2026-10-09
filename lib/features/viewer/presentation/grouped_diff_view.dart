// grouped_diff_view.dart

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../diff/domain/diff_operation.dart';
import '../../diff/domain/diff_result.dart';
import '../../import/presentation/providers/import_providers.dart';
import 'line_height_calculator.dart';
import 'providers/diff_viewer_providers.dart';
import 'providers/grouped_color_providers.dart';
import 'viewer_widgets.dart';

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
  double? _cacheCtxFont;
  double? _cacheGutterFont;
  bool? _cacheShowLine;
  int? _lastCtxLines;
  TextScaler? _cacheScaler;

  // 只用于文字高亮
  String _findQuery = '';

  // 当前跳到的 block（差异跳转 / 查找跳转都用它）
  int? _jumpedBlockIdx;

  // 行号缓存
  DiffResult? _metaFor;
  List<({int orig, int mod})>? _metaCache;

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

  // ==================== 给外部（主 screen）的公开方法 ====================

  /// 更新高亮词。只影响文字颜色，不做跳转。
  void updateFindQuery(String q) {
    if (_findQuery == q) return;
    setState(() => _findQuery = q);
  }

  /// 清掉查找状态。
  void clearFind() {
    if (_findQuery.isEmpty && _jumpedBlockIdx == null) return;
    setState(() {
      _findQuery = '';
      _jumpedBlockIdx = null;
    });
  }


double? _pendingRestoreOffset;

/// 返回左栏当前滚动像素位置。给主 screen 记住用。
double? get currentScrollOffset {
  if (!_leftCtrl.hasClients) return null;
  return _leftCtrl.offset;
}

/// 恢复左栏滚动位置。内容变了可能偏几行，但不会跳回开头。
void restoreScrollOffset(double offset) {
  _pendingRestoreOffset = offset;
  _tryRestoreOffset();
}

void _tryRestoreOffset() {
  final o = _pendingRestoreOffset;
  if (o == null) return;
  if (!_leftCtrl.hasClients) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tryRestoreOffset();
    });
    return;
  }
  final max = _leftCtrl.position.maxScrollExtent;
  _leftCtrl.jumpTo(o.clamp(0.0, max));
  _pendingRestoreOffset = null;
}

  
  /// 滚动到指定的 entry 索引。由主 screen 在按下"下一个/上一个"时调用。
  void scrollToEntry(int entryIdx) {
    final blockIdx = _blockIdxForEntry(entryIdx);
    if (blockIdx == null) return;
    setState(() => _jumpedBlockIdx = blockIdx);
    final off = _blockOffset(blockIdx);
    if (_leftCtrl.hasClients) {
      _leftCtrl.jumpTo(off.clamp(0, _leftCtrl.position.maxScrollExtent));
    }
  }

  // ==================== 差异跳转（工具栏按钮用）====================

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
    if (_jumpedBlockIdx != null) {
      setState(() => _jumpedBlockIdx = null);
    }
  }

  void jumpToBottom() {
    if (_leftCtrl.hasClients) {
      _leftCtrl.jumpTo(_leftCtrl.position.maxScrollExtent);
    }
    if (_jumpedBlockIdx != null) {
      setState(() => _jumpedBlockIdx = null);
    }
  }

 static const int _kLongSegThreshold = 3;   // 段长 > 3 才算"长段"

/// 返回 idx 所在差异段的起止；idx 是相同块返回 null。
({int start, int end})? _segmentAt(int idx, List<GroupedBlock> visible) {
  if (idx < 0 || idx >= visible.length) return null;
  if (visible[idx].kind == GroupedBlockKind.equal) return null;
  var start = idx;
  while (start > 0 &&
      visible[start - 1].kind != GroupedBlockKind.equal) {
    start--;
  }
  var end = idx;
  while (end + 1 < visible.length &&
      visible[end + 1].kind != GroupedBlockKind.equal) {
    end++;
  }
  return (start: start, end: end);
}

void jumpToNextDiff() {
  final visible = _visible;
  if (visible == null || !_leftCtrl.hasClients) return;
  final cur = _currentBlockIdx() ?? -1;

  int? target;
  final seg = _segmentAt(cur, visible);

  if (seg == null) {
    // 站在相同块上：找下一段段首
    var i = cur + 1;
    while (i < visible.length &&
        visible[i].kind == GroupedBlockKind.equal) {
      i++;
    }
    if (i < visible.length) target = i;
  } else {
    final len = seg.end - seg.start + 1;
    if (cur < seg.end) {
      // 段内但不在段尾：短段逐个跳，长段一次到段尾
      target = len > _kLongSegThreshold ? seg.end : cur + 1;
    } else {
      // 段尾：跳到下一段段首
      var i = seg.end + 1;
      while (i < visible.length &&
          visible[i].kind == GroupedBlockKind.equal) {
        i++;
      }
      if (i < visible.length) target = i;
    }
  }

  if (target == null) {
    _toast('到底了');
    return;
  }
  setState(() => _jumpedBlockIdx = target);
  _leftCtrl.jumpTo(
      _blockOffset(target).clamp(0, _leftCtrl.position.maxScrollExtent));
}

void jumpToPrevDiff() {
  final visible = _visible;
  if (visible == null || !_leftCtrl.hasClients) return;
  final cur = _currentBlockIdx() ?? visible.length;

  int? target;
  final seg = _segmentAt(cur, visible);

  if (seg == null) {
    var i = cur - 1;
    while (i >= 0 && visible[i].kind == GroupedBlockKind.equal) {
      i--;
    }
    if (i >= 0) {
      while (i > 0 && visible[i - 1].kind != GroupedBlockKind.equal) {
        i--;
      }
      target = i;
    }
  } else {
    final len = seg.end - seg.start + 1;
    if (cur > seg.start) {
      target = len > _kLongSegThreshold ? seg.start : cur - 1;
    } else {
      var i = seg.start - 1;
      while (i >= 0 && visible[i].kind == GroupedBlockKind.equal) {
        i--;
      }
      if (i >= 0) {
        while (i > 0 && visible[i - 1].kind != GroupedBlockKind.equal) {
          i--;
        }
        target = i;
      }
    }
  }

  if (target == null) {
    _toast('到顶了');
    return;
  }
  setState(() => _jumpedBlockIdx = target);
  _leftCtrl.jumpTo(
      _blockOffset(target).clamp(0, _leftCtrl.position.maxScrollExtent));
}

  // ==================== 内部 ====================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  double _blockOffset(int idx) {
    final visible = _visible;
    if (visible == null) return 0;
    final lineH = ref.read(bodyFontSizeProvider) * 1.1 + 2;
    double acc = 0;
    for (var i = 0; i < idx && i < visible.length; i++) {
      acc += _chunkHeights[i] ?? (visible[i].visualLength * lineH + 8);
    }
    return acc;
  }

  int? _currentBlockIdx() {
    if (!_leftCtrl.hasClients || _visible == null) return null;
    final off = _leftCtrl.offset;
    final lineH = ref.read(bodyFontSizeProvider) * 1.1 + 2;
    double acc = 0;
    for (var i = 0; i < _visible!.length; i++) {
      final h = _chunkHeights[i] ?? (_visible![i].visualLength * lineH + 8);
      if (off < acc + h) return i;
      acc += h;
    }
    return _visible!.length - 1;
  }

  /// 给定 entry 索引，找它落在哪个可见 block 里。
  int? _blockIdxForEntry(int entryIdx) {
    final diff = _dataForDiff;
    final visible = _visible;
    if (diff == null || visible == null) return null;
    if (entryIdx < 0 || entryIdx >= diff.entries.length) return null;
    final meta = _computeLineMeta(diff);
    final m = meta[entryIdx];
    // 优先看左侧行号
    if (m.orig >= 0) {
      for (var i = 0; i < visible.length; i++) {
        final b = visible[i];
        if (m.orig >= b.leftStart && m.orig < b.leftEnd) return i;
      }
    }
    // 再看右侧
    if (m.mod >= 0) {
      for (var i = 0; i < visible.length; i++) {
        final b = visible[i];
        if (m.mod >= b.rightStart && m.mod < b.rightEnd) return i;
      }
    }
    return null;
  }

  List<({int orig, int mod})> _computeLineMeta(DiffResult result) {
    if (identical(_metaFor, result) && _metaCache != null) return _metaCache!;
    final meta = <({int orig, int mod})>[];
    var o = 0, m = 0;
    for (final e in result.entries) {
      final usesOrig = e.operation == DiffOperation.equal ||
          e.operation == DiffOperation.delete ||
          e.operation == DiffOperation.replace;
      final usesMod = e.operation == DiffOperation.equal ||
          e.operation == DiffOperation.insert ||
          e.operation == DiffOperation.replace;
      meta.add((orig: usesOrig ? o : -1, mod: usesMod ? m : -1));
      if (usesOrig) o++;
      if (usesMod) m++;
    }
    _metaFor = result;
    _metaCache = meta;
    return meta;
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
    _metaFor = null;
    _metaCache = null;
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
          _metaFor = null;
          _metaCache = null;
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
      equalIgnoringWsBg: ref.watch(groupedEqualIgnoringWsBgProvider),
      wsHighlight: ref.watch(groupedWsHighlightProvider),
      findYellow: ref.watch(groupedFindYellowProvider),
      findPink: ref.watch(groupedFindPinkProvider),
    );

    final mq = MediaQuery.of(context);
    final viewportW = mq.size.width;
    final halfW = (viewportW - 1) / 2;
    final contentW = halfW - (showLine ? 42.0 : 8.0);

    if (_cacheWidth != contentW ||
        _cacheFont != bodyFs ||
        _cacheCtxFont != ctxFs ||
        _cacheGutterFont != gutterFs ||
        _cacheShowLine != showLine ||
        _cacheScaler != mq.textScaler) {
      _chunkHeights.clear();
      _cacheWidth = contentW;
      _cacheFont = bodyFs;
      _cacheCtxFont = ctxFs;
      _cacheGutterFont = gutterFs;
      _cacheShowLine = showLine;
      _cacheScaler = mq.textScaler;
    }

   final ctxLines = ref.watch(groupedContextLinesProvider).round();
if (_lastCtxLines != ctxLines) {
  _lastCtxLines = ctxLines;
  _visible = null;
  _chunkHeights.clear();
}
_visible ??= _filter(data.blocks, ctxLines);
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
          jumpedBlockIdx: _jumpedBlockIdx,
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
          jumpedBlockIdx: _jumpedBlockIdx,
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
    final style = TextStyle(fontSize: fs, height: 1.1);

    final showLine = ref.read(showLineNumbersProvider);
    final gutterFs = ref.read(gutterFontSizeProvider);
    final gutterStyle = TextStyle(fontSize: gutterFs, height: 1.1);
    final gutterH = showLine
        ? measureTextHeight(
            text: '0',
            maxWidth: 30,
            style: gutterStyle,
            textScaler: scaler,
          )
        : 0.0;

    // ★ 每行同时按常规和粗体测量，取较大值
double measureLine(String text) {
  final t = text.isEmpty ? ' ' : text;
  final h1 = measureTextHeight(
    text: t, maxWidth: width, style: style, textScaler: scaler);
  final h2 = measureTextHeight(
    text: t,
    maxWidth: width,
    style: style.copyWith(fontWeight: FontWeight.bold),
    textScaler: scaler);
  final h = h1 > h2 ? h1 : h2;
  return h > gutterH ? h : gutterH;
}

double lh = 0;
for (var i = b.leftStart; i < b.leftEnd; i++) {
  if (i < 0 || i >= data.linesA.length) continue;
  lh += measureLine(data.linesA[i]);
}
double rh = 0;
for (var i = b.rightStart; i < b.rightEnd; i++) {
  if (i < 0 || i >= data.linesB.length) continue;
  rh += measureLine(data.linesB[i]);
}

    final blank = measureTextHeight(
      text: ' ', maxWidth: width, style: style, textScaler: scaler);
    if (lh == 0) lh = blank;
    if (rh == 0) rh = blank;
    final h = (lh > rh ? lh : rh) + 8;
    _chunkHeights[blockIndex] = h;
    return h;
  }

 List<GroupedBlock> _filter(List<GroupedBlock> blocks, int ctx) {
  if (ctx <= 0) {
    // 仅差异块
    return <GroupedBlock>[
      for (final b in blocks)
        if (b.kind != GroupedBlockKind.equal) b,
    ];
  }
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
    required this.equalIgnoringWsBg,
    required this.wsHighlight,
    required this.findYellow,
    required this.findPink,
  });
  final Color diffLeftBg, diffRightBg;
  final Color charDeleteBg, charDeleteFg;
  final Color charInsertBg, charInsertFg;
  final Color equalIgnoringWsBg, wsHighlight;
  final Color findYellow, findPink;
}

enum _Side { left, right }

class _SidePane extends StatelessWidget {
  const _SidePane({
    required this.data, required this.blocks, required this.side,
    required this.controller, required this.showLineNumbers,
    required this.bodyFontSize, required this.contextFontSize,
    required this.gutterFontSize, required this.heightForBlock,
    required this.findQuery, required this.jumpedBlockIdx,
    required this.colors, required this.onLineLongPress,
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
  final int? jumpedBlockIdx;
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
            isCurrent: jumpedBlockIdx == i,
            colors: colors,
            onLineLongPress: onLineLongPress,
          ),
        );
      },
    );

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
    required this.findQuery, required this.isCurrent,
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
  final bool isCurrent;
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
    final base = TextStyle(fontSize: fs, color: fg, height: 1.1);

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
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontSize: gutterFontSize,
                    height: 1.1,
                    color: outline)),
              ),
              const SizedBox(width: 4),
            ],
            Expanded(child: Text.rich(TextSpan(children: _spans(
              lines[li], marks, base, findQuery, isCurrent, isLeft)))),
          ],
        ),
      ));
    }
    if (rows.isEmpty) rows.add(SizedBox(height: fs * 1.1));

    final body = ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );

    if (isCurrent) {
      return Container(
        foregroundDecoration: BoxDecoration(
          border: Border.all(color: Colors.black, width: 2),
        ),
        child: body,
      );
    }
    return body;
  }

  Color _bg() {
    switch (block.kind) {
      case GroupedBlockKind.equal:
        return Colors.transparent;
      case GroupedBlockKind.equalIgnoringWs:
        return colors.equalIgnoringWsBg;
      case GroupedBlockKind.different:
        return side == _Side.left ? colors.diffLeftBg : colors.diffRightBg;
    }
  }

  List<InlineSpan> _spans(
    String text, Set<int> marks, TextStyle base,
    String findQuery, bool isCurrent, bool isLeft,
  ) {
    final lineEndMarked = marks.contains(text.length);
    final innerMarks = marks.where((m) => m < text.length).toSet();
    final out = <InlineSpan>[];

    final diffCharBg = isLeft ? colors.charDeleteBg : colors.charInsertBg;
    final diffCharFg = isLeft ? colors.charDeleteFg : colors.charInsertFg;

    if (text.isEmpty) {
      out.add(TextSpan(text: ' ', style: base));
    } else if (innerMarks.isEmpty) {
      _appendWithFind(out, text, base, findQuery, isCurrent);
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
              backgroundColor:
                  isWs ? colors.wsHighlight : diffCharBg,
              color: isWs ? base.color : diffCharFg,
              fontWeight: FontWeight.bold,
            ),
          ));
        } else {
          _appendWithFind(out, chunk, base, findQuery, isCurrent);
        }
        i = j;
      }
    }

    if (lineEndMarked) {
      out.add(TextSpan(
        text: '↵',
        style: base.copyWith(
          backgroundColor: colors.wsHighlight,
          fontWeight: FontWeight.bold),
      ));
    }
    return out;
  }

  void _appendWithFind(List<InlineSpan> out, String text, TextStyle base,
      String q, bool isCurrent) {
    if (q.isEmpty || !text.contains(q)) {
      out.add(TextSpan(text: text, style: base));
      return;
    }
    final bg = isCurrent ? colors.findPink : colors.findYellow;
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
