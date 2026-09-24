import 'dart:io';

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
  /// 最近一次程序化跳转（点上一处/下一处）的时间戳。
/// 跳转后 800ms 内不让 _captureAnchor 覆盖 _currentDiffPos——
/// 因为程序化跳转用的是 alignment: 0.25，目标上方的差异还在屏幕上
/// 可见，_captureAnchor 会把位置误判回目标之前的那一处。
int _lastJumpAtMs = 0;
  int? _anchorEntryIndex;

  bool _showFind = false;
  String _findQuery = '';
  List<int> _matchEntries = const <int>[];
  int _matchPos = -1;

  bool _landscape = false;

  bool _originalDeleted = false;
  bool _modifiedDeleted = false;

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
  // 未聚焦（-1）时，第一次点“下一处”跳到第 0 处。
  // 否则从当前位置 +1，到末尾循环回 0。
  final current = _currentDiffPos < 0 ? -1 : _currentDiffPos;
  final next = (current + 1) % indices.length;
  _jumpToDiffPos(next);
}

void _jumpToPrevDiff() {
  final indices = _diffIndices();
  if (indices.isEmpty) return;
  // 未聚焦（-1）时，第一次点“上一处”跳到最后一处。
  // 否则从当前位置 -1，到开头循环回末尾。
  final current = _currentDiffPos < 0 ? 0 : _currentDiffPos;
  final prev = (current - 1 + indices.length) % indices.length;
  _jumpToDiffPos(prev);
}

void _jumpToDiffPos(int pos) {
  final indices = _diffIndices();
  if (pos < 0 || pos >= indices.length) return;
  _lastJumpAtMs = DateTime.now().millisecondsSinceEpoch;
  setState(() => _currentDiffPos = pos);
  _scrollToEntry(indices[pos]);
}

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

