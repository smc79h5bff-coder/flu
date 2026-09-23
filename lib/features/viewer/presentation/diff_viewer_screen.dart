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

  int _currentDiffPos = -1;
  int? _anchorEntryIndex;

  bool _showFind = false;
  String _findQuery = '';
  List<int> _matchEntries = const <int>[];
  int _matchPos = -1;

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

  /// 当前视图渲染出的总行数。
  /// - merged：entry 数
  /// - sideBySide / diffOnly：按块级对齐后的行数（del/ins 分组配对）
  int _renderedRows(DiffResult diff, ViewMode mode) {
    if (mode == ViewMode.merged) return diff.entries.length;
    final rows = computeAlignedRows(diff.entries);
    if (mode == ViewMode.sideBySide) return rows.length;
    // diffOnly：跳过 equal 行
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

  /// 给定 entryIndex，返回它在当前视图里渲染成第几行。
  /// 和两个视图里的布局逻辑必须保持一致，否则滚动估算会错位。
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
    // diffOnly：跳过 equal 行
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

  List<int> _diffIndices() {
    final diff = _diff;
    if (diff == null) return const <int>[];
    return <int>[
      for (var i = 0; i < diff.entries.length; i++)
        if (diff.entries[i].operation != DiffOperation.equal) i,
    ];
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
    final next = (_currentDiffPos + 1) % indices.length;
    _jumpToDiffPos(next);
  }

  void _jumpToPrevDiff() {
    final indices = _diffIndices();
    if (indices.isEmpty) return;
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

  void _captureAnchor() {
    if (_rowKeysByEntry.isEmpty) return;
    final sorted = _rowKeysByEntry.keys.toList()..sort();
    for (final idx in sorted) {
      final ctx = _rowKeysByEntry[idx]?.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (top + box.size.height > 0) {
        _anchorEntryIndex = idx;
        return;
      }
    }
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
                    Text(ref.watch(useCharEngineProvider)
                        ? '字符 diff 引擎'
                        : '行 diff 引擎'),
                  ],
                ),
                onTap: () =>
                    ref.read(useCharEngineProvider.notifier).state =
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
