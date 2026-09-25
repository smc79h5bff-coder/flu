import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart'
    hide colorToHex, hexToColor;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/persistent_notifier.dart';
import '../../diff/application/diff_cache.dart';
import '../../diff/domain/diff_entry.dart';
import '../../diff/domain/diff_operation.dart';
import '../../diff/domain/diff_result.dart';
import '../../edit/presentation/edit_screen.dart';
import '../../file_browser/presentation/comparison_settings_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import 'diff_scroll_helper.dart';
import 'diff_text_index.dart';
import 'providers/diff_viewer_providers.dart';
import 'regex_help_screen.dart';
import 'widgets/diff_only_view.dart';
import 'widgets/merged_view.dart';
import 'widgets/side_by_side_view.dart';

class DiffViewerScreen extends ConsumerStatefulWidget {
  const DiffViewerScreen({super.key});

  @override
  ConsumerState<DiffViewerScreen> createState() => _DiffViewerScreenState();
}

/// 切视图时用户选择的跳转目标。
enum _SwitchTarget { match, top, anchor }

class _DiffViewerScreenState extends ConsumerState<DiffViewerScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();

  final Map<int, GlobalKey> _rowKeysByEntry = <int, GlobalKey>{};

  int _currentDiffPos = -1;

  /// 最近一次程序化跳转（点上一处/下一处）的时间戳。
  int _lastJumpAtMs = 0;
  int? _anchorEntryIndex;

  bool _showFind = false;
  String _findQuery = '';
  List<int> _matchEntries = const <int>[];
  int _matchPos = -1;

  // 查找/替换的高级选项
  bool _regexEnable = false;
  bool _caseInsensitive = false;
  bool _wholeWord = false;
  bool _searchLeft = true;
  bool _searchRight = true;

  // 未应用的替换缓存：key = 预处理后的行号，value = 新的整行文本
  final Map<int, String> _pendingOrigChanges = <int, String>{};
  final Map<int, String> _pendingModChanges = <int, String>{};

  bool _landscape = false;

  bool _originalDeleted = false;
  bool _modifiedDeleted = false;

  List<int>? _cachedDiffIndices;
  DiffResult? _cachedDiffIndicesFor;

  /// 滚动结束防抖定时器。
  Timer? _captureTimer;

  /// 查找输入防抖：用户连续打字时只在停顿后触发一次全量扫描。
  Timer? _findDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(viewModeProvider.notifier).state = ViewMode.diffOnly;
    });
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _findDebounce?.cancel();
    _findController.dispose();
    _replaceController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  DiffResult? get _diff => ref.read(diffResultProvider).value;

  /// 当前停留的匹配项对应的 entry 下标。
  int? get _currentMatchEntry {
    if (_matchEntries.isEmpty) return null;
    if (_matchPos < 0 || _matchPos >= _matchEntries.length) return null;
    return _matchEntries[_matchPos];
  }

  // ==================== 查找 / 替换基础逻辑 ====================

  Pattern _buildFindPattern() {
    final q = _findQuery;
    if (q.isEmpty) return RegExp(r'(?!)');
    var src = _regexEnable ? q : RegExp.escape(q);
    if (_wholeWord) src = r'\b' + src + r'\b';
    try {
      return RegExp(src, caseSensitive: !_caseInsensitive, multiLine: true);
    } catch (_) {
      return RegExp(r'(?!)');
    }
  }

  String _expandReplacement(String tpl, Match m) {
    final out = StringBuffer();
    final re = RegExp(r'\$(\d+)');
    var last = 0;
    for (final match in re.allMatches(tpl)) {
      out.write(tpl.substring(last, match.start));
      final idx = int.parse(match.group(1)!);
      out.write(m.group(idx) ?? '');
      last = match.end;
    }
    out.write(tpl.substring(last));
    return out.toString();
  }

  String _applyReplace(String text, String replacement) {
    final p = _buildFindPattern();
    if (_regexEnable) {
      return text.replaceAllMapped(p, (m) => _expandReplacement(replacement, m));
    }
    return text.replaceAll(p, replacement);
  }

  bool _entryMatchesOnLeft(DiffEntry e) {
    if (!_searchLeft) return false;
    if (e.operation == DiffOperation.insert) return false;
    return true;
  }

  bool _entryMatchesOnRight(DiffEntry e) {
    if (!_searchRight) return false;
    if (e.operation == DiffOperation.delete) return false;
    return true;
  }

  String _entryLeftText(DiffEntry e) {
    if (e.operation == DiffOperation.replace && e.oldText.isNotEmpty) {
      return e.oldText;
    }
    return e.text;
  }

  String _entryRightText(DiffEntry e) {
    if (e.operation == DiffOperation.replace && e.newText.isNotEmpty) {
      return e.newText;
    }
    return e.text;
  }

  /// 查找框输入变化：先防抖，用户停顿 250ms 后再做全量扫描。
  /// 避免每敲一个键就 O(n) 扫一遍所有 entry，大文件下会掉帧。
  void _onFindInput(String q) {
    _findDebounce?.cancel();
    _findDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _findChanged(q);
    });
  }

  /// 立即执行一次查找。防抖外的调用点（切换左右、切正则等）直接走它。
  void _findChanged(String q, {bool autoScroll = true}) {
    _findQuery = q;
    final diff = _diff;
    final matches = <int>[];
    if (q.isNotEmpty && diff != null) {
      final p = _buildFindPattern();
      // 仅差异视图只统计非 equal 行，保证命中的一定是屏幕上能看见的。
      final diffOnly = ref.read(viewModeProvider) == ViewMode.diffOnly;
      for (var i = 0; i < diff.entries.length; i++) {
        final e = diff.entries[i];
        if (diffOnly && e.operation == DiffOperation.equal) continue;
        var hit = false;
        if (_entryMatchesOnLeft(e) &&
            p.allMatches(_entryLeftText(e)).isNotEmpty) {
          hit = true;
        }
        if (!hit &&
            _entryMatchesOnRight(e) &&
            p.allMatches(_entryRightText(e)).isNotEmpty) {
          hit = true;
        }
        if (hit) matches.add(i);
      }
    }
    setState(() {
      _matchEntries = matches;
      _matchPos = matches.isEmpty ? -1 : 0;
    });
    if (autoScroll && matches.isNotEmpty) _scrollToEntry(matches.first);
  }

  /// 如果防抖还在计时，说明用户还没停手；此时如果用户点了“下一个/上一个/替换”，
  /// 要先把最新的输入立即搜一遍，避免用到过期的 `_matchEntries`。
  void _ensureFindApplied() {
    if (_findDebounce?.isActive ?? false) {
      _findDebounce!.cancel();
      _findChanged(_findController.text, autoScroll: false);
    }
  }

  // ==================== 替换 ====================

  void _replaceCurrentInline() {
    _ensureFindApplied();
    if (_findQuery.isEmpty || _matchEntries.isEmpty || _matchPos < 0) {
      _toast('没有可替换的内容');
      return;
    }
    _doReplace(replacement: _replaceController.text, all: false);
  }

  void _replaceAllInline() {
    _ensureFindApplied();
    if (_findQuery.isEmpty || _matchEntries.isEmpty) {
      _toast('没有可替换的内容');
      return;
    }
    _doReplace(replacement: _replaceController.text, all: true);
  }

  void _doReplace({required String replacement, required bool all}) {
    final diff = _diff;
    if (diff == null) return;

    final targets = all
        ? _matchEntries
        : (_matchPos >= 0 && _matchPos < _matchEntries.length
            ? <int>[_matchEntries[_matchPos]]
            : const <int>[]);
    if (targets.isEmpty) {
      _toast('没有可替换的内容');
      return;
    }

    final meta = _computeLineMeta(diff);
    final p = _buildFindPattern();
    var count = 0;

    for (final ei in targets) {
      final e = diff.entries[ei];

      if (_entryMatchesOnLeft(e) && meta[ei].orig >= 0) {
        final origLine = meta[ei].orig;
        final current = _pendingOrigChanges[origLine] ?? _entryLeftText(e);
        if (p.allMatches(current).isNotEmpty) {
          _pendingOrigChanges[origLine] = _applyReplace(current, replacement);
          count++;
        }
      }

      if (_entryMatchesOnRight(e) && meta[ei].mod >= 0) {
        final modLine = meta[ei].mod;
        final current = _pendingModChanges[modLine] ?? _entryRightText(e);
        if (p.allMatches(current).isNotEmpty) {
          _pendingModChanges[modLine] = _applyReplace(current, replacement);
          count++;
        }
      }
    }

    if (count == 0) {
      _toast('没有可替换的内容');
      return;
    }

    setState(() {});
    _toast('已加入待应用队列（$count 处）· 点"应用并刷新"生效');
  }

  void _applyPendingChanges() {
    if (_pendingOrigChanges.isEmpty && _pendingModChanges.isEmpty) return;

    _applyRawChanges(isOriginal: true, changes: _pendingOrigChanges);
    _applyRawChanges(isOriginal: false, changes: _pendingModChanges);
    _pendingOrigChanges.clear();
    _pendingModChanges.clear();

    ref.read(importRevisionProvider.notifier).state++;
    _resetViewAfterEdit();
    _toast('已应用替换');
  }

  void _applyRawChanges({
    required bool isOriginal,
    required Map<int, String> changes,
  }) {
    if (changes.isEmpty) return;
    final raw = ref.read(
      isOriginal ? originalRawTextProvider : modifiedRawTextProvider,
    );
    if (raw == null) return;

    final lines =
        raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

    for (final entry in changes.entries) {
      final rawLine = rawLineForNormalizedLine(
        raw,
        normalizedLine: entry.key,
        ignoreWhitespace: ref.read(ignoreWhitespaceProvider),
        ignoreEmptyLines: ref.read(ignoreEmptyLinesProvider),
        ignoreInvisible: ref.read(ignoreInvisibleProvider),
      );
      if (rawLine == null) continue;
      if (rawLine < 0 || rawLine >= lines.length) continue;
      lines[rawLine] = entry.value;
    }

    final newRaw = lines.join('\n');
    if (isOriginal) {
      ref.read(originalRawTextProvider.notifier).state = newRaw;
    } else {
      ref.read(modifiedRawTextProvider.notifier).state = newRaw;
    }
  }

  Future<void> _closeFindBar() async {
    if (_pendingOrigChanges.isNotEmpty || _pendingModChanges.isNotEmpty) {
      if (!mounted) return;
      final n = _pendingOrigChanges.length + _pendingModChanges.length;
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('有未应用的替换'),
          content: Text('有 $n 处修改还没应用，怎么处理？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, 'cancel'),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, 'discard'),
              child: const Text('放弃'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, 'apply'),
              child: const Text('应用并关闭'),
            ),
          ],
        ),
      );
      if (choice == 'cancel' || choice == null) return;
      if (choice == 'apply') {
        _applyPendingChanges();
      } else {
        _pendingOrigChanges.clear();
        _pendingModChanges.clear();
      }
    }

    if (!mounted) return;
    _findDebounce?.cancel();
    _findController.clear();
    _replaceController.clear();
    setState(() {
      _showFind = false;
      _findQuery = '';
      _matchEntries = const [];
      _matchPos = -1;
    });
  }

  // ==================== 滚动 / 跳转 ====================

  int _renderedRows(DiffResult diff, ViewMode mode) {
    if (mode == ViewMode.merged) return diff.entries.length;
    final rows = cachedAlignedRows(diff);
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
    final diff = _diff;
    if (diff == null) return;
    final mode = ref.read(viewModeProvider);

    final helper = DiffScrollHelper(
      scrollController: _scrollController,
      rowKeysByEntry: _rowKeysByEntry,
      totalRows: () => _renderedRows(diff, mode),
      entryToRow: (ei) => _entryToRow(diff, ei, mode),
    );
    helper.scrollToEntry(entryIndex);
  }

  int _entryToRow(DiffResult diff, int entryIndex, ViewMode mode) {
    if (mode == ViewMode.merged) return entryIndex;

    final rows = cachedAlignedRows(diff);
    if (mode == ViewMode.sideBySide) {
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del == entryIndex || spec.ins == entryIndex) return r;
      }
      return -1;
    }
    var row = 0;
    for (final spec in rows) {
      final delOp = spec.del == null ? null : diff.entries[spec.del!].operation;
      final insOp = spec.ins == null ? null : diff.entries[spec.ins!].operation;
      final onlyEqual = (delOp == null || delOp == DiffOperation.equal) &&
          (insOp == null || insOp == DiffOperation.equal);
      if (onlyEqual) continue;
      if (spec.del == entryIndex || spec.ins == entryIndex) return row;
      row++;
    }
    return -1;
  }

  void _nextMatch() {
    _ensureFindApplied();
    if (_matchEntries.isEmpty) return;
    final next = (_matchPos + 1) % _matchEntries.length;
    setState(() => _matchPos = next);
    _scrollToEntry(_matchEntries[next]);
  }

  void _prevMatch() {
    _ensureFindApplied();
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

  void _openRegexHelp() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RegexHelpScreen()),
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

  void _jumpToNextDiff() {
    final indices = _diffIndices();
    if (indices.isEmpty) return;
    final current = _currentDiffPos < 0 ? -1 : _currentDiffPos;
    final next = (current + 1) % indices.length;
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
    _lastJumpAtMs = DateTime.now().millisecondsSinceEpoch;
    setState(() => _currentDiffPos = pos);
    _scrollToEntry(indices[pos]);
  }

  /// 找屏幕上最靠上的那个已构建行。
  /// 遍历时顺手把已失效的 key 从 map 里删掉，避免滚动一段时间后 map 膨胀到几万条，
  /// 每次滚动结束都要 O(n) 遍历一次。
  int? _findFirstVisibleDiffEntry() {
    if (_rowKeysByEntry.isEmpty) return null;
    int? best;
    double bestTop = double.infinity;
    final stale = <int>[];
    for (final e in _rowKeysByEntry.entries) {
      final ctx = e.value.currentContext;
      if (ctx == null) {
        stale.add(e.key);
        continue;
      }
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) {
        stale.add(e.key);
        continue;
      }
      final top = box.localToGlobal(Offset.zero).dy;
      if (top + box.size.height > 0 && top < bestTop) {
        bestTop = top;
        best = e.key;
      }
    }
    for (final k in stale) {
      _rowKeysByEntry.remove(k);
    }
    return best;
  }

  /// 防抖入口：滚动结束时调用，250ms 内只真正执行一次。
  void _captureAnchor() {
    _captureTimer?.cancel();
    _captureTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _captureAnchorNow();
    });
  }

  /// 立即执行锚点捕获（切视图等场景需要同步结果）。
  void _captureAnchorNow() {
    if (!mounted) return;
    final anchorEntry = _findFirstVisibleDiffEntry();
    if (anchorEntry == null) return;
    _anchorEntryIndex = anchorEntry;

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

  Future<void> _switchView(ViewMode newMode) async {
    final current = ref.read(viewModeProvider);
    if (current == newMode) return;

    _captureTimer?.cancel();
    _captureAnchorNow();
    final anchor = _anchorEntryIndex;
    final searchEntry = _currentMatchEntry;
    final hasSearch = _findQuery.isNotEmpty && _matchEntries.isNotEmpty;

    // ===== 方向一：并排/合并 → 仅差异：不弹框，直接切，跳顶部 =====
    if (newMode == ViewMode.diffOnly) {
      ref.read(viewModeProvider.notifier).state = newMode;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (hasSearch) {
          _findChanged(_findQuery, autoScroll: false);
        }
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
      return;
    }

    // ===== 方向二：仅差异 → 并排/合并，且有查找词时弹框三选一 =====
    // ===== 并排 ⇄ 合并：不弹框，保持原有 anchor 行为 =====
    _SwitchTarget? choice;
    if (current == ViewMode.diffOnly && hasSearch) {
      choice = await _showSwitchViewDialog(newMode);
      if (!mounted || choice == null) return;
    }

    ref.read(viewModeProvider.notifier).state = newMode;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      if (!hasSearch) {
        if (anchor != null) _scrollToEntry(anchor);
        return;
      }

      // 仅差异 → 并排/合并 需要重搜（可见行集合变了）。
      // 并排 ⇄ 合并 可见行集合相同，不用重搜。
      if (current == ViewMode.diffOnly) {
        _findChanged(_findQuery, autoScroll: false);
      }

      switch (choice ?? _SwitchTarget.anchor) {
        case _SwitchTarget.match:
          if (_matchEntries.isEmpty) return;
          // 三层兜底：精确 → 最近 → 第一个
          var bestPos = -1;
          if (searchEntry != null) {
            bestPos = _matchEntries.indexOf(searchEntry);
            if (bestPos < 0) {
              var bestDiff = 1 << 30;
              for (var i = 0; i < _matchEntries.length; i++) {
                final d = (_matchEntries[i] - searchEntry).abs();
                if (d < bestDiff) {
                  bestDiff = d;
                  bestPos = i;
                }
              }
            }
          }
          if (bestPos < 0) bestPos = 0;
          setState(() => _matchPos = bestPos);
          _scrollToEntry(_matchEntries[bestPos]);
          break;
        case _SwitchTarget.top:
          if (_scrollController.hasClients) _scrollController.jumpTo(0);
          break;
        case _SwitchTarget.anchor:
          if (anchor != null) _scrollToEntry(anchor);
          break;
      }
    });
  }

  Future<_SwitchTarget?> _showSwitchViewDialog(ViewMode newMode) {
    final modeName = switch (newMode) {
      ViewMode.sideBySide => '并排',
      ViewMode.merged => '合并',
      ViewMode.diffOnly => '仅差异',
    };
    return showDialog<_SwitchTarget>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text('切换到$modeName视图'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '切换后会按新视图重新搜索。请选择要跳转到的位置：',
              style: Theme.of(c).textTheme.bodySmall,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('跳到当前搜索词所在的那一行'),
            onTap: () => Navigator.pop(c, _SwitchTarget.match),
          ),
          ListTile(
            leading: const Icon(Icons.vertical_align_top),
            title: const Text('跳到文件最开头'),
            onTap: () => Navigator.pop(c, _SwitchTarget.top),
          ),
          ListTile(
            leading: const Icon(Icons.my_location),
            title: const Text('跳到屏幕最上面那行对应位置'),
            onTap: () => Navigator.pop(c, _SwitchTarget.anchor),
          ),
        ],
      ),
    );
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
      isScrollControlled: true,
      builder: (_) => const _DisplaySettingsSheet(),
    );
  }

  void _openComparisonSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ComparisonSettingsScreen(),
      ),
    );
  }

  // ==================== 导出差异 ====================

  ({List<String> left, List<String> right}) _collectDiffParts(
      DiffResult diff) {
    final leftParts = <String>[];
    final rightParts = <String>[];

    final entries = diff.entries;
    var i = 0;
    while (i < entries.length) {
      if (entries[i].operation == DiffOperation.equal) {
        i++;
        continue;
      }
      final delLines = <String>[];
      while (i < entries.length &&
          entries[i].operation == DiffOperation.delete) {
        delLines.add(entries[i].text);
        i++;
      }
      final insLines = <String>[];
      while (i < entries.length &&
          entries[i].operation == DiffOperation.insert) {
        insLines.add(entries[i].text);
        i++;
      }

      final pairs = delLines.length < insLines.length
          ? delLines.length
          : insLines.length;

      for (var k = 0; k < pairs; k++) {
        final segs =
            DiffCache.instance.charSegments(delLines[k], insLines[k]);
        final leftOnly = <String>[];
        final rightOnly = <String>[];
        for (final (op, text) in segs) {
          if (text.isEmpty) continue;
          if (op == -1) leftOnly.add(text);
          if (op == 1) rightOnly.add(text);
        }
        if (leftOnly.isEmpty) {
          leftParts.addAll(rightOnly);
        } else {
          leftParts.addAll(leftOnly);
          rightParts.addAll(rightOnly);
        }
      }

      for (var k = pairs; k < delLines.length; k++) {
        leftParts.add(delLines[k]);
      }
      for (var k = pairs; k < insLines.length; k++) {
        rightParts.add(insLines[k]);
      }
    }

    return (left: leftParts, right: rightParts);
  }

  Future<void> _exportDiff() async {
    final diff = _diff;
    if (diff == null) return;

    final side = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('导出哪一侧的差异？',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('导出左边文件的差异处'),
              onTap: () => Navigator.pop(c, 'left'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_forward),
              title: const Text('导出右边文件的差异处'),
              onTap: () => Navigator.pop(c, 'right'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(c),
            ),
          ],
        ),
      ),
    );
    if (!mounted || side == null) return;

    final isLeft = side == 'left';
    final parts = _collectDiffParts(diff);
    final list = isLeft ? parts.left : parts.right;

    if (list.isEmpty) {
      _toast('这一侧没有差异可导出');
      return;
    }

    final buf = StringBuffer();
    for (final p in list) {
      buf.writeln(p);
    }
    final bytes = Uint8List.fromList(utf8.encode(buf.toString()));
    final out = await FilePicker.saveFile(
      fileName:
          'docdiff-${isLeft ? "left" : "right"}-${DateTime.now().millisecondsSinceEpoch}.txt',
      bytes: bytes,
      mimeType: 'text/plain',
      dialogTitle: isLeft ? '导出左边文件差异' : '导出右边文件差异',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (out != null && mounted) {
      _toast('差异已导出');
    }
  }

  // ==================== 长按：复制 / 就地编辑 ====================

  List<({int orig, int mod})> _computeLineMeta(DiffResult result) {
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
    return meta;
  }

  void _replaceRawLine({
    required bool isOriginal,
    required int normalizedLine,
    required String newText,
  }) {
    final raw = ref.read(
      isOriginal ? originalRawTextProvider : modifiedRawTextProvider,
    );
    if (raw == null) return;

    final rawLine = rawLineForNormalizedLine(
      raw,
      normalizedLine: normalizedLine,
      ignoreWhitespace: ref.read(ignoreWhitespaceProvider),
      ignoreEmptyLines: ref.read(ignoreEmptyLinesProvider),
      ignoreInvisible: ref.read(ignoreInvisibleProvider),
    );
    if (rawLine == null) return;

    final lines =
        raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    if (rawLine < 0 || rawLine >= lines.length) return;
    lines[rawLine] = newText;
    final newRaw = lines.join('\n');

    if (isOriginal) {
      ref.read(originalRawTextProvider.notifier).state = newRaw;
    } else {
      ref.read(modifiedRawTextProvider.notifier).state = newRaw;
    }
  }

  Future<void> _onRowLongPress(List<int> entryIndices) async {
    final diff = _diff;
    if (diff == null || entryIndices.isEmpty) return;

    int? origEntryIdx;
    int? modEntryIdx;
    for (final i in entryIndices) {
      final op = diff.entries[i].operation;
      if (op == DiffOperation.equal) {
        origEntryIdx ??= i;
        modEntryIdx ??= i;
      } else if (op == DiffOperation.delete ||
          op == DiffOperation.replace) {
        origEntryIdx ??= i;
      } else if (op == DiffOperation.insert) {
        modEntryIdx ??= i;
      }
    }
    if (origEntryIdx == null && modEntryIdx == null) return;

    final meta = _computeLineMeta(diff);

    String? origAnchorText;
    String? modAnchorText;
    if (origEntryIdx != null && origEntryIdx > 0) {
      origAnchorText = diff.entries[origEntryIdx - 1].text;
    }
    if (modEntryIdx != null && modEntryIdx > 0) {
      modAnchorText = diff.entries[modEntryIdx - 1].text;
    }

    String? origText;
    String? modText;
    int? origLine;
    int? modLine;

    if (origEntryIdx != null) {
      final e = diff.entries[origEntryIdx];
      origText =
          (e.operation == DiffOperation.replace && e.oldText.isNotEmpty)
              ? e.oldText
              : e.text;
      final m = meta[origEntryIdx].orig;
      if (m >= 0) origLine = m;
    }
    if (modEntryIdx != null) {
      final e = diff.entries[modEntryIdx];
      modText =
          (e.operation == DiffOperation.replace && e.newText.isNotEmpty)
              ? e.newText
              : e.text;
      final m = meta[modEntryIdx].mod;
      if (m >= 0) modLine = m;
    }

    final action = await _showRowActionSheet(
      origText: origText,
      modText: modText,
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'copyOrig':
        if (origText != null) {
          await Clipboard.setData(ClipboardData(text: origText));
          if (mounted) _toast('已复制左边此行');
        }
        return;
      case 'copyMod':
        if (modText != null) {
          await Clipboard.setData(ClipboardData(text: modText));
          if (mounted) _toast('已复制右边此行');
        }
        return;
      case 'edit':
        break;
      default:
        return;
    }

    final edited = await _showRowEditDialog(
      origText: origText,
      modText: modText,
    );
    if (edited == null) return;

    if (origLine != null && origText != null) {
      _replaceRawLine(
        isOriginal: true,
        normalizedLine: origLine,
        newText: edited.orig,
      );
    }
    if (modLine != null && modText != null) {
      _replaceRawLine(
        isOriginal: false,
        normalizedLine: modLine,
        newText: edited.mod,
      );
    }

    ref.read(importRevisionProvider.notifier).state++;
    _resetViewAfterEdit(
      anchorOrigLine: origLine,
      anchorModLine: modLine,
      anchorOrigText: origAnchorText,
      anchorModText: anchorModText,
    );
  }

  Future<String?> _showRowActionSheet({
    required String? origText,
    required String? modText,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (origText != null)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('复制左边此行'),
                subtitle: Text(
                  origText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(c).textTheme.labelSmall,
                ),
                onTap: () => Navigator.pop(c, 'copyOrig'),
              ),
            if (modText != null)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('复制右边此行'),
                subtitle: Text(
                  modText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(c).textTheme.labelSmall,
                ),
                onTap: () => Navigator.pop(c, 'copyMod'),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑此行'),
              onTap: () => Navigator.pop(c, 'edit'),
            ),
          ],
        ),
      ),
    );
  }

  Future<({String orig, String mod})?> _showRowEditDialog({
    required String? origText,
    required String? modText,
  }) async {
    final origCtrl = TextEditingController(text: origText ?? '');
    final modCtrl = TextEditingController(text: modText ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('编辑此行'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (origText != null) ...[
                const Text('左边'),
                const SizedBox(height: 4),
                TextField(
                  controller: origCtrl,
                  maxLines: null,
                  autofocus: modText == null,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (modText != null) ...[
                if (origText != null) const SizedBox(height: 12),
                const Text('右边'),
                const SizedBox(height: 4),
                TextField(
                  controller: modCtrl,
                  maxLines: null,
                  autofocus: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
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
    if (ok != true) return null;
    return (orig: origCtrl.text, mod: modCtrl.text);
  }

  void _resetViewAfterEdit({
    int? anchorOrigLine,
    int? anchorModLine,
    String? anchorOrigText,
    String? anchorModText,
  }) {
    _captureTimer?.cancel();
    _currentDiffPos = -1;
    _anchorEntryIndex = null;
    _matchEntries = const <int>[];
    _matchPos = -1;
    _rowKeysByEntry.clear();
    _cachedDiffIndices = null;
    _cachedDiffIndicesFor = null;
    DiffTextIndex.invalidate();
    setState(() {});

    final hasAnchor = anchorOrigLine != null ||
        anchorModLine != null ||
        (anchorOrigText != null && anchorOrigText.isNotEmpty) ||
        (anchorModText != null && anchorModText.isNotEmpty);
    if (!hasAnchor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
      });
      return;
    }

    _scrollToLineAfterRecompute(
      anchorOrigLine,
      anchorModLine,
      anchorOrigText,
      anchorModText,
    );
  }

  Future<void> _scrollToLineAfterRecompute(
    int? origLine,
    int? modLine,
    String? origAnchorText,
    String? modAnchorText,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (var attempt = 0; attempt < 30; attempt++) {
      if (!mounted) return;
      final diff = _diff;
      if (diff != null) {
        // 用文本索引 O(1) 命中，替代原来的 O(n) 线性搜索。
        final idx = DiffTextIndex.of(diff);
        int? hitEntry;
        if (origAnchorText != null && origAnchorText.isNotEmpty) {
          hitEntry = idx.firstEntryOf(origAnchorText);
        }
        if (hitEntry == null &&
            modAnchorText != null &&
            modAnchorText.isNotEmpty) {
          hitEntry = idx.firstEntryOf(modAnchorText);
        }
        if (hitEntry != null) {
          final target = hitEntry + 1 < diff.entries.length
              ? hitEntry + 1
              : hitEntry;
          _scrollToEntry(target);
          return;
        }

        final meta = _computeLineMeta(diff);
        for (var i = 0; i < meta.length; i++) {
          final m = meta[i];
          if ((origLine != null && m.orig == origLine) ||
              (modLine != null && m.mod == modLine)) {
            _scrollToEntry(i);
            return;
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
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
    final label = isOriginal ? '左边文件' : '右边文件';
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
    final totalDiffs = _diffIndices().length;
    final currentPos = _currentDiffPos >= 0 ? _currentDiffPos + 1 : 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '对比结果',
          style: TextStyle(fontSize: 11),
        ),
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
            iconSize: 26,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            tooltip: '上一处差异',
            onPressed: _jumpToPrevDiff,
          ),
          IconButton(
            key: const Key('next-diff'),
            icon: const Icon(Icons.arrow_downward),
            iconSize: 26,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            tooltip: '下一处差异',
            onPressed: _jumpToNextDiff,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            iconSize: 26,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            tooltip: '查找 / 替换',
            onPressed: () => setState(() => _showFind = !_showFind),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.tune),
            tooltip: '更多操作',
            onSelected: (v) {
              if (v == 'edit') {
                _openEdit();
              } else if (v == 'exportDiff') {
                _exportDiff();
              } else if (v == 'delOriginal') {
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
                ref.read(syncScrollProvider.notifier).update(!cur);
              } else if (v == 'displaySettings') {
                _openDisplaySettings();
              } else if (v == 'comparisonSettings') {
                _openComparisonSettings();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit),
                    SizedBox(width: 10),
                    Text('编辑对比中的2个文档'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'exportDiff',
                child: Row(
                  children: [
                    Icon(Icons.ios_share),
                    SizedBox(width: 10),
                    Text('导出差异为 txt'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'delOriginal',
                enabled: !_originalDeleted &&
                    ref.read(originalFilePathProvider) != null,
                child: Row(
                  children: [
                    const Icon(Icons.delete_outline, color: Colors.red),
                    const SizedBox(width: 10),
                    Text(_originalDeleted ? '左边文件已删除' : '删除左边文件'),
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
                    Text(_modifiedDeleted ? '右边文件已删除' : '删除右边文件'),
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
              const PopupMenuItem<String>(
                value: 'comparisonSettings',
                child: Row(
                  children: [
                    Icon(Icons.rule),
                    SizedBox(width: 10),
                    Text('比较设置'),
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
                        ? '关闭两栏同步滚动'
                        : '开启两栏同步滚动'),
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
                        ? '关闭性能面板'
                        : '开启性能面板'),
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
          if (ref.watch(showPerfOverlayProvider)) _buildPerfOverlay(),
          SegmentedButton<ViewMode>(
            segments: const [
              ButtonSegment(value: ViewMode.diffOnly, label: Text('仅差异')),
              ButtonSegment(value: ViewMode.sideBySide, label: Text('并排')),
              ButtonSegment(value: ViewMode.merged, label: Text('合并')),
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
                      currentMatchEntry: _currentMatchEntry,
                      rowKeysByEntry: _rowKeysByEntry,
                      showLineNumbers: ref.watch(showLineNumbersProvider),
                      bodyFontSize: ref.watch(bodyFontSizeProvider),
                      gutterFontSize: ref.watch(gutterFontSizeProvider),
                      onLongPressEntry: (i) => _onRowLongPress([i]),
                    ),
                  ViewMode.sideBySide => SideBySideView(
                      result: diff,
                      originalFileName: origName,
                      modifiedFileName: modName,
                      controller: _scrollController,
                      findQuery: _findQuery,
                      currentMatchEntry: _currentMatchEntry,
                      rowKeysByEntry: _rowKeysByEntry,
                      showLineNumbers: ref.watch(showLineNumbersProvider),
                      bodyFontSize: ref.watch(bodyFontSizeProvider),
                      gutterFontSize: ref.watch(gutterFontSizeProvider),
                      syncScroll: ref.watch(syncScrollProvider),
                      onLongPressEntry: _onRowLongPress,
                    ),
                  ViewMode.diffOnly => DiffOnlyView(
                      result: diff,
                      originalFileName: origName,
                      modifiedFileName: modName,
                      controller: _scrollController,
                      findQuery: _findQuery,
                      currentMatchEntry: _currentMatchEntry,
                      rowKeysByEntry: _rowKeysByEntry,
                      showLineNumbers: ref.watch(showLineNumbersProvider),
                      bodyFontSize: ref.watch(bodyFontSizeProvider),
                      gutterFontSize: ref.watch(gutterFontSizeProvider),
                      onLongPressEntry: _onRowLongPress,
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
    if (_originalDeleted) parts.add('左边文件');
    if (_modifiedDeleted) parts.add('右边文件');
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

  // ==================== 查找栏 UI ====================

  Widget _buildFindBar() {
    final total = _matchEntries.length;
    final pendingCount =
        _pendingOrigChanges.length + _pendingModChanges.length;

    Widget toggle({
      required String label,
      required bool value,
      required VoidCallback onTap,
      VoidCallback? onLongPress,
    }) {
      return InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: value ? FontWeight.bold : FontWeight.normal,
              color: value
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    Widget sideToggle({
      required String label,
      required bool value,
      required VoidCallback onTap,
    }) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                value ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
                color: value
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: value
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '关闭查找',
                  visualDensity: VisualDensity.compact,
                  onPressed: _closeFindBar,
                ),
                Expanded(
                  child: TextField(
                    controller: _findController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '查找',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: _onFindInput,
                    onSubmitted: (_) => _nextMatch(),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 48),
                Expanded(
                  child: TextField(
                    controller: _replaceController,
                    decoration: const InputDecoration(
                      hintText: '替换为（留空 = 删掉）',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: total == 0 ? null : _replaceCurrentInline,
                  child: const Text('替换当前'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: total == 0 ? null : _replaceAllInline,
                  child: const Text('全部替换'),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 8),
                sideToggle(
                  label: '查左侧',
                  value: _searchLeft,
                  onTap: () {
                    if (_searchLeft && !_searchRight) {
                      _toast('至少要开一个（左/右）');
                      return;
                    }
                    setState(() => _searchLeft = !_searchLeft);
                    _findChanged(_findController.text);
                  },
                ),
                sideToggle(
                  label: '查右侧',
                  value: _searchRight,
                  onTap: () {
                    if (_searchRight && !_searchLeft) {
                      _toast('至少要开一个（左/右）');
                      return;
                    }
                    setState(() => _searchRight = !_searchRight);
                    _findChanged(_findController.text);
                  },
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: '上一个',
                  visualDensity: VisualDensity.compact,
                  onPressed: total == 0 ? null : _prevMatch,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward),
                  tooltip: '下一个',
                  visualDensity: VisualDensity.compact,
                  onPressed: total == 0 ? null : _nextMatch,
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 8),
                toggle(
                  label: '正则',
                  value: _regexEnable,
                  onTap: () => setState(() {
                    _regexEnable = !_regexEnable;
                    _findChanged(_findController.text);
                  }),
                  onLongPress: _openRegexHelp,
                ),
                toggle(
                  label: '忽略大小写',
                  value: _caseInsensitive,
                  onTap: () => setState(() {
                    _caseInsensitive = !_caseInsensitive;
                    _findChanged(_findController.text);
                  }),
                  onLongPress: () => _toast('开启后 A 和 a 视为相同'),
                ),
                toggle(
                  label: '整词',
                  value: _wholeWord,
                  onTap: () => setState(() {
                    _wholeWord = !_wholeWord;
                    _findChanged(_findController.text);
                  }),
                  onLongPress: () => _toast('只匹配完整单词，对中文无效'),
                ),
                if (pendingCount > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '待应用 $pendingCount',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
                const Spacer(),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: pendingCount > 0
                        ? Colors.orange.shade800
                        : null,
                  ),
                  onPressed: pendingCount > 0 ? _applyPendingChanges : null,
                  icon: const Icon(Icons.done_all, size: 16),
                  label: const Text('应用并刷新'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 显示设置底部面板。
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
                      onChanged: (v) => ref
                          .read(showLineNumbersProvider.notifier)
                          .update(v),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '正文字号：${bodySize.toStringAsFixed(0)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Slider(
                      min: 2,
                      max: 38,
                      divisions: 36,
                      value: bodySize,
                      label: bodySize.toStringAsFixed(0),
                      onChanged: (v) =>
                          ref.read(bodyFontSizeProvider.notifier).update(v),
                    ),
                    Text(
                      '行号字号：${gutterSize.toStringAsFixed(0)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Slider(
                      min: 2,
                      max: 38,
                      divisions: 36,
                      value: gutterSize,
                      label: gutterSize.toStringAsFixed(0),
                      onChanged: (v) => ref
                          .read(gutterFontSizeProvider.notifier)
                          .update(v),
                    ),
                    const Divider(height: 32),
                    Text(
                      '差异颜色',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    _colorRow(context, ref, '左文件独有行 · 整行底色',
                        deleteRowBgProvider),
                    _colorRow(context, ref, '左文件独有行 · 文字颜色',
                        deleteRowFgProvider),
                    _colorRow(context, ref, '右文件独有行 · 整行底色',
                        insertRowBgProvider),
                    _colorRow(context, ref, '右文件独有行 · 文字颜色',
                        insertRowFgProvider),
                    _colorRow(context, ref, '被改行（左）· 整行底色',
                        replaceLeftBgProvider),
                    _colorRow(context, ref, '被改行（左）· 文字颜色',
                        replaceLeftFgProvider),
                    _colorRow(context, ref, '被改行（右）· 整行底色',
                        replaceRightBgProvider),
                    _colorRow(context, ref, '被改行（右）· 文字颜色',
                        replaceRightFgProvider),
                    _colorRow(context, ref, '行内删掉的字 · 底色',
                        charDeleteBgProvider),
                    _colorRow(context, ref, '行内删掉的字 · 文字颜色',
                        charDeleteFgProvider),
                    _colorRow(context, ref, '行内新增的字 · 底色',
                        charInsertBgProvider),
                    _colorRow(context, ref, '行内新增的字 · 文字颜色',
                        charInsertFgProvider),
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

  /// 12 个颜色现在都是 `NotifierProvider<ColorPrefNotifier, Color>`。
  Widget _colorRow(
    BuildContext context,
    WidgetRef ref,
    String label,
    NotifierProvider<ColorPrefNotifier, Color> provider,
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
    NotifierProvider<ColorPrefNotifier, Color> provider,
  ) async {
    var picked = ref.read(provider);
    final controller = TextEditingController(text: colorToHex(picked));

    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialogState) => AlertDialog(
          title: Text(label),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 拖动选择任意颜色的色板
                ColorPicker(
                  pickerColor: picked,
                  onColorChanged: (color) {
                    picked = color;
                    controller.text = colorToHex(color);
                  },
                  enableAlpha: false,
                  labelTypes: const [],
                  pickerAreaHeightPercent: 0.7,
                  displayThumbColor: true,
                  portraitOnly: true,
                ),
                const SizedBox(height: 12),
                // 仍然保留手动输入 #RRGGBB 的入口，方便精确输入
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: '#RRGGBB',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (v) {
                    final parsed = hexToColor(v.trim());
                    if (parsed != null) {
                      picked = parsed;
                      setDialogState(() {});
                    }
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  '拖动上面的色板选颜色，或手动输入 #RRGGBB',
                  style: Theme.of(c).textTheme.labelSmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                ref.read(provider.notifier).update(picked);
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
