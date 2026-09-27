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
import 'diff_text_index.dart';
import 'line_height_cache.dart';
import 'line_height_calculator.dart';
import 'providers/diff_viewer_providers.dart';
import 'regex_help_screen.dart';
import 'widgets/diff_only_plain_view.dart';
import 'widgets/diff_only_view.dart';
import 'widgets/merged_view.dart';
import 'widgets/side_by_side_view.dart';
import '../../preprocessing/application/preprocessing_service.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';
import '../../file_browser/presentation/comparison_settings_screen.dart'
    show RuleEditorDialog, ruleSubtitle;
import 'providers/toolbar_rules_provider.dart';

class DiffViewerScreen extends ConsumerStatefulWidget {
  const DiffViewerScreen({super.key});

  @override
  ConsumerState<DiffViewerScreen> createState() => _DiffViewerScreenState();
}

/// 切视图时用户选择的目标。
class _SwitchChoice {
  const _SwitchChoice.top()
      : targetEntry = null,
        isTop = true;
  const _SwitchChoice.entry(int this.targetEntry) : isTop = false;

  final int? targetEntry;
  final bool isTop;
}

/// 一次 view build 需要的高度表集合。
class _HeightBundle {
  const _HeightBundle({
    this.merged,
    this.sbsSync,
    this.sbsLeft,
    this.sbsRight,
    this.diffOnly,
    this.diffOnlyPlain,
  });

  final LineHeightTable? merged;
  final LineHeightTable? sbsSync;
  final LineHeightTable? sbsLeft;
  final LineHeightTable? sbsRight;
  final LineHeightTable? diffOnly;
  final LineHeightTable? diffOnlyPlain;
}

class _DiffViewerScreenState extends ConsumerState<DiffViewerScreen> {
  final ScrollController _scrollController = ScrollController();

  /// 不换行模式下，外层横向滚动。
  final ScrollController _hScrollController = ScrollController();

  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();

  bool _showFind = false;
  String _findQuery = '';
  List<int> _matchEntries = const <int>[];
  int _matchPos = -1;

  String _scannedQuery = '';
  String? _noResultHint;

  bool _regexEnable = false;
  bool _caseInsensitive = false;
  bool _wholeWord = false;
  bool _searchLeft = true;
  bool _searchRight = true;

  final Map<int, String> _pendingOrigChanges = <int, String>{};
  final Map<int, String> _pendingModChanges = <int, String>{};

  bool _landscape = false;
  bool _originalDeleted = false;
  bool _modifiedDeleted = false;

  List<int>? _cachedDiffIndices;
  DiffResult? _cachedDiffIndicesFor;

  Map<int, int>? _entryToRowMap;
  DiffResult? _entryToRowMapFor;
  ViewMode? _entryToRowMapMode;
  final Map<ViewMode, Future<_HeightBundle>> _heightFutures = {};
  DiffResult? _heightFuturesFor;
  String? _heightFuturesConfigKey;
  int? _jumpedToEntry;

  _HeightBundle? _activeHeights;
  ViewMode? _activeHeightsMode;

  // 内容宽度缓存（不换行模式横向滚动用）。
  double? _cachedContentWidth;
  DiffResult? _cachedContentWidthFor;
  String? _cachedContentWidthConfig;

  int? _pendingJumpEntry;
  bool _pendingJumpQueued = false;

