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

/// Diff viewer — switches between merged / side-by-side / diff-only views
/// and offers jump-to-diff gestures (PRD §2 Module 6 + §4.2 手势操作:
/// "左右滑 → 跳转上一处/下一处差异").
class DiffViewerScreen extends ConsumerStatefulWidget {
  const DiffViewerScreen({super.key});

  @override
  ConsumerState<DiffViewerScreen> createState() => _DiffViewerScreenState();
}

class _DiffViewerScreenState extends ConsumerState<DiffViewerScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _findController = TextEditingController();

  /// Per-entry GlobalKeys (keyed by diff-entry index) enabling precise
  /// scroll-to via [Scrollable.ensureVisible]. Only created for rows that are
  /// search matches or diffs, so the count stays small even for huge files.
  final Map<int, GlobalKey> _rowKeysByEntry = <int, GlobalKey>{};

  /// Position into [_diffIndices] of the currently focused diff entry.
  int _currentDiffPos = -1;

  /// 当前视口里第一个可见差异条目的 entry index。
  /// 用于跨视图切换时把位置“迁移”到新视图的同一处差异。
  /// null 表示还没捕获过（首次进入）。
  int? _anchorEntryIndex;

  // ---- 查找状态 ----
  bool _showFind = false;
  String _findQuery = '';
  List<int> _matchEntries = const <int>[];
  int _matchPos = -1;

  // ---- 横屏切换 ----
  bool _landscape = false;

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
        // 替换行同时查新文本（右侧）与旧文本（左侧），保证两侧命中都能跳转。
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

  /// 当前视图渲染出的总行数（合并=条目数；并排/仅差异=合并 delete+insert 后的行数）。
  int _renderedRows(DiffResult diff, ViewMode mode) {
    var n = 0;
    for (var j = 0; j < diff.entries.length; j++) {
      final e = diff.entries[j];
      if (mode == ViewMode.diffOnly && e.operation == DiffOperation.equal) {
        continue;
      }
      if (j + 1 < diff.entries.length &&
          e.operation == DiffOperation.delete &&
          diff.entries[j + 1].operation == DiffOperation.insert) {
        j++; // 合并行
      }
      n++;
    }
    return n;
  }

  /// 查找/差异跳转：
  /// 1) 目标行已构建 → [Scrollable.ensureVisible] 精确定位；
  /// 2) 未构建 → 先按“行占比 × 总高度”估算滚到目标附近，若仍未被构建则
  ///    沿目标方向每轮推进大半个视口（双向收敛），直到目标行进入构建窗口
  ///    再 ensureVisible 校正。
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
      if (round > 10) return; // 兜底，避免死循环
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
      // 首轮：按目标行占比估算（最接近真实位置）。
      var target = maxExtent * ((targetRow + 1) / rowsCount);
      if (round > 0) {
        // 估算不足/过头：沿目标方向每轮推进大半个视口，直到目标行被构建。
        final curRow = pos.pixels / maxExtent * rowsCount;
        final dir = (targetRow + 0.5) >= curRow ? 1 : -1;
        target += dir * round * viewport * 0.7;
      }
      target = target.clamp(0.0, maxExtent);
      if ((pos.pixels - target).abs() < 1.0) return;
      if ((pos.pixels - target).abs() > viewport * 3) {
        pos.jumpTo(target); // 大距离瞬移
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

  /// Returns the row index that [entryIndex] occupies in the given view mode.
  int _entryToRow(List<DiffEntry> entries, int entryIndex, ViewMode mode) {
    if (mode == ViewMode.merged) return entryIndex;
    final skipEqual = mode == ViewMode.diffOnly;
    var row = 0;
    for (var j = 0; j < entries.length; j++) {
      final e = entries[j];
      if (skipEqual && e.operation == DiffOperation.equal) continue;
      final isDel = e.operation == DiffOperation.delete;
      final nextIsIns = j + 1 < entries.length &&
          entries[j + 1].operation == DiffOperation.insert;
      if (isDel && nextIsIns) {
        if (j == entryIndex || j + 1 == entryIndex) return row;
        j++; // consume the following insert
      } else {
        if (j == entryIndex) return row;
      }
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
  List<int> _diffIndices() {
    final diff = _diff;
    if (diff == null) return const <int>[];
    return <int>[
      for (var i = 0; i < diff.entries.length; i++)
        if (diff.entries[i].operation != DiffOperation.equal) i,
    ];
  }

  /// Create a GlobalKey for every row that can be jumped to (search matches
  /// + diff entries), so [Scrollable.ensureVisible] can scroll to it exactly.
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
    // Initial state (-1) → first diff. Otherwise wraps to first when at end.
    final next = (_currentDiffPos + 1) % indices.length;
    _jumpToDiffPos(next);
  }

  void _jumpToPrevDiff() {
    final indices = _diffIndices();
    if (indices.isEmpty) return;
    // Treat unfocused (-1) as 0 so prev wraps to the last diff.
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

  /// 记录当前视口里第一个可见差异条目的 entry index。
  /// 由 ScrollEndNotification 触发（滚动停止后一次），也用于切换视图前。
  ///
  /// 找法：遍历所有差异条目的 GlobalKey，取“底部 > 0”的第一个（即第一个
  /// 还未完全滚出视口顶部的条目）。这对应视口里的第一处差异。
  void _captureAnchor() {
    if (_rowKeysByEntry.isEmpty) return;
    final sorted = _rowKeysByEntry.keys.toList()..sort();
    for (final idx in sorted) {
      final ctx = _rowKeysByEntry[idx]?.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      // 相对屏幕的顶部位置 + 高度：如果底部 >= 0，说明还没完全滚出去。
      final top = box.localToGlobal(Offset.zero).dy;
      if (top + box.size.height > 0) {
        _anchorEntryIndex = idx;
        return;
      }
    }
  }

  /// 切换到新视图，并把位置迁移到同一处差异。
  ///
  /// 流程：
  /// 1. 记录旧视图里的 anchor entry index。
  /// 2. setState 切换 viewMode。
  /// 3. 下一帧在新视图里 `_scrollToEntry(anchor)`。
  ///
  /// 用 addPostFrameCallback 是因为新视图的 ListView 必须完成 build 之后
  /// ScrollController 才有 position，否则 _scrollToEntry 的第一轮会被
  /// “hasClients == false” 挡掉。
  void _switchView(ViewMode newMode) {
    final current = ref.read(viewModeProvider);
    if (current == newMode) return;
    _captureAnchor();
    final anchor = _anchorEntryIndex;
    ref.read(viewModeProvider.notifier).state = newMode;
    // 让新视图先完成一次 build，再迁移位置。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (anchor != null) {
        _scrollToEntry(anchor);
      }
    });
  }

  /// Toggles between forced portrait and forced landscape.
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
              PopupMenuItem<void>(
                value: null,
                child: Row(
                  children: [
                    Icon(
                      ref.watch(useCharEngineProvider)
                          ? Icons.science_outlined
                          : Icons.straighten,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Text(ref.watch(useCharEngineProvider) ? '字符 diff 引擎' : '行 diff 引擎'),
                  ],
                ),
                onTap: () => ref.read(useCharEngineProvider.notifier).state =
                    !ref.read(useCharEngineProvider),
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
            // 改用 _switchView：切换前捕获 anchor，切完后在新视图里迁移位置。
            onSelectionChanged: (s) => _switchView(s.first),
          ),
          Expanded(
            // 滚动停止后捕获 anchor，供下次视图切换使用。
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

  /// 查找输入栏。
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
