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

  // ==================== 长按：复制 / 就地编辑 ====================

  /// 计算每个 entry 对应的原/改行号（预处理后），-1 表示该侧不涉及。
  /// 逻辑和视图里的 _lineMeta 一致，这里独立一份。
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

  /// 把某侧 raw 文本的第 [normalizedLine] 行替换为 [newText]，写回 provider。
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

  /// 长按某一行的入口。entryIndices 是这一行关联的 entry 下标：
  /// 合并视图传 [ei]；并排/仅差异传 [delIdx, insIdx]（可能是单元素）。
  Future<void> _onRowLongPress(List<int> entryIndices) async {
    final diff = _diff;
    if (diff == null || entryIndices.isEmpty) return;

    // 分类出"原文侧"和"修改侧"各自的 entry。
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

    String? origText;
    String? modText;
    int? origLine;
    int? modLine;

    if (origEntryIdx != null) {
      final e = diff.entries[origEntryIdx];
      origText = (e.operation == DiffOperation.replace &&
              e.oldText.isNotEmpty)
          ? e.oldText
          : e.text;
      final m = meta[origEntryIdx].orig;
      if (m >= 0) origLine = m;
    }
    if (modEntryIdx != null) {
      final e = diff.entries[modEntryIdx];
      modText = (e.operation == DiffOperation.replace &&
              e.newText.isNotEmpty)
          ? e.newText
          : e.text;
      final m = meta[modEntryIdx].mod;
      if (m >= 0) modLine = m;
    }

    // 弹底部菜单：复制 / 编辑。
    final action = await _showRowActionSheet(
      origText: origText,
      modText: modText,
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'copyOrig':
        if (origText != null) {
          await Clipboard.setData(ClipboardData(text: origText));
          if (mounted) _toast('已复制原版此行');
        }
        return;
      case 'copyMod':
        if (modText != null) {
          await Clipboard.setData(ClipboardData(text: modText));
          if (mounted) _toast('已复制修改版此行');
        }
        return;
      case 'edit':
        break;
      default:
        return;
    }

    // 编辑：弹对话框。
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

    // 触发 diff 重算 + 重置视图，并按行号锚回原位置。
    ref.read(importRevisionProvider.notifier).state++;
    _resetViewAfterEdit(
      anchorOrigLine: origLine,
      anchorModLine: modLine,
    );
  }

  /// 底部菜单。哪侧有内容就显示对应的复制项。
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
                title: const Text('复制原版此行'),
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
                title: const Text('复制修改版此行'),
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

  /// 弹出编辑对话框。哪侧有内容就显示哪个输入框。
  /// 返回 (orig, mod)；取消返回 null。
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
                const Text('原版'),
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
                const Text('修改版'),
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

  /// 编辑后重置视图状态，并按行号锚回原位置。
  /// 只改内容不改行数时，行号保持不变，视图基本停在原处。
  void _resetViewAfterEdit({int? anchorOrigLine, int? anchorModLine}) {
    _currentDiffPos = -1;
    _anchorEntryIndex = null;
    _matchEntries = const <int>[];
    _matchPos = -1;
    _findController.clear();
    _findQuery = '';
    _rowKeysByEntry.clear();
    _cachedDiffIndices = null;
    _cachedDiffIndicesFor = null;
    setState(() {});

    if (anchorOrigLine == null && anchorModLine == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
      });
      return;
    }

    _scrollToLineAfterRecompute(anchorOrigLine, anchorModLine);
  }

  /// diff 重算需要时间（大文件可能几百毫秒），这里轮询等待新结果，
  /// 找到对应行号的 entry 后滚过去。最多等 3 秒。
  Future<void> _scrollToLineAfterRecompute(
    int? origLine,
    int? modLine,
  ) async {
    // 先等一下，让 provider 进入 recompute 状态
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (var attempt = 0; attempt < 30; attempt++) {
      if (!mounted) return;
      final diff = _diff;
      if (diff != null) {
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
                      onLongPressEntry: (i) => _onRowLongPress([i]),
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
                      onLongPressEntry: _onRowLongPress,
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