void _captureAnchor() {
  final anchorEntry = _findFirstVisibleDiffEntry();
  if (anchorEntry == null) return;
  _anchorEntryIndex = anchorEntry;

  // 程序化跳转后 800ms 内不更新计数器。否则点“下一处”时，目标上方
  // 仍在屏幕上可见的上一处差异会被 _captureAnchor 误判为“当前位置”，
  // 导致计数器被打回，下一次点“下一处”看起来像卡住或往回跳。
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - _lastJumpAtMs < 800) return;

  final indices = _diffIndices();
  if (indices.isEmpty) return;
  final pos = _lowerBound(indices, anchorEntry);
  if (pos >= indices.length) return;
  if (pos != _currentDiffPos) {
    setState(() => _currentDiffPos = pos);
  }
}

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

  void _openDisplaySettings() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => const _DisplaySettingsSheet(),
    );
  }

  // ---------- 删除文件 ----------

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _fmtTime(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<bool> _confirmDelete(String label, String? path) async {
    if (path == null) return false;
    int? size;
    DateTime? modified;
    try {
      final st = await File(path).stat();
      size = st.size;
      modified = st.modified;
    } catch (_) {
      // 文件可能已经不存在
    }

    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除$label？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请确认以下信息，防止删错：'),
            const SizedBox(height: 8),
            Text('路径：$path', style: Theme.of(c).textTheme.bodySmall),
            if (size != null)
              Text('大小：${_fmtSize(size)}',
                  style: Theme.of(c).textTheme.bodySmall),
            if (modified != null)
              Text('修改时间：${_fmtTime(modified)}',
                  style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 12),
            const Text(
              '删除后无法恢复。',
              style:
                  TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteSide({required bool isOriginal}) async {
    final path = ref.read(
      isOriginal ? originalFilePathProvider : modifiedFilePathProvider,
    );
    final label = isOriginal ? '原文件' : '修改版';
    final ok = await _confirmDelete(label, path);
    if (!ok || !mounted) return;

    try {
      await File(path!).delete();
      if (!mounted) return;
      setState(() {
        if (isOriginal) {
          _originalDeleted = true;
        } else {
          _modifiedDeleted = true;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label 已删除')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    }
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
          PopupMenuButton<String>(
            icon: const Icon(Icons.tune),
            tooltip: '更多操作',
            onSelected: (v) {
              if (v == 'delOriginal') {
                _deleteSide(isOriginal: true);
              } else if (v == 'delModified') {
                _deleteSide(isOriginal: false);
              } else if (v == 'orientation') {
                _toggleOrientation();
              } else if (v == 'perf') {
                final cur = ref.read(showPerfOverlayProvider);
                ref.read(showPerfOverlayProvider.notifier).state = !cur;
              } else if (v == 'syncScroll') {
                final cur = ref.read(syncScrollProvider);
                ref.read(syncScrollProvider.notifier).state = !cur;
              } else if (v == 'displaySettings') {
                _openDisplaySettings();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'delOriginal',
                enabled: !_originalDeleted &&
                    ref.read(originalFilePathProvider) != null,
                child: Row(
                  children: [
                    const Icon(Icons.delete_outline, color: Colors.red),
                    const SizedBox(width: 10),
                    Text(_originalDeleted ? '原文件已删除' : '删除原文件'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'delModified',
                enabled: !_modifiedDeleted &&
                    ref.read(modifiedFilePathProvider) != null,
                child: Row(
                  children: [
                    const Icon(Icons.delete_outline, color: Colors.red),
                    const SizedBox(width: 10),
                    Text(_modifiedDeleted ? '修改版已删除' : '删除修改版'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'displaySettings',
                child: Row(
                  children: [
                    const Icon(Icons.format_size),
                    const SizedBox(width: 10),
                    const Text('显示设置'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'syncScroll',
                child: Row(
                  children: [
                    Icon(
                      ref.watch(syncScrollProvider)
                          ? Icons.sync
                          : Icons.sync_disabled,
                    ),
                    const SizedBox(width: 10),
                    Text(ref.watch(syncScrollProvider)
                        ? '两栏同步滚动：开'
                        : '两栏同步滚动：关'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'perf',
                child: Row(
                  children: [
                    Icon(
                      ref.watch(showPerfOverlayProvider)
                          ? Icons.speed
                          : Icons.speed_outlined,
                    ),
                    const SizedBox(width: 10),
                    Text(ref.watch(showPerfOverlayProvider)
                        ? '性能面板：开'
                        : '性能面板：关'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'orientation',
                child: Row(
                  children: [
                    Icon(
                      _landscape
                          ? Icons.screen_rotation
                          : Icons.rotate_left,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Text(_landscape ? '切换到竖屏' : '切换到横屏'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_originalDeleted || _modifiedDeleted) _buildDeletedBanner(),
          _buildEncodingBanner(),
          if (_showFind) _buildFindBar(),
          DiffStatsBar(result: diff),
          if (ref.watch(showPerfOverlayProvider)) _buildPerfOverlay(),
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
                      showLineNumbers: ref.watch(showLineNumbersProvider),
                      bodyFontSize: ref.watch(bodyFontSizeProvider),
                      gutterFontSize: ref.watch(gutterFontSizeProvider),
                    ),
                  ViewMode.sideBySide => SideBySideView(
                      result: diff,
                      originalFileName: origName,
                      modifiedFileName: modName,
                      controller: _scrollController,
                      findQuery: _findQuery,
                      rowKeysByEntry: _rowKeysByEntry,
                      showLineNumbers: ref.watch(showLineNumbersProvider),
                      bodyFontSize: ref.watch(bodyFontSizeProvider),
                      gutterFontSize: ref.watch(gutterFontSizeProvider),
                      syncScroll: ref.watch(syncScrollProvider),
                    ),
                  ViewMode.diffOnly => DiffOnlyView(
                      result: diff,
                      originalFileName: origName,
                      modifiedFileName: modName,
                      controller: _scrollController,
                      findQuery: _findQuery,
                      rowKeysByEntry: _rowKeysByEntry,
                      showLineNumbers: ref.watch(showLineNumbersProvider),
                      bodyFontSize: ref.watch(bodyFontSizeProvider),
                      gutterFontSize: ref.watch(gutterFontSizeProvider),
                    ),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeletedBanner() {
    final parts = <String>[];
    if (_originalDeleted) parts.add('原文件');
    if (_modifiedDeleted) parts.add('修改版');
    return Container(
      width: double.infinity,
      color: Colors.red.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.warning_amber, size: 16, color: Colors.red.shade900),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${parts.join(" / ")} 已从磁盘删除（下方内容仅内存保留）',
              style: TextStyle(
                fontSize: 12,
                color: Colors.red.shade900,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEncodingBanner() {
    final origEnc = ref.watch(originalEncodingProvider);
    final modEnc = ref.watch(modifiedEncodingProvider);
    if (origEnc == modEnc) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: Colors.amber.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: Colors.amber.shade900),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '两份文件编码不同（$origEnc / $modEnc），已分别解码后对比',
              style: TextStyle(
                fontSize: 12,
                color: Colors.amber.shade900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerfOverlay() {
    final perf = ref.watch(lastDiffPerfProvider);
    if (perf == null) return const SizedBox.shrink();
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SelectableText(
        perf.oneLine,
        style: TextStyle(
          fontSize: 10,
          fontFamily: 'monospace',
          color: s.onTertiaryContainer,
        ),
        maxLines: 3,
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

/// 显示设置底部面板：行号显隐、正文字号、行号字号。
/// 独立顶级类，不能写在 _DiffViewerScreenState 内部。
/// 显示设置底部面板：行号显隐、正文字号、行号字号 + 12 个差异颜色。
class _DisplaySettingsSheet extends ConsumerWidget {
  const _DisplaySettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showLine = ref.watch(showLineNumbersProvider);
    final bodySize = ref.watch(bodyFontSizeProvider);
    final gutterSize = ref.watch(gutterFontSizeProvider);

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '显示设置',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示行号'),
                      value: showLine,
                      onChanged: (v) =>
                          ref.read(showLineNumbersProvider.notifier).state = v,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '正文字号：${bodySize.toStringAsFixed(0)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Slider(
                      min: 10,
                      max: 28,
                      divisions: 18,
                      value: bodySize,
                      label: bodySize.toStringAsFixed(0),
                      onChanged: (v) =>
                          ref.read(bodyFontSizeProvider.notifier).state = v,
                    ),
                    Text(
                      '行号字号：${gutterSize.toStringAsFixed(0)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Slider(
                      min: 8,
                      max: 20,
                      divisions: 12,
                      value: gutterSize,
                      label: gutterSize.toStringAsFixed(0),
                      onChanged: (v) =>
                          ref.read(gutterFontSizeProvider.notifier).state = v,
                    ),
                    const Divider(height: 32),
                    Text(
                      '差异颜色',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    _colorRow(context, ref, '纯删除行背景', deleteRowBgProvider),
                    _colorRow(context, ref, '纯删除行字体', deleteRowFgProvider),
                    _colorRow(context, ref, '纯新增行背景', insertRowBgProvider),
                    _colorRow(context, ref, '纯新增行字体', insertRowFgProvider),
                    _colorRow(context, ref, '修改行左背景', replaceLeftBgProvider),
                    _colorRow(context, ref, '修改行左字体', replaceLeftFgProvider),
                    _colorRow(context, ref, '修改行右背景', replaceRightBgProvider),
                    _colorRow(context, ref, '修改行右字体', replaceRightFgProvider),
                    _colorRow(context, ref, '字符删除背景', charDeleteBgProvider),
                    _colorRow(context, ref, '字符删除字体', charDeleteFgProvider),
                    _colorRow(context, ref, '字符新增背景', charInsertBgProvider),
                    _colorRow(context, ref, '字符新增字体', charInsertFgProvider),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _colorRow(
    BuildContext context,
    WidgetRef ref,
    String label,
    StateProvider<Color> provider,
  ) {
    final color = ref.watch(provider);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            colorToHex(color),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => _pickColor(context, ref, label, provider),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickColor(
    BuildContext context,
    WidgetRef ref,
    String label,
    StateProvider<Color> provider,
  ) async {
    final controller =
        TextEditingController(text: colorToHex(ref.read(provider)));
    String? error;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: Text(label),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '#RRGGBB',
                  errorText: error,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => error = null),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                height: 40,
                decoration: BoxDecoration(
                  color: hexToColor(controller.text) ?? ref.read(provider),
                  border: Border.all(color: Theme.of(c).colorScheme.outline),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final parsed = hexToColor(controller.text);
                if (parsed == null) {
                  setState(() => error = '格式错误，需要 #RRGGBB');
                  return;
                }
                ref.read(provider.notifier).state = parsed;
                Navigator.pop(c);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }
}