  Timer? _findDebounce;
  bool _processing = false;
  String _processingText = '';

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
    _findDebounce?.cancel();
    _findController.dispose();
    _replaceController.dispose();
    _scrollController.dispose();
    _hScrollController.dispose();
    super.dispose();
  }

  DiffResult? get _diff => ref.read(diffResultProvider).value;

  int? get _currentMatchEntry {
    if (_matchEntries.isEmpty) return null;
    if (_matchPos < 0 || _matchPos >= _matchEntries.length) return null;
    return _matchEntries[_matchPos];
  }

  bool _isDiffOnlyMode(ViewMode m) =>
      m == ViewMode.diffOnly || m == ViewMode.diffOnlyPlain;

  bool get _isLargeFile {
    final diff = _diff;
    return diff != null && diff.entries.length > 2000;
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

  Set<int> _visibleEntriesFor(ViewMode mode, DiffResult diff) {
    final s = <int>{};
    switch (mode) {
      case ViewMode.diffOnly:
        for (final spec in cachedDiffOnlyRows(diff)) {
          if (spec.del != null) s.add(spec.del!);
          if (spec.ins != null) s.add(spec.ins!);
        }
        break;
      case ViewMode.diffOnlyPlain:
        for (final spec in cachedDiffOnlyPlainRows(diff)) {
          if (spec.del != null) s.add(spec.del!);
          if (spec.ins != null) s.add(spec.ins!);
        }
        break;
      case ViewMode.sideBySide:
        for (final spec in cachedAlignedRows(diff)) {
          if (spec.del != null) s.add(spec.del!);
          if (spec.ins != null) s.add(spec.ins!);
        }
        break;
      case ViewMode.merged:
        for (final ei in cachedMergedOrder(diff)) {
          s.add(ei);
        }
        break;
    }
    return s;
  }

  void _onFindInput(String q) {
    _findDebounce?.cancel();
    if (_isLargeFile) {
      setState(() => _findQuery = q);
      return;
    }
    _findDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _findChanged(q);
    });
  }

  void _findChanged(String q, {bool autoScroll = true}) {
    _findQuery = q;
    _scannedQuery = q;
    final diff = _diff;
    final matches = <int>[];
    var hasGlobalHits = false;
    String? hint;

    if (q.isNotEmpty && diff != null) {
      final p = _buildFindPattern();
      final mode = ref.read(viewModeProvider);

      final visible = _visibleEntriesFor(mode, diff);
      for (var i = 0; i < diff.entries.length; i++) {
        if (!visible.contains(i)) continue;
        final e = diff.entries[i];
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

      if (matches.isEmpty && _isDiffOnlyMode(mode)) {
        for (var i = 0; i < diff.entries.length; i++) {
          final e = diff.entries[i];
          if (p.allMatches(_entryLeftText(e)).isNotEmpty ||
              p.allMatches(_entryRightText(e)).isNotEmpty) {
            hasGlobalHits = true;
            break;
          }
        }
        if (hasGlobalHits) {
          hint = '本视图搜不到，切到「并排」或「合并」试试';
        }
      }
    }

    int newPos = 0;
    if (matches.isNotEmpty && diff != null) {
      final mode = ref.read(viewModeProvider);
      final topRow = _currentTopRow();
      if (topRow != null) {
        final map = _entryToRowMapOf(diff, mode);
        for (var i = 0; i < matches.length; i++) {
          final r = map[matches[i]];
          if (r != null && r >= topRow) {
            newPos = i;
            break;
          }
        }
      }
    }

    setState(() {
      _matchEntries = matches;
      _matchPos = matches.isEmpty ? -1 : newPos;
      _noResultHint = hint;
    });
    if (autoScroll && matches.isNotEmpty) {
      _scrollToEntry(matches[newPos]);
    }
  }

  void _ensureFindApplied() {
    _findDebounce?.cancel();
    if (_scannedQuery != _findController.text) {
      _findChanged(_findController.text, autoScroll: false);
    }
  }

  void _recordFindHistory() {
    final q = _findController.text;
    if (q.trim().isEmpty) return;
    ref.read(findHistoryProvider.notifier).add(q);
  }

  Future<void> _showFindHistory() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _FindHistoryDialog(
        onPick: (q) {
          _findController.text = q;
          setState(() => _findQuery = q);
        },
      ),
    );
  }

  // ==================== 替换 ====================

  void _replaceCurrentInline() {
    _ensureFindApplied();
    _recordFindHistory();
    if (_findQuery.isEmpty || _matchEntries.isEmpty || _matchPos < 0) {
      _toast('没有可替换的内容');
      return;
    }
    _doReplace(replacement: _replaceController.text, all: false);
  }

  void _replaceAllInline() {
    _ensureFindApplied();
    _recordFindHistory();
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

    final current = ref.read(
      isOriginal ? preprocessedOriginalProvider : preprocessedModifiedProvider,
    );
    if (current.isEmpty) return;

    final lines = current.split('\n');
    for (final entry in changes.entries) {
      final lineNo = entry.key;
      if (lineNo < 0 || lineNo >= lines.length) continue;
      lines[lineNo] = entry.value;
    }
    final newProcessed = lines.join('\n');

    if (isOriginal) {
      ref.read(editedOriginalProvider.notifier).state = newProcessed;
    } else {
      ref.read(editedModifiedProvider.notifier).state = newProcessed;
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
      _scannedQuery = '';
      _matchEntries = const [];
      _matchPos = -1;
      _noResultHint = null;
    });
  }

  // ==================== 行数 / 行映射 ====================

  Map<int, int> _entryToRowMapOf(DiffResult diff, ViewMode mode) {
    if (identical(_entryToRowMapFor, diff) &&
        _entryToRowMapMode == mode &&
        _entryToRowMap != null) {
      return _entryToRowMap!;
    }
    final map = <int, int>{};
    if (mode == ViewMode.merged) {
      final order = cachedMergedOrder(diff);
      for (var r = 0; r < order.length; r++) {
        map[order[r]] = r;
      }
    } else if (mode == ViewMode.sideBySide) {
      final rows = cachedAlignedRows(diff);
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del != null) map.putIfAbsent(spec.del!, () => r);
        if (spec.ins != null) map.putIfAbsent(spec.ins!, () => r);
      }
    } else if (mode == ViewMode.diffOnlyPlain) {
      final rows = cachedDiffOnlyPlainRows(diff);
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del != null) map.putIfAbsent(spec.del!, () => r);
        if (spec.ins != null) map.putIfAbsent(spec.ins!, () => r);
      }
    } else {
      final rows = cachedDiffOnlyRows(diff);
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del != null) map.putIfAbsent(spec.del!, () => r);
        if (spec.ins != null) map.putIfAbsent(spec.ins!, () => r);
      }
    }
    _entryToRowMap = map;
    _entryToRowMapFor = diff;
    _entryToRowMapMode = mode;
    return map;
  }

  // ==================== 高度表 ====================

  Future<_HeightBundle> _getHeightFuture(DiffResult diff, ViewMode mode) {
    final mq = MediaQuery.of(context);
    final configKey = '${mq.size.width}|'
        '${ref.read(bodyFontSizeProvider)}|'
        '${ref.read(noWrapProvider)}|'
        '${ref.read(showLineNumbersProvider)}|'
        '${ref.read(importRevisionProvider)}|'
        '${ref.read(syncScrollProvider)}';

    if (!identical(_heightFuturesFor, diff) ||
        _heightFuturesConfigKey != configKey) {
      _heightFutures.clear();
      _heightFuturesFor = diff;
      _heightFuturesConfigKey = configKey;
    }

    final existing = _heightFutures[mode];
    if (existing != null) return existing;

    final f = _computeHeightBundle(diff, mode);
    _heightFutures[mode] = f;
    return f;
  }

  Future<_HeightBundle> _computeHeightBundle(
    DiffResult diff,
    ViewMode mode,
  ) async {
    final mq = MediaQuery.of(context);
    final viewportW = mq.size.width;
    final dpr = mq.devicePixelRatio;
    final scaler = mq.textScaler;

    final noWrap = ref.read(noWrapProvider);
    final showLine = ref.read(showLineNumbersProvider);
    final bodySize = ref.read(bodyFontSizeProvider);
    final style = TextStyle(fontSize: bodySize, height: 1.35);

    final fp = contentFingerprint(
      ref.read(originalRawTextProvider) ?? '',
      ref.read(modifiedRawTextProvider) ?? '',
    );
    final rev = ref.read(importRevisionProvider);

    String cacheKey(String name) => buildLineHeightCacheKey(
          contentFingerprint: fp,
          importRevision: rev,
          viewModeName: name,
          viewportWidth: viewportW,
          bodyFontSize: bodySize,
          showLineNumbers: showLine,
          noWrap: noWrap,
          devicePixelRatio: dpr,
        );

    if (mode == ViewMode.merged) {
      final order = cachedMergedOrder(diff);
      final rowW = showLine ? viewportW - 50.0 : viewportW - 16.0;
      final k = cacheKey('merged');
      final cached = LineHeightCache.instance.get(k);
      if (cached != null) return _HeightBundle(merged: cached);
      final table = await computeLineHeights(
        itemCount: order.length,
        widthForItem: (_) => rowW,
        textForItem: (i) => diff.entries[order[i]].text,
        style: style,
        textScaler: scaler,
        noWrap: noWrap,
        extraVerticalPadding: 8,
      );
      LineHeightCache.instance.put(k, table);
      return _HeightBundle(merged: table);
    }

    if (mode == ViewMode.sideBySide) {
      if (ref.read(syncScrollProvider)) {
        final rows = cachedAlignedRows(diff);
        final panelW = (viewportW - 1) / 2;
        final contentW = panelW - 52.0;
        final k = cacheKey('sbs_sync');
        final cached = LineHeightCache.instance.get(k);
        if (cached != null) return _HeightBundle(sbsSync: cached);
        final table = await computeLineHeightsForTwoPane(
          itemCount: rows.length,
          leftWidth: contentW,
          rightWidth: contentW,
          leftTextForItem: (i) {
            final spec = rows[i];
            if (spec.del != null) return diff.entries[spec.del!].text;
            return '';
          },
          rightTextForItem: (i) {
            final spec = rows[i];
            if (spec.ins != null) return diff.entries[spec.ins!].text;
            return '';
          },
          style: style,
          textScaler: scaler,
          noWrap: noWrap,
          extraVerticalPadding: 12,
        );
        LineHeightCache.instance.put(k, table);
        return _HeightBundle(sbsSync: table);
      } else {
        final entries = diff.entries;
        final leftIndices = <int>[];
        final rightIndices = <int>[];
        for (var i = 0; i < entries.length; i++) {
          final op = entries[i].operation;
          if (op != DiffOperation.insert) leftIndices.add(i);
          if (op != DiffOperation.delete) rightIndices.add(i);
        }
        final panelW = (viewportW - 1) / 2;
        final contentW = panelW - 52.0;

        final lk = cacheKey('sbs_left');
        final rk = cacheKey('sbs_right');
        final cachedL = LineHeightCache.instance.get(lk);
        final cachedR = LineHeightCache.instance.get(rk);

        final leftTable = cachedL ??
            await computeLineHeights(
              itemCount: leftIndices.length,
              widthForItem: (_) => contentW,
              textForItem: (i) => entries[leftIndices[i]].text,
              style: style,
              textScaler: scaler,
              noWrap: noWrap,
              extraVerticalPadding: 12,
            );
        if (cachedL == null) LineHeightCache.instance.put(lk, leftTable);

        final rightTable = cachedR ??
            await computeLineHeights(
              itemCount: rightIndices.length,
              widthForItem: (_) => contentW,
              textForItem: (i) => entries[rightIndices[i]].text,
              style: style,
              textScaler: scaler,
              noWrap: noWrap,
              extraVerticalPadding: 12,
            );
        if (cachedR == null) LineHeightCache.instance.put(rk, rightTable);

        return _HeightBundle(sbsLeft: leftTable, sbsRight: rightTable);
      }
    }

    final isPlain = mode == ViewMode.diffOnlyPlain;
    final rows =
        isPlain ? cachedDiffOnlyPlainRows(diff) : cachedDiffOnlyRows(diff);
    final panelW = (viewportW - 1) / 2;
    final contentW = panelW - 44.0;
    final k = cacheKey(isPlain ? 'diff_only_plain' : 'diff_only');
    final cached = LineHeightCache.instance.get(k);
    if (cached != null) {
      return isPlain
          ? _HeightBundle(diffOnlyPlain: cached)
          : _HeightBundle(diffOnly: cached);
    }
    final table = await computeLineHeightsForTwoPane(
      itemCount: rows.length,
      leftWidth: contentW,
      rightWidth: contentW,
      leftTextForItem: (i) {
        final spec = rows[i];
        if (spec.del != null) {
          final e = diff.entries[spec.del!];
          if (e.operation == DiffOperation.replace && e.oldText.isNotEmpty) {
            return e.oldText;
          }
          return e.text;
        }
        return '';
      },
      rightTextForItem: (i) {
        final spec = rows[i];
        if (spec.ins != null) {
          final e = diff.entries[spec.ins!];
          if (e.operation == DiffOperation.replace && e.newText.isNotEmpty) {
            return e.newText;
          }
          return e.text;
        }
        return '';
      },
      style: style,
      textScaler: scaler,
      noWrap: noWrap,
      extraVerticalPadding: 4,
    );
    LineHeightCache.instance.put(k, table);
    return isPlain
        ? _HeightBundle(diffOnlyPlain: table)
        : _HeightBundle(diffOnly: table);
  }

  LineHeightTable? _activeTableFor(ViewMode mode) {
    final h = _activeHeights;
    if (h == null) return null;
    switch (mode) {
      case ViewMode.merged:
        return h.merged;
      case ViewMode.sideBySide:
        return h.sbsSync ?? h.sbsLeft;
      case ViewMode.diffOnly:
        return h.diffOnly;
      case ViewMode.diffOnlyPlain:
        return h.diffOnlyPlain;
    }
  }

  // ==================== 滚动 / 跳转 ====================

  void _scrollToEntry(int entryIndex) {
    final diff = _diff;
    if (diff == null) return;
    final mode = ref.read(viewModeProvider);
    final table = _activeTableFor(mode);
    if (table == null) return;
    if (!_scrollController.hasClients) return;

    final map = _entryToRowMapOf(diff, mode);
    final row = map[entryIndex];
    if (row == null) return;

    final offset = table.offsetOf(row);
    final max = _scrollController.position.maxScrollExtent;
    final clamped = offset < 0 ? 0.0 : (offset > max ? max : offset);
    _scrollController.jumpTo(clamped);

    if (_jumpedToEntry != entryIndex) {
      setState(() => _jumpedToEntry = entryIndex);
    }
  }

  void _nextMatch() {
    _ensureFindApplied();
    _recordFindHistory();
    if (_matchEntries.isEmpty) return;
    final next = (_matchPos + 1) % _matchEntries.length;
    setState(() => _matchPos = next);
    _scrollToEntry(_matchEntries[next]);
  }

  void _prevMatch() {
    _ensureFindApplied();
    _recordFindHistory();
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

  int _diffBlockCount(DiffResult diff) {
    var count = 0;
    var inBlock = false;
    for (final e in diff.entries) {
      final isDiff = e.operation != DiffOperation.equal;
      if (isDiff && !inBlock) {
        count++;
        inBlock = true;
      } else if (!isDiff) {
        inBlock = false;
      }
    }
    return count;
  }

  int? _currentTopRow() {
    final diff = _diff;
    if (diff == null) return null;
    final mode = ref.read(viewModeProvider);
    final table = _activeTableFor(mode);
    if (table == null) return null;
    if (!_scrollController.hasClients) return null;
    return table.indexAt(_scrollController.position.pixels);
  }

  void _jumpToDocTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(0);
  }

  void _jumpToDocBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  void _jumpToNextDiff() {
    final diff = _diff;
    if (diff == null) return;
    final mode = ref.read(viewModeProvider);
    final map = _entryToRowMapOf(diff, mode);
    final currentRow = _currentTopRow();
    if (currentRow == null) return;

    final indices = _diffIndices();
    if (indices.isEmpty) return;

    for (final ei in indices) {
      final r = map[ei];
      if (r != null && r > currentRow) {
        _scrollToEntry(ei);
        return;
      }
    }
    _toast('到底了');
  }

  void _jumpToPrevDiff() {
    final diff = _diff;
    if (diff == null) return;
    final mode = ref.read(viewModeProvider);
    final map = _entryToRowMapOf(diff, mode);
    final currentRow = _currentTopRow();
    if (currentRow == null) return;

    final indices = _diffIndices();
    if (indices.isEmpty) return;

    for (var i = indices.length - 1; i >= 0; i--) {
      final ei = indices[i];
      final r = map[ei];
      if (r != null && r < currentRow) {
        _scrollToEntry(ei);
        return;
      }
    }
    _toast('到顶了');
  }

  // ==================== 切视图 ====================

  Future<void> _switchView(ViewMode newMode) async {
    final current = ref.read(viewModeProvider);
    if (current == newMode) return;

    final searchEntry = _currentMatchEntry;
    final hasSearch = _findQuery.isNotEmpty && _matchEntries.isNotEmpty;

    final choice = await _showSwitchChoiceDialog(
      newMode: newMode,
      hasSearch: hasSearch,
      searchEntry: searchEntry,
    );
    if (!mounted || choice == null) return;

    ref.read(viewModeProvider.notifier).state = newMode;

    final target = choice.isTop ? -1 : (choice.targetEntry ?? -1);
    _pendingJumpEntry = target;
    _pendingJumpQueued = false;
    setState(() {});
  }

  Future<_SwitchChoice?> _showSwitchChoiceDialog({
    required ViewMode newMode,
    required bool hasSearch,
    required int? searchEntry,
  }) async {
    final modeName = switch (newMode) {
      ViewMode.sideBySide => '并排',
      ViewMode.merged => '合并',
      ViewMode.diffOnly => '差异上下文行',
      ViewMode.diffOnlyPlain => '纯差异',
    };

    final diff = _diff;
    final mode = ref.read(viewModeProvider);
    final map = diff == null ? <int, int>{} : _entryToRowMapOf(diff, mode);
    final topRow = _currentTopRow();

    int? entryAtRowDelta(int delta) {
      if (diff == null || topRow == null || map.isEmpty) return null;
      var target = topRow + delta;
      if (target < 0) target = 0;
      int? best;
      var bestDist = 1 << 30;
      for (final e in map.entries) {
        final d = (e.value - target).abs();
        if (d < bestDist) {
          bestDist = d;
          best = e.key;
        }
      }
      return best;
    }

    final entry0 = entryAtRowDelta(0);
    final entry1 = entryAtRowDelta(1);
    final entry2 = entryAtRowDelta(2);
    final entryNeg = entryAtRowDelta(-1);

    String preview(int? entryIndex) {
      if (diff == null || entryIndex == null) return '';
      final e = diff.entries[entryIndex];
      final raw =
          (e.operation == DiffOperation.replace && e.newText.isNotEmpty)
              ? e.newText
              : e.text;
      if (raw.isEmpty) return '（空行）';
      return raw.length > 20 ? '${raw.substring(0, 20)}…' : raw;
    }

    Widget choiceTile({
      required IconData icon,
      required String title,
      required String? subtitle,
      required VoidCallback onTap,
    }) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null || subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
        onTap: onTap,
      );
    }

    return showDialog<_SwitchChoice>(
      context: context,
      builder: (c) {
        final children = <Widget>[];

        if (hasSearch && searchEntry != null) {
          children.add(choiceTile(
            icon: Icons.search,
            title: '跳到我搜的那个词',
            subtitle: preview(searchEntry),
            onTap: () => Navigator.pop(c, _SwitchChoice.entry(searchEntry)),
          ));
        } else {
          if (entry0 != null) {
            children.add(choiceTile(
              icon: Icons.looks_one,
              title: '停在我现在看的地方（屏幕第 1 行）',
              subtitle: preview(entry0),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entry0)),
            ));
          }
          if (entry1 != null) {
            children.add(choiceTile(
              icon: Icons.looks_two,
              title: '停在我现在看的地方（屏幕第 2 行）',
              subtitle: preview(entry1),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entry1)),
            ));
          }
          if (entry2 != null) {
            children.add(choiceTile(
              icon: Icons.looks_3,
              title: '停在我现在看的地方（屏幕第 3 行）',
              subtitle: preview(entry2),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entry2)),
            ));
          }
          if (entryNeg != null) {
            children.add(choiceTile(
              icon: Icons.expand_less,
              title: '屏幕顶部再往上一点',
              subtitle: preview(entryNeg),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entryNeg)),
            ));
          }
        }

        children.add(const Divider(height: 1));
        children.add(choiceTile(
          icon: Icons.vertical_align_top,
          title: '跳到文件最开头',
          subtitle: null,
          onTap: () => Navigator.pop(c, const _SwitchChoice.top()),
        ));

        return SimpleDialog(
          title: Text('切换到$modeName视图'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                '切换后请选择要跳转到的位置：',
                style: Theme.of(c).textTheme.bodySmall,
              ),
            ),
            ...children,
          ],
        );
      },
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
    final current = ref.read(
      isOriginal ? preprocessedOriginalProvider : preprocessedModifiedProvider,
    );
    if (current.isEmpty) return;

    final lines = current.split('\n');
    if (normalizedLine < 0 || normalizedLine >= lines.length) return;
    lines[normalizedLine] = newText;
    final newProcessed = lines.join('\n');

    if (isOriginal) {
      ref.read(editedOriginalProvider.notifier).state = newProcessed;
    } else {
      ref.read(editedModifiedProvider.notifier).state = newProcessed;
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
      anchorModText: modAnchorText,
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
    _matchEntries = const <int>[];
    _matchPos = -1;
    _noResultHint = null;
    _scannedQuery = '';
    _cachedDiffIndices = null;
    _cachedDiffIndicesFor = null;
    _entryToRowMap = null;
    _entryToRowMapFor = null;
    _entryToRowMapMode = null;
    _heightFutures.clear();
    _heightFuturesFor = null;
    _heightFuturesConfigKey = null;
    _cachedContentWidth = null;
    _cachedContentWidthFor = null;
    _cachedContentWidthConfig = null;
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
        if (_hScrollController.hasClients) _hScrollController.jumpTo(0);
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
    await Future<void>.delayed(const Duration(milliseconds: 400));
    for (var attempt = 0; attempt < 30; attempt++) {
      if (!mounted) return;
      final diff = _diff;
      if (diff != null && _activeHeights != null) {
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
    } catch (_) {}

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
        return _buildWithHeights(diff, viewMode, origName, modName);
      },
    );
  }

  Widget _buildWithHeights(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
  ) {
    final future = _getHeightFuture(diff, viewMode);
    return FutureBuilder<_HeightBundle>(
      future: future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Scaffold(
            appBar: AppBar(title: const Text('对比结果')),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '正在计算显示布局…',
                  style: TextStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        final heights = snapshot.data!;
        _activeHeights = heights;
        _activeHeightsMode = viewMode;

        if (_pendingJumpEntry != null && !_pendingJumpQueued) {
          _pendingJumpQueued = true;
          final target = _pendingJumpEntry!;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted) return;
            _pendingJumpEntry = null;
            _pendingJumpQueued = false;

            for (var attempt = 0; attempt < 5; attempt++) {
              if (!mounted) return;
              if (!_scrollController.hasClients) {
                await WidgetsBinding.instance.endOfFrame;
                continue;
              }
              if (_scrollController.position.maxScrollExtent > 0 ||
                  attempt >= 4) {
                break;
              }
              await WidgetsBinding.instance.endOfFrame;
            }
            if (!mounted) return;

            if (target < 0) {
              if (_scrollController.hasClients) {
                _scrollController.jumpTo(0);
              }
            } else {
              _scrollToEntry(target);
            }
          });
        }

        return _buildDiffScaffold(diff, viewMode, origName, modName, heights);
      },
    );
  }

  // ==================== 内容宽度（不换行模式横向滚动用） ====================

  double _getContentWidth(DiffResult diff, ViewMode mode, double viewportW) {
    final noWrap = ref.read(noWrapProvider);
    if (!noWrap) return viewportW;

    final bodySize = ref.read(bodyFontSizeProvider);
    final showLine = ref.read(showLineNumbersProvider);
    final rev = ref.read(importRevisionProvider);
    final configKey =
        '${viewportW.round()}|${bodySize.round()}|$showLine|${mode.name}|$rev';

    if (identical(_cachedContentWidthFor, diff) &&
        _cachedContentWidthConfig == configKey &&
        _cachedContentWidth != null) {
      return _cachedContentWidth!;
    }

    // 估算字符宽度：中文约 1.0×bodySize，英文约 0.5×bodySize，取 0.75 折中。
    final charWidth = bodySize * 0.75;
    final numW = showLine ? 44.0 : 16.0;
    final pad = 30.0;

    double computed;

    if (mode == ViewMode.merged) {
      var maxChars = 0;
      for (final ei in cachedMergedOrder(diff)) {
        final t = diff.entries[ei].text;
        if (t.length > maxChars) maxChars = t.length;
      }
      computed = numW + maxChars * charWidth + pad;
    } else {
      final rows = mode == ViewMode.sideBySide
          ? cachedAlignedRows(diff)
          : (mode == ViewMode.diffOnlyPlain
              ? cachedDiffOnlyPlainRows(diff)
              : cachedDiffOnlyRows(diff));
      var maxL = 0;
      var maxR = 0;
      for (final spec in rows) {
        if (spec.del != null) {
          final t = diff.entries[spec.del!].text;
          if (t.length > maxL) maxL = t.length;
        }
        if (spec.ins != null) {
          final t = diff.entries[spec.ins!].text;
          if (t.length > maxR) maxR = t.length;
        }
      }
      final panelChars = maxL > maxR ? maxL : maxR;
      final panelW = numW + panelChars * charWidth + pad;
      computed = panelW * 2 + 1; // +1 = 中间分隔线
    }

    if (computed < viewportW) computed = viewportW;

    _cachedContentWidth = computed;
    _cachedContentWidthFor = diff;
    _cachedContentWidthConfig = configKey;
    return computed;
  }

  // ==================== 视图（可选横向滚动包裹） ====================

  Widget _buildActiveView(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
    _HeightBundle heights,
    bool noWrap,
  ) {
    final Widget inner = switch (viewMode) {
      ViewMode.merged => MergedView(
          result: diff,
          heightTable: heights.merged ?? LineHeightTable.empty,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          noWrap: noWrap,
          onLongPressEntry: (i) => _onRowLongPress([i]),
        ),
      ViewMode.sideBySide => SideBySideView(
          result: diff,
          syncHeightTable: heights.sbsSync ?? LineHeightTable.empty,
          leftHeightTable: heights.sbsLeft ?? LineHeightTable.empty,
          rightHeightTable: heights.sbsRight ?? LineHeightTable.empty,
          originalFileName: origName,
          modifiedFileName: modName,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          syncScroll: ref.watch(syncScrollProvider),
          noWrap: noWrap,
          onLongPressEntry: _onRowLongPress,
        ),
      ViewMode.diffOnly => DiffOnlyView(
          result: diff,
          heightTable: heights.diffOnly ?? LineHeightTable.empty,
          originalFileName: origName,
          modifiedFileName: modName,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          noWrap: noWrap,
          onLongPressEntry: _onRowLongPress,
        ),
      ViewMode.diffOnlyPlain => DiffOnlyPlainView(
          result: diff,
          heightTable: heights.diffOnlyPlain ?? LineHeightTable.empty,
          originalFileName: origName,
          modifiedFileName: modName,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          noWrap: noWrap,
          onLongPressEntry: _onRowLongPress,
        ),
    };

    if (!noWrap) return inner;

    final screenW = MediaQuery.of(context).size.width;
    final contentW = _getContentWidth(diff, viewMode, screenW);
    if (contentW <= screenW + 1) return inner;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _hScrollController,
      child: SizedBox(
        width: contentW,
        child: inner,
      ),
    );
  }

  Widget _buildDiffScaffold(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
    _HeightBundle heights,
  ) {
    final noWrap = ref.watch(noWrapProvider);
    final diffBlocks = _diffBlockCount(diff);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '对比结果',
          style: TextStyle(fontSize: 11),
        ),
        actions: [
          Tooltip(
            message: '上一处差异\n长按：跳到文档开头',
            child: InkWell(
              key: const Key('prev-diff'),
              onTap: _jumpToPrevDiff,
              onLongPress: _jumpToDocTop,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Icon(Icons.arrow_upward, size: 26),
              ),
            ),
          ),
          Tooltip(
            message: '下一处差异\n长按：跳到文档结尾',
            child: InkWell(
              key: const Key('next-diff'),
              onTap: _jumpToNextDiff,
              onLongPress: _jumpToDocBottom,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Icon(Icons.arrow_downward, size: 26),
              ),
            ),
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
              } else if (v == 'noWrap') {
                final cur = ref.read(noWrapProvider);
                ref.read(noWrapProvider.notifier).state = !cur;
                // 切换不换行时重置横向滚动位置。
                if (_hScrollController.hasClients) {
                  _hScrollController.jumpTo(0);
                }
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
                value: 'noWrap',
                child: Row(
                  children: [
                    Icon(noWrap ? Icons.wrap_text : Icons.notes),
                    const SizedBox(width: 10),
                    Text(noWrap ? '关闭不换行' : '开启不换行'),
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
          if (diffBlocks < 6) _buildFewDiffsBanner(diffBlocks),
          if (_showFind) _buildFindBar(),
          if (ref.watch(showPerfOverlayProvider)) _buildPerfOverlay(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _viewChip(
                    label: '差异上下文行',
                    value: ViewMode.diffOnly,
                    current: viewMode,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: _viewChip(
                    label: '纯差异',
                    value: ViewMode.diffOnlyPlain,
                    current: viewMode,
                  ),
                ),
                Expanded(
                  flex: 1,
                  child: _viewChip(
                    label: '并排',
                    value: ViewMode.sideBySide,
                    current: viewMode,
                    compact: true,
                  ),
                ),
                Expanded(
                  flex: 1,
                  child: _viewChip(
                    label: '合并',
                    value: ViewMode.merged,
                    current: viewMode,
                    compact: true,
                  ),
                ),
              ],
            ),
          ),
          _buildToolbar(),
          if (_processing) _buildProcessingBanner(),
          Expanded(
            child: _buildActiveView(
              diff,
              viewMode,
              origName,
              modName,
              heights,
              noWrap,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 按钮栏 ====================

  Widget _buildToolbar() {
    final rules = ref.watch(toolbarRulesOrderedProvider);
    final colors = ref.watch(toolbarButtonColorsProvider);
    final s = Theme.of(context).colorScheme;

    return Container(
      height: 32,
      color: s.surfaceVariant.withOpacity(0.25),
      child: Row(
        children: [
          Expanded(
            child: rules.isEmpty
                ? Center(
                    child: Text(
                      '点 + 添加按钮（长按编辑）',
                      style: TextStyle(
                        fontSize: 10,
                        color: s.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    itemCount: rules.length,
                    itemBuilder: (ctx, i) {
                      final r = rules[i];
                      final c = colors[r.id];
                      final bg = c?.bg ?? s.primaryContainer;
                      final fg = c?.fg ?? s.onPrimaryContainer;
                      final border =
                          c?.border ?? s.primary.withOpacity(0.3);
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 1,
                          vertical: 4,
                        ),
                        child: GestureDetector(
                          onTap: () => _onToolbarButtonTap(r),
                          onLongPress: () => _editToolbarRule(r),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: border),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: fg,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SizedBox(
            width: 28,
            child: IconButton(
              icon: const Icon(Icons.add, size: 16),
              padding: EdgeInsets.zero,
              tooltip: '新建按钮',
              visualDensity: VisualDensity.compact,
              onPressed: _addToolbarRule,
            ),
          ),
          SizedBox(
            width: 28,
            child: IconButton(
              icon: const Icon(Icons.sort, size: 16),
              padding: EdgeInsets.zero,
              tooltip: '排序按钮',
              visualDensity: VisualDensity.compact,
              onPressed: _showToolbarOrderDialog,
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewChip({
    required String label,
    required ViewMode value,
    required ViewMode current,
    bool compact = false,
  }) {
    final selected = value == current;
    final s = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _switchView(value),
      child: Container(
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? s.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? s.primary : s.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingBanner() {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        _processingText,
        style: TextStyle(
          fontSize: 12,
          color: s.onTertiaryContainer,
        ),
      ),
    );
  }

  Future<void> _onToolbarButtonTap(PreprocessingRule rule) async {
    final side = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '「${rule.name}」应用到：',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('只改左侧文件'),
              onTap: () => Navigator.pop(c, 'left'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_forward),
              title: const Text('只改右侧文件'),
              onTap: () => Navigator.pop(c, 'right'),
            ),
            ListTile(
              leading: const Icon(Icons.compare_arrows),
              title: const Text('两侧都改'),
              onTap: () => Navigator.pop(c, 'both'),
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
    if (side == null || !mounted) return;
    await _applyToolbarRule(rule, side);
  }

  Future<void> _applyToolbarRule(PreprocessingRule rule, String side) async {
    setState(() {
      _processing = true;
      _processingText = '正在执行「${rule.name}」…';
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    try {
      final currentOrig = ref.read(preprocessedOriginalProvider);
      final currentMod = ref.read(preprocessedModifiedProvider);

      if (side == 'left' || side == 'both') {
        if (currentOrig.isNotEmpty) {
          final next = applyOneRule(currentOrig, rule);
          ref.read(editedOriginalProvider.notifier).state = next;
        }
      }
      if (side == 'right' || side == 'both') {
        if (currentMod.isNotEmpty) {
          final next = applyOneRule(currentMod, rule);
          ref.read(editedModifiedProvider.notifier).state = next;
        }
      }

      ref.read(importRevisionProvider.notifier).state++;
      _resetViewAfterEdit();

      if (!mounted) return;
      _toast('已应用「${rule.name}」');
    } catch (e) {
      if (mounted) _toast('执行失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _processingText = '';
        });
      }
    }
  }

  Future<void> _addToolbarRule() async {
    final rule = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => const RuleEditorDialog(
        showCopyToPreprocess: false,
      ),
    );
    if (rule == null || !mounted) return;
    ref.read(toolbarRulesProvider.notifier).add(rule);
    _toast('已添加按钮「${rule.name}」');
  }

  Future<void> _editToolbarRule(PreprocessingRule rule) async {
    final updated = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => RuleEditorDialog(
        initial: rule,
        showCopyToPreprocess: true,
        onCopyToPreprocess: (copied) {
          _toast('「${copied.name}」已复制到预处理规则');
        },
      ),
    );
    if (updated == null || !mounted) return;
    ref.read(toolbarRulesProvider.notifier).updateRule(updated);
  }

  Future<void> _showToolbarOrderDialog() async {
    final rules = ref.read(toolbarRulesOrderedProvider);
    if (rules.isEmpty) {
      _toast('还没有按钮');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => _ToolbarOrderDialog(rules: rules),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: Colors.amber.shade900),
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

  Widget _buildFewDiffsBanner(int blocks) {
    return Container(
      width: double.infinity,
      color: Colors.pink.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline,
              size: 14, color: Colors.pink.shade900),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              blocks == 0
                  ? '两份文档完全相同'
                  : '共 $blocks 处差异，已全部显示',
              style: TextStyle(
                fontSize: 12,
                color: Colors.pink.shade900,
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: '查找历史',
                  visualDensity: VisualDensity.compact,
                  onPressed: _showFindHistory,
                ),
              ],
            ),
            if (_noResultHint != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4, bottom: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  border: Border.all(color: Colors.orange.shade200),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: Colors.orange.shade800),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _noResultHint!,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
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

class _ToolbarOrderDialog extends ConsumerStatefulWidget {
  const _ToolbarOrderDialog({required this.rules});

  final List<PreprocessingRule> rules;

  @override
  ConsumerState<_ToolbarOrderDialog> createState() =>
      _ToolbarOrderDialogState();
}

class _ToolbarOrderDialogState extends ConsumerState<_ToolbarOrderDialog> {
  late List<PreprocessingRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = List<PreprocessingRule>.from(widget.rules);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: const Text('按钮排序'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.7,
        child: ReorderableListView.builder(
          itemCount: _rules.length,
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final item = _rules.removeAt(oldIndex);
              _rules.insert(newIndex, item);
            });
          },
          itemBuilder: (ctx, i) {
            final r = _rules[i];
            return ListTile(
              key: ValueKey<String>('order:${r.id}'),
              leading: const Icon(Icons.drag_handle),
              title: Text(r.name),
              subtitle: Text(
                ruleSubtitle(r),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '设置颜色',
                    icon: const Icon(Icons.palette),
                    onPressed: () => _openColorPanel(r),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() => _rules.removeAt(i));
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _openColorPanel(PreprocessingRule r) {
    showDialog<void>(
      context: context,
      builder: (_) => _ButtonColorDialog(
        ruleId: r.id,
        ruleName: r.name,
      ),
    );
  }

  void _save() {
    ref
        .read(toolbarOrderProvider.notifier)
        .setAll(_rules.map((r) => r.id).toList());
    ref.read(toolbarRulesProvider.notifier).setAll(_rules);

    // 清理已被删除的按钮的颜色设置。
    final newIds = _rules.map((r) => r.id).toSet();
    final oldIds = widget.rules.map((r) => r.id).toSet();
    final removedIds = oldIds.difference(newIds);
    for (final id in removedIds) {
      ref.read(toolbarButtonColorsProvider.notifier).remove(id);
    }

    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
  }
}

// ==================== 按钮颜色面板 ====================

class _ButtonColorDialog extends ConsumerStatefulWidget {
  const _ButtonColorDialog({
    required this.ruleId,
    required this.ruleName,
  });

  final String ruleId;
  final String ruleName;

  @override
  ConsumerState<_ButtonColorDialog> createState() =>
      _ButtonColorDialogState();
}

class _ButtonColorDialogState extends ConsumerState<_ButtonColorDialog> {
  @override
  Widget build(BuildContext context) {
    final all = ref.watch(toolbarButtonColorsProvider);
    final c = all[widget.ruleId] ?? const ToolbarButtonColor();
    final s = Theme.of(context).colorScheme;

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: Text(
        '${widget.ruleName} · 按钮颜色',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _colorRow(
              context: context,
              label: '背景色',
              isSet: c.bg != null,
              color: c.bg ?? s.primaryContainer,
              onPick: (v) => _setBg(v),
            ),
            _colorRow(
              context: context,
              label: '文字色',
              isSet: c.fg != null,
              color: c.fg ?? s.onPrimaryContainer,
              onPick: (v) => _setFg(v),
            ),
            _colorRow(
              context: context,
              label: '边框色',
              isSet: c.border != null,
              color: c.border ?? s.primary.withOpacity(0.3),
              onPick: (v) => _setBorder(v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  void _setBg(Color? color) {
    final all = ref.read(toolbarButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const ToolbarButtonColor();
    ref.read(toolbarButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          ToolbarButtonColor(bg: color, fg: cur.fg, border: cur.border),
        );
  }

  void _setFg(Color? color) {
    final all = ref.read(toolbarButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const ToolbarButtonColor();
    ref.read(toolbarButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          ToolbarButtonColor(bg: cur.bg, fg: color, border: cur.border),
        );
  }

  void _setBorder(Color? color) {
    final all = ref.read(toolbarButtonColorsProvider);
    final cur = all[widget.ruleId] ?? const ToolbarButtonColor();
    ref.read(toolbarButtonColorsProvider.notifier).setOne(
          widget.ruleId,
          ToolbarButtonColor(bg: cur.bg, fg: cur.fg, border: color),
        );
  }

  Widget _colorRow({
    required BuildContext context,
    required String label,
    required bool isSet,
    required Color color,
    required void Function(Color?) onPick,
  }) {
    final s = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isSet ? colorToHex(color) : '默认',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: isSet ? s.onSurface : s.outline,
            ),
          ),
          const SizedBox(width: 4),
          if (isSet)
            SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: '清空（回到默认）',
                icon: const Icon(Icons.close, size: 14),
                onPressed: () => onPick(null),
              ),
            ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () async {
              final picked = await _pickColorDialog(context, color);
              if (picked != null) onPick(picked);
            },
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(color: s.outline),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用取色弹窗。返回选中的颜色；用户取消返回 null。
Future<Color?> _pickColorDialog(BuildContext context, Color initial) async {
  var picked = initial;
  final controller = TextEditingController(text: colorToHex(picked));

  return showDialog<Color>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setDialogState) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: const Text('选择颜色'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
            onPressed: () => Navigator.pop(c, picked),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

// ==================== 查找历史弹窗 ====================

class _FindHistoryDialog extends ConsumerWidget {
  const _FindHistoryDialog({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(findHistoryProvider);

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: const Text('查找历史'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.7,
        child: history.isEmpty
            ? const Center(child: Text('还没有查找记录'))
            : ListView.builder(
                itemCount: history.length,
                itemBuilder: (ctx, i) {
                  final q = history[i];
                  return ListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    title: Text(
                      q,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: '删除',
                      onPressed: () {
                        ref.read(findHistoryProvider.notifier).remove(q);
                      },
                    ),
                    onTap: () {
                      onPick(q);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
