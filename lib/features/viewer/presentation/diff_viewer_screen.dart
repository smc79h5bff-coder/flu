import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../diff/domain/diff_entry.dart';
import '../../diff/domain/diff_operation.dart';
import '../../diff/domain/diff_result.dart';
import '../../edit/presentation/edit_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import 'providers/diff_viewer_providers.dart';
import 'widgets/diff_only_view.dart';
import 'widgets/diff_stats_bar.dart';
import 'widgets/merged_view.dart';
import 'widgets/side_by_side_view.dart';

class DiffViewerScreen extends ConsumerStatefulWidget {
  const DiffViewerScreen({super.key});

  @override
  ConsumerState<DiffViewerScreen> createState() => _DiffViewerScreenState();
}

class _DiffViewerScreenState extends ConsumerState<DiffViewerScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _findController = TextEditingController();

  final Map<int, GlobalKey> _rowKeysByEntry = <int, GlobalKey>{};

  /// Position into [_diffIndices] of the currently focused diff entry.
  /// -1 = nothing focused yet (initial state).
  int _currentDiffPos = -1;

  /// 当前视口里第一个可见差异条目的 entry index（跨视图切换用）。
  int? _anchorEntryIndex;

  bool _showFind = false;
  String _findQuery = '';
  List<int> _matchEntries = const <int>[];
  int _matchPos = -1;

  bool _landscape = false;

  /// 缓存上次计算出的 diff indices，避免滚动时每帧重新扫描一遍 entries。
  /// 只在 diff 结果变化时失效。
  List<int>? _cachedDiffIndices;
  DiffResult? _cachedDiffIndicesFor;

  @override
  void dispose() {
    _findController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  DiffResult? get _diff => ref.read(diffResultProvider).value;

  void _findChanged(String q) {
    final diff = _diff;
    final matches = <int>[];
    if (q.isNotEmpty && diff != null) {
      for (var i = 0; i < diff.entries.length; i++) {
        final e = diff.entries[i];
        final hit = e.text.contains(q) ||
            (e.operation == DiffOperation.replace && e.oldText.contains(q));
        if (hit) matches.add(i);
      }
    }
    setState(() {
      _findQuery = q;
      _matchEntries = matches;
      _matchPos = matches.isEmpty ? -1 : 0;
    });
    if (matches.isNotEmpty) _scrollToEntry(matches.first);
  }

  int _renderedRows(DiffResult diff, ViewMode mode) {
    if (mode == ViewMode.merged) return diff.entries.length;
    final rows = computeAlignedRows(diff.entries);
    if (mode == ViewMode.sideBySide) return rows.length;
    var n = 0;
    for (final r in rows) {
      final delOp = r.del == null ? null : diff.entries[r.del!].operation;
      final insOp = r.ins == null ? null : diff.entries[r.ins!].operation;
      final onlyEqual = (delOp == null || delOp == DiffOperation.equal) &&
          (insOp == null || insOp == DiffOperation.equal);
      if (onlyEqual) continue;
      n++;
    }
    return n;
  }

  void _scrollToEntry(int entryIndex) {
    Future<void> locate(int round) async {
      final ctx = _rowKeysByEntry[entryIndex]?.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: 0.25,
        );
        return;
      }
      if (round > 10) return;
      final diff = _diff;
      final mode = ref.read(viewModeProvider);
      if (diff == null || !_scrollController.hasClients) return;
      final targetRow = _entryToRow(diff.entries, entryIndex, mode);
      final pos = _scrollController.position;
      final maxExtent = pos.maxScrollExtent;
      if (targetRow < 0 || maxExtent <= 0) return;
      final rowsCount = _renderedRows(diff, mode);
      if (rowsCount <= 0) return;
      final viewport = pos.viewportDimension;
      var target = maxExtent * ((targetRow + 1) / rowsCount);
      if (round > 0) {
        final curRow = pos.pixels / maxExtent * rowsCount;
        final dir = (targetRow + 0.5) >= curRow ? 1 : -1;
        target += dir * round * viewport * 0.7;
      }
      target = target.clamp(0.0, maxExtent);
      if ((pos.pixels - target).abs() < 1.0) return;
      if ((pos.pixels - target).abs() > viewport * 3) {
        pos.jumpTo(target);
      } else {
        await pos.animateTo(
          target,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeInOut,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await locate(round + 1);
    }

    locate(0);
  }

  int _entryToRow(List<DiffEntry> entries, int entryIndex, ViewMode mode) {
    if (mode == ViewMode.merged) return entryIndex;

    final rows = computeAlignedRows(entries);
    if (mode == ViewMode.sideBySide) {
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del == entryIndex || spec.ins == entryIndex) return r;
      }
      return -1;
    }
    var row = 0;
    for (final spec in rows) {
      final delOp = spec.del == null ? null : entries[spec.del!].operation;
      final insOp = spec.ins == null ? null : entries[spec.ins!].operation;
      final onlyEqual = (delOp == null || delOp == DiffOperation.equal) &&
          (insOp == null || insOp == DiffOperation.equal);
      if (onlyEqual) continue;
      if (spec.del == entryIndex || spec.ins == entryIndex) return row;
      row++;
    }
    return -1;
  }

  void _nextMatch() {
    if (_matchEntries.isEmpty) return;
    final next = (_matchPos + 1) % _matchEntries.length;
    setState(() => _matchPos = next);
    _scrollToEntry(_matchEntries[next]);
  }

  void _prevMatch() {
    if (_matchEntries.isEmpty) return;
    final prev = (_matchPos - 1 + _matchEntries.length) % _matchEntries.length;
    setState(() => _matchPos = prev);
    _scrollToEntry(_matchEntries[prev]);
  }

  void _openEdit() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const EditScreen()),
    );
  }

  /// Indices of all non-equal entries in the current diff result.
  /// 结果按 diff 对象缓存：滚动时每帧都会读这个列表，重复 O(n) 扫描会拖慢。
  List<int> _diffIndices() {
    final diff = _diff;
    if (diff == null) return const <int>[];
    if (identical(_cachedDiffIndicesFor, diff) && _cachedDiffIndices != null) {
      return _cachedDiffIndices!;
    }
    final list = <int>[
      for (var i = 0; i < diff.entries.length; i++)
        if (diff.entries[i].operation != DiffOperation.equal) i,
    ];
    _cachedDiffIndices = list;
    _cachedDiffIndicesFor = diff;
    return list;
  }

  void _ensureRowKeys() {
    for (final i in <int>{
      ..._matchEntries,
      ..._diffIndices(),
    }) {
      _rowKeysByEntry.putIfAbsent(i, () => GlobalKey());
    }
  }

  void _jumpToNextDiff() {
    final indices = _diffIndices();
    if (indices.isEmpty) return;
    // _currentDiffPos 是“上一次已知的差异序号”。用户如果手动滚动过，
    // _syncDiffPosToScroll 会把它更新到视口里的第一处差异，所以从这里
    // +1 就是“下一处”；如果从未滚动/点过，-1 → 0，跳到第一处。
    final current = _currentDiffPos < 0 ? -1 : _currentDiffPos;
    final next = (current + 1) % indices.length;
    _jumpToDiffPos(next);
  }

  void _jumpToPrevDiff() {
    final indices = _diffIndices();
    if (indices.isEmpty) return;
    // 未聚焦时视为 0，prev 会绕到最后一处；否则从当前位置 -1。
    final current = _currentDiffPos < 0 ? 0 : _currentDiffPos;
    final prev = (current - 1 + indices.length) % indices.length;
    _jumpToDiffPos(prev);
  }

  void _jumpToDiffPos(int pos) {
    final indices = _diffIndices();
    if (pos < 0 || pos >= indices.length) return;
    setState(() => _currentDiffPos = pos);
    _scrollToEntry(indices[pos]);
  }

  /// 遍历所有已登记的 GlobalKey，找到第一个还在视口里的差异条目，
  /// 记录它的 entry index 作为 anchor。
  ///
  /// 返回 entry index（不是 _currentDiffPos 里的位置），因为跨视图迁移
  /// 用的是 entry index，`_currentDiffPos` 换算要在调用方做。
  int? _findFirstVisibleDiffEntry() {
    if (_rowKeysByEntry.isEmpty) return null;
    final sorted = _rowKeysByEntry.keys.toList()..sort();
    for (final idx in sorted) {
      final ctx = _rowKeysByEntry[idx]?.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (top + box.size.height > 0) {
        return idx;
      }
    }
    return null;
  }

  /// 记录 anchor 并同步顶部“N/总数”计数器。
  ///
  /// 之前这个函数只记 anchor，`_currentDiffPos` 不动，导致用户滚动到
  /// 第 150 处时顶部还显示 1/200，且点“下一处”从过期的 0 开始 +1 → 跳到
  /// 第 1 处（“跳到文档开头”）。
  ///
  /// 现在顺手把 anchor 换算成它在 `_diffIndices()` 里的序号，写回
  /// `_currentDiffPos`。用 setState 是因为顶部计数在 AppBar 里。
  void _captureAnchor() {
    final anchorEntry = _findFirstVisibleDiffEntry();
    if (anchorEntry == null) return;
    _anchorEntryIndex = anchorEntry;

    final indices = _diffIndices();
    if (indices.isEmpty) return;
    // 目标条目可能因为当前视图过滤（equal 行在 diff-only 里不渲染）而
    // 不在 indices 里；二分/线性找到第一个 >= anchorEntry 的位置最稳。
    final pos = _lowerBound(indices, anchorEntry);
    if (pos >= indices.length) return;
    if (pos != _currentDiffPos) {
      setState(() => _currentDiffPos = pos);
    }
  }

  /// 返回 indices 里第一个 >= value 的下标（二分）。
  /// indices 单调递增，长度通常是几百到几千，二分足够。
  int _lowerBound(List<int> indices, int value) {
    var lo = 0, hi = indices.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (indices[mid] < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _switchView(ViewMode newMode) {
    final current = ref.read(viewModeProvider);
    if (current == newMode) return;
    _captureAnchor();
    final anchor = _anchorEntryIndex;
    ref.read(viewModeProvider.notifier).state = newMode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (anchor != null) {
        _scrollToEntry(anchor);
      }
    });
  }

  Future<void> _toggleOrientation() async {
    setState(() => _landscape = !_landscape);
    await SystemChrome.setPreferredOrientations(_landscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp]);
  }

  @override
  Widget build(BuildContext context) {
    final diffAsync = ref.watch(diffResultProvider);
    final viewMode = ref.watch(viewModeProvider);

    return diffAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('对比结果')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, st) => Scaffold(
        appBar: AppBar(title: const Text('对比结果')),
        body: Center(child: Text('计算差异失败：$e')),
      ),
      data: (diff) {
        final origName = ref.watch(originalFileNameProvider);
        final modName = ref.watch(modifiedFileNameProvider);
        if (diff == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('对比结果')),
            body: const Center(child: Text('请先导入两份文档')),
          );
        }
        return _buildDiffScaffold(diff, viewMode, origName, modName);
      },
    );
  }

  Widget _buildDiffScaffold(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
  ) {
    _ensureRowKeys();
    final totalDiffs = _diffIndices().length;
    final currentPos = _currentDiffPos >= 0 ? _currentDiffPos + 1 : 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('对比结果'),
        actions: [
          Center(
            key: const Key('diff-position'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '$currentPos/$totalDiffs',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
          IconButton(
            key: const Key('prev-diff'),
            icon: const Icon(Icons.arrow_upward),
            tooltip: '上一处差异',
            onPressed: _jumpToPrevDiff,
          ),
          IconButton(
            key: const Key('next-diff'),
            icon: const Icon(Icons.arrow_downward),
            tooltip: '下一处差异',
            onPressed: _jumpToNextDiff,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '查找',
            onPressed: () => setState(() => _showFind = !_showFind),
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: '编辑文档',
            onPressed: _openEdit,
          ),
          PopupMenuButton<void>(
            icon: const Icon(Icons.tune),
            tooltip: '更多操作',
            onSelected: (_) {},
            itemBuilder: (context) => [
              PopupMenuItem<void>(
                value: null,
                child: Row(
                  children: [
                    Icon(
                      _landscape ? Icons.screen_rotation : Icons.rotate_left,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Text(_landscape ? '切换到竖屏' : '切换到横屏'),
                  ],
                ),
                onTap: () {
                  Navigator.of(context).maybePop();
                  _toggleOrientation();
                },
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_showFind) _buildFindBar(),
          DiffStatsBar(result: diff),
          SegmentedButton<ViewMode>(
            segments: const [
              ButtonSegment(value: ViewMode.merged, label: Text('合并')),
              ButtonSegment(value: ViewMode.sideBySide, label: Text('并排')),
              ButtonSegment(value: ViewMode.diffOnly, label: Text('仅差异')),
            ],
            selected: {viewMode},
            onSelectionChanged: (s) => _switchView(s.first),
          ),
          Expanded(
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (_) {
                _captureAnchor();
                return false;
              },
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -300) {
                    _jumpToNextDiff();
                  } else if (velocity > 300) {
                    _jumpToPrevDiff();
                  }
                },
                child: switch (viewMode) {
                  ViewMode.merged => MergedView(
                      result: diff,
                      controller: _scrollController,
                      findQuery: _findQuery,
                      rowKeysByEntry: _rowKeysByEntry,
                    ),
                  ViewMode.sideBySide => SideBySideView(
                      result: diff,
                      originalFileName: origName,
                      modifiedFileName: modName,
                      controller: _scrollController,
                      findQuery: _findQuery,
                      rowKeysByEntry: _rowKeysByEntry,
                    ),
                  ViewMode.diffOnly => DiffOnlyView(
                      result: diff,
                      originalFileName: origName,
                      modifiedFileName: modName,
                      controller: _scrollController,
                      findQuery: _findQuery,
                      rowKeysByEntry: _rowKeysByEntry,
                    ),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFindBar() {
    final total = _matchEntries.length;
    final current = _matchPos >= 0 ? _matchPos + 1 : 0;
    return Material(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _findController.clear();
                setState(() {
                  _showFind = false;
                  _findQuery = '';
                  _matchEntries = const [];
                  _matchPos = -1;
                });
              },
            ),
            Expanded(
              child: TextField(
                controller: _findController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '输入要查找的内容',
                  isDense: true,
                  border: InputBorder.none,
                ),
                onChanged: _findChanged,
                onSubmitted: (_) => _nextMatch(),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text('$current/$total',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_upward),
              tooltip: '上一个',
              onPressed: total == 0 ? null : _prevMatch,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_downward),
              tooltip: '下一个',
              onPressed: total == 0 ? null : _nextMatch,
            ),
          ],
        ),
      ),
    );
  }
}
