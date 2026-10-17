// grouped_diff_view.dart
//
// 跨行块视图。
//
// 架构：
//   - 渲染：单个 ListView，每个 item 是 Row（左右各一个 _BlockTile），高度由内容自然撑开。
//          不裁切、不留块间空白、左右天然对齐。
//   - 跳转定位：单独维护一张"块高缓存" _chunkHeights（后台异步填充），供 _blockOffset /
//          _currentBlockIdx 使用。跳转是 O(1) 读缓存，不会因为索引大而变慢或闪退。

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/debug/crash_logger.dart';
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
        raw.add(GroupedBlock(
            leftStart: ai, leftEnd: ai + 1,
            rightStart: bi, rightEnd: bi + 1,
            kind: GroupedBlockKind.equal));
      } else if (_strip(la) == _strip(ra)) {
        raw.add(GroupedBlock(
            leftStart: ai, leftEnd: ai + 1,
            rightStart: bi, rightEnd: bi + 1,
            kind: GroupedBlockKind.equalIgnoringWs));
      } else {
        raw.add(GroupedBlock(
            leftStart: ai, leftEnd: ai + 1,
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

// ==================== 字符级高亮（含 LRU 缓存） ====================

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
  if (selfBlob.length > 20000 || otherBlob.length > 20000) return r;
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
  late final ScrollController _ctrl;

  GroupedDiffData? _data;
  DiffResult? _dataForDiff;
  List<GroupedBlock>? _visible;

  // ★ 块高缓存（供跳转定位用）。后台异步填充。
  final Map<int, double> _chunkHeights = {};

  // 字符级高亮缓存（供渲染用）。后台异步填充。key = "blockIdx:L" 或 "blockIdx:R"
  final Map<String, List<List<int>>> _highlightsCache = {};

  // 任务队列
  final Set<int> _pendingHeights = {};
  final Set<String> _pendingHighlights = {};
  bool _processing = false;

  // 最近 build 过的块索引（用于任务优先级）
  final Set<int> _recentlyVisible = {};

  // 短文件结束提示（块索引）
  int? _shortFileLastBlockIdx;
  DiffResult? _shortFileLastBlockIdxFor;
  int? _shortFileLastBlockIdxCtxLines;
  bool _shortIsLeft = true;

  // 缓存失效用
  bool? _cacheShowLine;
  double? _cacheBodyFont;
  double? _cacheCtxFont;
  double? _cacheGutterFont;
  TextScaler? _cacheScaler;
  double? _cacheContentWidth;
  int? _lastCtxLines;

  String _findQuery = '';
  int? _jumpedBlockIdx;

  DiffResult? _metaFor;
  List<({int orig, int mod})>? _metaCache;

  double? _pendingRestoreOffset;
  int _restoreAttempts = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = ScrollController();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _pendingHeights.clear();
    _pendingHighlights.clear();
    _highlightsCache.clear();
    _hlCache.clear();
    super.dispose();
  }

  // ==================== 给外部（主 screen）的公开方法 ====================

  void updateFindQuery(String q) {
    if (_findQuery == q) return;
    setState(() => _findQuery = q);
  }

  void clearFind() {
    if (_findQuery.isEmpty && _jumpedBlockIdx == null) return;
    setState(() {
      _findQuery = '';
      _jumpedBlockIdx = null;
    });
  }

  double? get currentScrollOffset {
    if (!_ctrl.hasClients) return null;
    return _ctrl.offset;
  }

  void restoreScrollOffset(double offset) {
    _pendingRestoreOffset = offset;
    _restoreAttempts = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tryRestoreOffset();
    });
  }

  void _tryRestoreOffset() {
    if (_pendingRestoreOffset == null) {
      final fromProvider = ref.read(groupedRestoreOffsetProvider);
      if (fromProvider != null) {
        _pendingRestoreOffset = fromProvider;
        ref.read(groupedRestoreOffsetProvider.notifier).state = null;
        _restoreAttempts = 0;
      }
    }

    final o = _pendingRestoreOffset;
    if (o == null) return;

    if (_restoreAttempts >= 120) {
      _pendingRestoreOffset = null;
      _restoreAttempts = 0;
      return;
    }

    final latest = ref.read(diffResultProvider).value;
    if (latest == null || !identical(_dataForDiff, latest)) {
      _restoreAttempts++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tryRestoreOffset();
      });
      return;
    }

    if (!_ctrl.hasClients) {
      _restoreAttempts++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tryRestoreOffset();
      });
      return;
    }

    final max = _ctrl.position.maxScrollExtent;
    if (max < o) {
      _restoreAttempts++;
      if (_restoreAttempts >= 120) {
        _ctrl.jumpTo(max);
        _pendingRestoreOffset = null;
        _restoreAttempts = 0;
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tryRestoreOffset();
      });
      return;
    }

    _ctrl.jumpTo(o.clamp(0.0, max));
    _pendingRestoreOffset = null;
    _restoreAttempts = 0;
  }

  bool scrollToEntry(int entryIdx) {
    final blockIdx = _blockIdxForEntry(entryIdx);
    if (blockIdx == null) return false;
    setState(() => _jumpedBlockIdx = blockIdx);
    _jumpToBlockAnimated(blockIdx);
    return true;
  }

  // ==================== 差异跳转 ====================

  void pageUp() {
    if (!_ctrl.hasClients) return;
    final p = _ctrl.position;
    final t = (p.pixels - p.viewportDimension * 0.95)
        .clamp(0.0, p.maxScrollExtent);
    if ((t - p.pixels).abs() < 0.5) return;
    _ctrl.jumpTo(t);
  }

  void pageDown() {
    if (!_ctrl.hasClients) return;
    final p = _ctrl.position;
    final t = (p.pixels + p.viewportDimension * 0.95)
        .clamp(0.0, p.maxScrollExtent);
    if ((t - p.pixels).abs() < 0.5) return;
    _ctrl.jumpTo(t);
  }

  void jumpToTop() {
    CrashLogger.instance.mark('grouped: 跳到第一个差异块');
    if (!_ctrl.hasClients) return;
    final visible = _visible;
    if (visible == null || visible.isEmpty) {
      _ctrl.jumpTo(0);
      return;
    }
    for (var i = 0; i < visible.length; i++) {
      if (visible[i].kind != GroupedBlockKind.equal) {
        setState(() => _jumpedBlockIdx = i);
        _jumpToBlockAnimated(i);
        return;
      }
    }
    _ctrl.jumpTo(0);
    if (_jumpedBlockIdx != null) {
      setState(() => _jumpedBlockIdx = null);
    }
  }

  void jumpToBottom() {
  CrashLogger.instance.mark('grouped: 跳到最后一个差异块');
  if (!_ctrl.hasClients) return;
  final visible = _visible;
  if (visible == null || visible.isEmpty) {
    _ctrl.jumpTo(_ctrl.position.maxScrollExtent);
    return;
  }
  for (var i = visible.length - 1; i >= 0; i--) {
    if (visible[i].kind != GroupedBlockKind.equal) {
      setState(() => _jumpedBlockIdx = i);
      // 不迭代逼近，直接跳到列表最底。
      // 视图里最后一个可见块就是最后一个差异块（+ 上下文），
      // 所以列表最底就是目标位置，且不会触发 _currentBlockIdx 的 O(N) 遍历。
      _ctrl.jumpTo(_ctrl.position.maxScrollExtent);
      return;
    }
  }
  _ctrl.jumpTo(_ctrl.position.maxScrollExtent);
  if (_jumpedBlockIdx != null) {
    setState(() => _jumpedBlockIdx = null);
  }
}

  /// 迭代逼近到目标块。缓存命中时每轮 O(1)，通常 2~4 轮收敛。
  Future<void> _jumpToBlockAnimated(int targetIdx) async {
    if (!mounted) return;
    if (!_ctrl.hasClients) return;

    for (var attempt = 0; attempt < 8; attempt++) {
      if (!mounted || !_ctrl.hasClients) return;

      final max = _ctrl.position.maxScrollExtent;
      final off = _blockOffset(targetIdx).clamp(0.0, max);
      _ctrl.jumpTo(off);

      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      final cur = _currentBlockIdx();
      if (cur == null) return;
      if (cur == targetIdx || (cur - targetIdx).abs() <= 1) return;
    }
  }

  static const int _kLongSegThreshold = 3;

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
    if (visible == null || !_ctrl.hasClients) return;
    final cur = _currentBlockIdx() ?? -1;

    int? target;

    final noEqual = !visible.any((b) => b.kind == GroupedBlockKind.equal);
    if (noEqual) {
      target = cur < visible.length - 1 ? cur + 1 : null;
    } else {
      final seg = _segmentAt(cur, visible);
      if (seg == null) {
        var i = cur + 1;
        while (i < visible.length &&
            visible[i].kind == GroupedBlockKind.equal) {
          i++;
        }
        if (i < visible.length) target = i;
      } else {
        final len = seg.end - seg.start + 1;
        if (cur < seg.end) {
          target = len > _kLongSegThreshold ? seg.end : cur + 1;
        } else {
          var i = seg.end + 1;
          while (i < visible.length &&
              visible[i].kind == GroupedBlockKind.equal) {
            i++;
          }
          if (i < visible.length) target = i;
        }
      }
    }

    if (target == null) {
      _toast('到底了');
      return;
    }
    setState(() => _jumpedBlockIdx = target);
    _jumpToBlockAnimated(target);
  }

  void jumpToPrevDiff() {
    final visible = _visible;
    if (visible == null || !_ctrl.hasClients) return;
    final cur = _currentBlockIdx() ?? visible.length;

    int? target;

    final noEqual = !visible.any((b) => b.kind == GroupedBlockKind.equal);
    if (noEqual) {
      target = cur > 0 ? cur - 1 : null;
    } else {
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
    }

    if (target == null) {
      _toast('到顶了');
      return;
    }
    setState(() => _jumpedBlockIdx = target);
    _jumpToBlockAnimated(target);
  }

  // ==================== 内部 ====================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 块高缓存的查询：优先精确缓存，缺失时用粗估。
  double _heightOf(int idx) {
    final visible = _visible;
    if (visible == null || idx < 0 || idx >= visible.length) return 24.0;
    final cached = _chunkHeights[idx];
    if (cached != null) return cached;
    return _estimateBlockHeight(visible[idx]);
  }

  /// 大 idx 时避免 O(N) 遍历：前 N 块采样取平均，乘以 idx。
  double _blockOffset(int idx) {
    final visible = _visible;
    if (visible == null || idx <= 0) return 0;

    const int sampleLimit = 200;
    if (idx > sampleLimit) {
      // 前 100 块采样
      double sum = 0;
      int n = 0;
      const int sampleSize = 100;
      for (var i = 0; i < sampleSize && i < visible.length; i++) {
        sum += _heightOf(i);
        n++;
      }
      final avg = n > 0 ? sum / n : 24.0;
      return avg * idx;
    }

    double acc = 0;
    for (var i = 0; i < idx && i < visible.length; i++) {
      acc += _heightOf(i);
    }
    return acc;
  }

  int? _currentBlockIdx() {
    if (!_ctrl.hasClients || _visible == null) return null;
    final off = _ctrl.offset;
    final visible = _visible!;

    // 大文件时用平均高度跳过前面
    if (visible.length > 400) {
      double sum = 0;
      int n = 0;
      const int sampleSize = 100;
      for (var i = 0; i < sampleSize && i < visible.length; i++) {
        sum += _heightOf(i);
        n++;
      }
      final avg = n > 0 ? sum / n : 24.0;
      final guess = (off / avg).floor();
      final startIdx = guess.clamp(0, visible.length - 1);

      double acc = avg * startIdx;
      // 从前一格开始精调
      final from = (startIdx - 2).clamp(0, visible.length - 1);
      acc = 0;
      // 重新精确累加（从 0 到 from 用平均估，从 from 开始精算）
      acc = avg * from;
      for (var i = from; i < visible.length; i++) {
        final h = _heightOf(i);
        if (off < acc + h) return i;
        acc += h;
      }
      return visible.length - 1;
    }

    double acc = 0;
    for (var i = 0; i < visible.length; i++) {
      final h = _heightOf(i);
      if (off < acc + h) return i;
      acc += h;
    }
    return visible.length - 1;
  }

  int? _blockIdxForEntry(int entryIdx) {
    final diff = _dataForDiff;
    final visible = _visible;
    if (diff == null || visible == null) return null;
    if (entryIdx < 0 || entryIdx >= diff.entries.length) return null;
    final meta = _computeLineMeta(diff);
    final m = meta[entryIdx];
    if (m.orig >= 0) {
      for (var i = 0; i < visible.length; i++) {
        final b = visible[i];
        if (m.orig >= b.leftStart && m.orig < b.leftEnd) return i;
      }
    }
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

  /// 计算"短文件最后一行"所在的可视 block 索引。
  /// 两个文件行数差距 < 100 时不提示（返回 null）。
  int? _computeShortFileEndBlockIdx(GroupedDiffData data) {
    if (data.linesA.isEmpty || data.linesB.isEmpty) return null;
    final lenA = data.linesA.length;
    final lenB = data.linesB.length;
    if (lenA == lenB) return null;
    const int minDiff = 100;
    if ((lenA - lenB).abs() < minDiff) return null;

    final shortIsLeft = lenA < lenB;
    _shortIsLeft = shortIsLeft;
    final shortLineCount = shortIsLeft ? lenA : lenB;
    final visible = _visible;
    if (visible == null || visible.isEmpty) return null;

    for (var i = visible.length - 1; i >= 0; i--) {
      final b = visible[i];
      final blockStart = shortIsLeft ? b.leftStart : b.rightStart;
      if (blockStart < shortLineCount) {
        return i;
      }
    }
    return visible.length - 1;
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

  // ==================== 构建 ====================

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
          CrashLogger.instance
              .mark('[restore] 新数据到达 pending=$_pendingRestoreOffset');
          _dataForDiff = diff;
          _data = buildGroupedData(diff, a, b);
          _visible = null;
          _chunkHeights.clear();
          _highlightsCache.clear();
          _pendingHeights.clear();
          _pendingHighlights.clear();
          _recentlyVisible.clear();
          _shortFileLastBlockIdx = null;
          _shortFileLastBlockIdxFor = null;
          _shortFileLastBlockIdxCtxLines = null;
          _metaFor = null;
          _metaCache = null;

          _restoreAttempts = 0;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _tryRestoreOffset();
          });
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
    final textScaler = MediaQuery.of(context).textScaler;

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
    final contentW = halfW - (showLine ? 36.0 : 2.0);

    if (_cacheShowLine != showLine ||
        _cacheBodyFont != bodyFs ||
        _cacheCtxFont != ctxFs ||
        _cacheGutterFont != gutterFs ||
        _cacheScaler != textScaler ||
        _cacheContentWidth != contentW) {
      _chunkHeights.clear();
      _highlightsCache.clear();
      _pendingHeights.clear();
      _pendingHighlights.clear();
      _recentlyVisible.clear();
      _cacheShowLine = showLine;
      _cacheBodyFont = bodyFs;
      _cacheCtxFont = ctxFs;
      _cacheGutterFont = gutterFs;
      _cacheScaler = textScaler;
      _cacheContentWidth = contentW;
    }

    final ctxLines = ref.watch(groupedContextLinesProvider).round();
    if (_lastCtxLines != ctxLines) {
      _lastCtxLines = ctxLines;
      _visible = null;
      _chunkHeights.clear();
      _highlightsCache.clear();
      _pendingHeights.clear();
      _pendingHighlights.clear();
      _recentlyVisible.clear();
    }
    _visible ??= _filter(data.blocks, ctxLines);
    final visible = _visible!;
    if (visible.isEmpty) {
      return const Center(child: Text('两份文档完全相同'));
    }

    // 短文件结束提示位置
    if (!identical(_shortFileLastBlockIdxFor, _dataForDiff) ||
        _shortFileLastBlockIdxCtxLines != ctxLines) {
      _shortFileLastBlockIdx = _computeShortFileEndBlockIdx(data);
      _shortFileLastBlockIdxFor = _dataForDiff;
      _shortFileLastBlockIdxCtxLines = ctxLines;
    }

    final shortLineCount =
        _shortIsLeft ? data.linesA.length : data.linesB.length;

    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    final listView = ListView.builder(
      controller: _ctrl,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      cacheExtent: 100,
      itemCount: visible.length,
      itemBuilder: (ctx, i) {
        final b = visible[i];

        // ★ 触发块高计算（供跳转定位用，不影响本 item 的渲染高度）
        _heightForBlock(i);

        final showMarkLeft =
            _shortIsLeft && _shortFileLastBlockIdx == i;
        final showMarkRight =
            !_shortIsLeft && _shortFileLastBlockIdx == i;

        final afterShortEndLeft = _shortIsLeft &&
            _shortFileLastBlockIdx != null &&
            b.leftStart >= shortLineCount;
        final afterShortEndRight = !_shortIsLeft &&
            _shortFileLastBlockIdx != null &&
            b.rightStart >= shortLineCount;

        final isCurrent = _jumpedBlockIdx == i;

        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _BlockTile(
                  block: b, data: data, side: _Side.left,
                  showLineNumbers: showLine,
                  bodyFontSize: bodyFs,
                  contextFontSize: ctxFs,
                  gutterFontSize: gutterFs,
                  findQuery: _findQuery,
                  isCurrent: isCurrent,
                  highlights: _getHighlightOrNull(i, _Side.left),
                  showShortEndMark: showMarkLeft,
                  afterShortEnd: afterShortEndLeft,
                  colors: colors,
                  onLineLongPress: _onLineLongPress,
                ),
              ),
              divider,
              Expanded(
                child: _BlockTile(
                  block: b, data: data, side: _Side.right,
                  showLineNumbers: showLine,
                  bodyFontSize: bodyFs,
                  contextFontSize: ctxFs,
                  gutterFontSize: gutterFs,
                  findQuery: _findQuery,
                  isCurrent: isCurrent,
                  highlights: _getHighlightOrNull(i, _Side.right),
                  showShortEndMark: showMarkRight,
                  afterShortEnd: afterShortEndRight,
                  colors: colors,
                  onLineLongPress: _onLineLongPress,
                ),
              ),
            ],
          ),
        );
      },
    );

    return buildViewerScrollbar(child: listView, controller: _ctrl);
  }

  // ==================== 块高计算（供跳转定位） ====================

  void _heightForBlock(int blockIndex) {
    if (_recentlyVisible.length > 300) _recentlyVisible.clear();
    _recentlyVisible.add(blockIndex);

    if (_chunkHeights.containsKey(blockIndex)) return;
    if (_pendingHeights.contains(blockIndex)) return;
    _pendingHeights.add(blockIndex);
    _scheduleProcess();
  }

  /// 粗估一个块的渲染高度。仅作为精确高度算出来之前的占位。
  double _estimateBlockHeight(GroupedBlock b) {
    final data = _data;
    if (data == null) return 24.0;
    final isContext = b.kind == GroupedBlockKind.equal;
    final fs = isContext
        ? ref.read(contextFontSizeProvider)
        : ref.read(bodyFontSizeProvider);
    final strutH = fs * 1.1;
    final contentW = _cacheContentWidth ?? 100.0;

    double estimateLines(List<String> lines, int start, int end) {
      var acc = 0.0;
      for (var i = start; i < end; i++) {
        if (i < 0 || i >= lines.length) continue;
        final t = lines[i];
        if (t.isEmpty) {
          acc += 1;
          continue;
        }
        double w = 0;
        for (final code in t.runes) {
          w += code < 128 ? fs * 0.6 : fs;
        }
        final rows = (w / contentW).ceil();
        acc += rows < 1 ? 1 : rows;
      }
      return acc;
    }

    final leftN = estimateLines(data.linesA, b.leftStart, b.leftEnd);
    final rightN = estimateLines(data.linesB, b.rightStart, b.rightEnd);
    final n = leftN > rightN ? leftN : rightN;
    return n * strutH + 8;
  }

  /// 精确计算一个块的渲染高度（用 TextPainter 逐行量）。
  double _computeHeight(int blockIndex) {
    final visible = _visible;
    final data = _data;
    if (visible == null || data == null ||
        blockIndex < 0 || blockIndex >= visible.length) return 24.0;

    final b = visible[blockIndex];
    final isContext = b.kind == GroupedBlockKind.equal;
    final fs = isContext
        ? ref.read(contextFontSizeProvider)
        : ref.read(bodyFontSizeProvider);
    final width = _cacheContentWidth ?? 100.0;
    final scaler = _cacheScaler ?? TextScaler.noScaling;
    final style = TextStyle(fontSize: fs, height: 1.1);
    final strut = StrutStyle(
      fontSize: fs,
      height: 1.1,
      forceStrutHeight: true,
    );

    final showLine = ref.read(showLineNumbersProvider);
    final gutterFs = ref.read(gutterFontSizeProvider);
    final gutterStyle = TextStyle(fontSize: gutterFs, height: 1.1);
    final gutterStrut = StrutStyle(
      fontSize: gutterFs,
      height: 1.1,
      forceStrutHeight: true,
    );
    final gutterH = showLine
        ? measureTextHeight(
            text: '0',
            maxWidth: 30,
            style: gutterStyle,
            textScaler: scaler,
            strutStyle: gutterStrut,
          )
        : 0.0;

    double measureLine(String text) {
      final t = text.isEmpty ? ' ' : text;
      final h = measureTextHeight(
        text: t,
        maxWidth: width,
        style: style,
        textScaler: scaler,
        strutStyle: strut,
      );
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
      text: ' ', maxWidth: width, style: style, textScaler: scaler,
      strutStyle: strut);
    if (lh == 0) lh = blank;
    if (rh == 0) rh = blank;
    return (lh > rh ? lh : rh) + 8;
  }

  // ==================== 高亮 + 块高 异步计算 ====================

  List<List<int>>? _getHighlightOrNull(int blockIndex, _Side side) {
    if (_recentlyVisible.length > 300) _recentlyVisible.clear();
    _recentlyVisible.add(blockIndex);

    final key = _hlKeyFor(blockIndex, side);
    final cached = _highlightsCache[key];
    if (cached != null) return cached;
    if (!_pendingHighlights.contains(key)) {
      _pendingHighlights.add(key);
      _scheduleProcess();
    }
    return null;
  }

  String _hlKeyFor(int blockIndex, _Side side) =>
      '$blockIndex:${side == _Side.left ? "L" : "R"}';

  List<List<int>> _computeHighlight(int blockIndex, _Side side) {
    final visible = _visible;
    final data = _data;
    if (visible == null || data == null ||
        blockIndex < 0 || blockIndex >= visible.length) {
      return const [];
    }
    final b = visible[blockIndex];
    final isLeft = side == _Side.left;
    final start = isLeft ? b.leftStart : b.rightStart;
    final end = isLeft ? b.leftEnd : b.rightEnd;
    final lines = isLeft ? data.linesA : data.linesB;
    final otherLines = isLeft ? data.linesB : data.linesA;
    final otherStart = isLeft ? b.rightStart : b.leftStart;
    final otherEnd = isLeft ? b.rightEnd : b.leftEnd;

    if (b.kind == GroupedBlockKind.equal || end <= start) {
      return List.generate(end - start, (_) => <int>[], growable: false);
    }
    final selfBlob = lines.sublist(start, end).join('\n');
    final otherBlob = otherLines.sublist(otherStart, otherEnd).join('\n');
    final onlyWs = b.kind == GroupedBlockKind.equalIgnoringWs;
    return _hlCached(selfBlob, end - start, otherBlob, onlyWs);
  }

  void _scheduleProcess() {
    if (_processing) return;
    _processing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _processOne());
  }

  void _processOne() {
    if (!mounted) {
      _processing = false;
      return;
    }

    // 每帧最多处理 4 个任务
    const int budget = 4;
    var processed = 0;

    while (processed < budget) {
      bool didWork = false;

      // 优先块高（跳转要用），其次高亮
      if (_pendingHeights.isNotEmpty) {
        int? target;
        for (final i in _recentlyVisible) {
          if (_pendingHeights.contains(i)) {
            target = i;
            break;
          }
        }
        target ??= _pendingHeights.first;

        _pendingHeights.remove(target);
        try {
          _chunkHeights[target] = _computeHeight(target);
          didWork = true;
        } catch (_) {}
      } else if (_pendingHighlights.isNotEmpty) {
        String? target;
        for (final i in _recentlyVisible) {
          for (final suffix in const ['L', 'R']) {
            final k = '$i:$suffix';
            if (_pendingHighlights.contains(k)) {
              target = k;
              break;
            }
          }
          if (target != null) break;
        }
        target ??= _pendingHighlights.first;

        _pendingHighlights.remove(target);
        try {
          final parts = target.split(':');
          final idx = int.parse(parts[0]);
          final side = parts[1] == 'L' ? _Side.left : _Side.right;
          _highlightsCache[target] = _computeHighlight(idx, side);
          didWork = true;
        } catch (_) {}
      } else {
        break;
      }

      if (!didWork) break;
      processed++;
    }

    if (processed > 0 && mounted) {
      setState(() {});
    }

    if (_pendingHeights.isNotEmpty || _pendingHighlights.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _processOne());
    } else {
      _processing = false;
    }
  }

  List<GroupedBlock> _filter(List<GroupedBlock> blocks, int ctx) {
    if (ctx <= 0) {
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

// ==================== 颜色配置 ====================

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

// ==================== 单侧块渲染 ====================

class _BlockTile extends StatelessWidget {
  const _BlockTile({
    required this.block, required this.data, required this.side,
    required this.showLineNumbers, required this.bodyFontSize,
    required this.contextFontSize, required this.gutterFontSize,
    required this.findQuery, required this.isCurrent,
    required this.highlights,
    required this.showShortEndMark,
    required this.afterShortEnd,
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
  final List<List<int>>? highlights;
  final bool showShortEndMark;
  final bool afterShortEnd;
  final _Colors colors;
  final void Function(int lineIdx, bool isLeft) onLineLongPress;

  @override
  Widget build(BuildContext context) {
    final isLeft = side == _Side.left;
    final start = isLeft ? block.leftStart : block.rightStart;
    final end = isLeft ? block.leftEnd : block.rightEnd;
    final lines = isLeft ? data.linesA : data.linesB;

    final hi = highlights ??
        List.generate(end - start, (_) => <int>[], growable: false);

    final isContext = block.kind == GroupedBlockKind.equal;
    final fs = isContext ? contextFontSize : bodyFontSize;
    final bg = afterShortEnd ? const Color(0xFF1C1C1C) : _bg();
    final defaultFg = Theme.of(context).textTheme.bodyMedium?.color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white : Colors.black);
    final fg = afterShortEnd ? const Color(0xFFB0B0B0) : defaultFg;
    final outline = afterShortEnd
        ? const Color(0xFF606060)
        : Theme.of(context).colorScheme.outline;
    final base = TextStyle(fontSize: fs, color: fg, height: 1.1);

    final bodyStrut = StrutStyle(
      fontSize: fs,
      height: 1.1,
      forceStrutHeight: true,
    );
    final gutterStrut = StrutStyle(
      fontSize: gutterFontSize,
      height: 1.1,
      forceStrutHeight: true,
    );

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
                  strutStyle: gutterStrut,
                  style: TextStyle(
                    fontSize: gutterFontSize,
                    height: 1.1,
                    color: outline)),
              ),
              const SizedBox(width: 4),
            ],
            Expanded(child: Text.rich(
              TextSpan(children: _spans(
                lines[li], marks, base, findQuery, isCurrent, isLeft)),
              strutStyle: bodyStrut,
            )),
          ],
        ),
      ));
    }
    if (rows.isEmpty) rows.add(SizedBox(height: fs * 1.1));

    final content = ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );

    final Widget body = showShortEndMark
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              content,
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: const [
                  _WarningBar(color: Color(0xFFFF0000), label: '短文件到此结束，下方仅为长文件独有内容'),
                  _WarningBar(color: Color(0xFFFF8700), label: '短文件到此结束，下方仅为长文件独有内容'),
                  _WarningBar(color: Color(0xFFF9FF00), label: '短文件到此结束，下方仅为长文件独有内容'),
                  _WarningBar(color: Color(0xFF00FF27), label: '短文件到此结束，下方仅为长文件独有内容'),
                  _WarningBar(color: Color(0xFF00F3FF), label: '短文件到此结束，下方仅为长文件独有内容'),
                  _WarningBar(color: Color(0xFF0037FF), label: '短文件到此结束，下方仅为长文件独有内容'),
                  _WarningBar(color: Color(0xFF9C00FF), label: '短文件到此结束，下方仅为长文件独有内容'),
                  _WarningBar(color: Color(0xFFFF50DE), label: '短文件到此结束，下方仅为长文件独有内容'),
                ],
              ),
            ],
          )
        : content;

    if (isCurrent) {
      return Container(
        foregroundDecoration: BoxDecoration(
          border: Border.all(
            color: afterShortEnd ? const Color(0xFF606060) : Colors.black,
            width: 2,
          ),
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

class _WarningBar extends StatelessWidget {
  const _WarningBar({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 18,
      color: color,
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: Colors.white,
          fontWeight: FontWeight.w700,
          shadows: [Shadow(blurRadius: 2, color: Colors.black)],
        ),
      ),
    );
  }
}
