// grouped_diff_page.dart
//
// 跨行块视图的独立页面。自带顶栏、菜单、规则栏、查找栏。
// 不依赖 diff_viewer_screen 的任何私有状态。

import 'dart:async';
import 'dart:io';

import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../diff/domain/diff_operation.dart';
import '../../diff/domain/diff_result.dart';
import '../../edit/presentation/edit_screen.dart';
import '../../file_browser/presentation/comparison_settings_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/application/preprocessing_service.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';
import 'diagnostic_screen.dart';
import 'line_height_calculator.dart';
import 'providers/diff_viewer_providers.dart';
import 'providers/toolbar_rules_provider.dart';
import 'viewer_widgets.dart';

// ==================== 颜色 ====================

const Color _kEqualIgnoringWsBg = Color(0xFFF7FAFF);
const Color _kDiffLeftBg = Color(0xFFFFEEEE);
const Color _kDiffRightBg = Color(0xFFEEFFEE);
const Color _kCharHighlight = Color(0xFFEF6C00);
const Color _kWsHighlight = Color(0xFFFFD600);

const int _kMaxLinesPerChunk = 25;

// ==================== 高亮缓存 ====================

final Map<String, List<List<int>>> _hlCache = {};
const int _hlCacheMax = 200;

String _hlKey(String self, String other) =>
    '${self.length}:${other.length}:${self.hashCode}:${other.hashCode}';

List<List<int>> _hlCached(
  String selfBlob,
  int selfLines,
  String otherBlob,
  bool onlyWs,
) {
  final key = _hlKey(selfBlob, otherBlob) + ':$onlyWs';
  final hit = _hlCache[key];
  if (hit != null) return hit;
  if (_hlCache.length >= _hlCacheMax) {
    _hlCache.remove(_hlCache.keys.first);
  }
  final result = _blobHighlight(selfBlob, selfLines, otherBlob, onlyWs);
  _hlCache[key] = result;
  return result;
}

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
    final l = leftLength;
    final r = rightLength;
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
      final la = linesA[ai];
      final ra = linesB[bi];
      if (la == ra) {
        raw.add(GroupedBlock(
          leftStart: ai, leftEnd: ai + 1,
          rightStart: bi, rightEnd: bi + 1,
          kind: GroupedBlockKind.equal,
        ));
      } else if (_strip(la) == _strip(ra)) {
        raw.add(GroupedBlock(
          leftStart: ai, leftEnd: ai + 1,
          rightStart: bi, rightEnd: bi + 1,
          kind: GroupedBlockKind.equalIgnoringWs,
        ));
      } else {
        raw.add(GroupedBlock(
          leftStart: ai, leftEnd: ai + 1,
          rightStart: bi, rightEnd: bi + 1,
          kind: GroupedBlockKind.different,
        ));
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
        raw.add(GroupedBlock(
          leftStart: sA, leftEnd: eA,
          rightStart: sB, rightEnd: eB,
          kind: sameWs
              ? GroupedBlockKind.equalIgnoringWs
              : GroupedBlockKind.different,
        ));
      } else if (eA > sA) {
        raw.add(GroupedBlock(
          leftStart: sA, leftEnd: eA,
          rightStart: sB, rightEnd: sB,
          kind: GroupedBlockKind.different,
        ));
      } else if (eB > sB) {
        raw.add(GroupedBlock(
          leftStart: sA, leftEnd: sA,
          rightStart: sB, rightEnd: eB,
          kind: GroupedBlockKind.different,
        ));
      }
    }
  }

  // 切块
  final blocks = <GroupedBlock>[];
  for (final b in raw) {
    if (b.visualLength <= _kMaxLinesPerChunk) {
      blocks.add(b);
      continue;
    }
    var l = b.leftStart, r = b.rightStart;
    while (l < b.leftEnd || r < b.rightEnd) {
      final lRem = b.leftEnd - l;
      final rRem = b.rightEnd - r;
      final lTake = lRem > _kMaxLinesPerChunk ? _kMaxLinesPerChunk : lRem;
      final rTake = rRem > _kMaxLinesPerChunk ? _kMaxLinesPerChunk : rRem;
      blocks.add(GroupedBlock(
        leftStart: l, leftEnd: l + lTake,
        rightStart: r, rightEnd: r + rTake,
        kind: b.kind,
      ));
      l += lTake;
      r += rTake;
    }
  }

  return GroupedDiffData(linesA: linesA, linesB: linesB, blocks: blocks);
}

List<List<int>> _blobHighlight(
  String selfBlob, int selfLines, String otherBlob, bool onlyWs,
) {
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
            if (starts[mid] <= p) {
              lo = mid;
            } else {
              hi = mid - 1;
            }
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

// ==================== 页面 ====================

class GroupedDiffPage extends ConsumerStatefulWidget {
  const GroupedDiffPage({super.key});

  @override
  ConsumerState<GroupedDiffPage> createState() => _GroupedDiffPageState();
}

class _GroupedDiffPageState extends ConsumerState<GroupedDiffPage> {
  late final ScrollController _leftCtrl;
  late final ScrollController _rightCtrl;
  bool _syncing = false;
  bool _landscape = false;

  GroupedDiffData? _data;
  DiffResult? _dataForDiff;
  List<GroupedBlock>? _visible;
  final Map<int, double> _chunkHeights = {};
  double? _cacheWidth;
  double? _cacheFont;
  TextScaler? _cacheScaler;

  // 查找
  bool _showFind = false;
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();
  String _findQuery = '';
  List<({int blockIdx, bool isLeft})> _matches = const [];
  int _matchPos = -1;
  Timer? _findDebounce;

  // 长按编辑
  final Map<int, String> _pendingOrig = {};
  final Map<int, String> _pendingMod = {};

  bool _processing = false;
  String _processingText = '';

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
    _findDebounce?.cancel();
    _leftCtrl.removeListener(_syncL);
    _rightCtrl.removeListener(_syncR);
    _leftCtrl.dispose();
    _rightCtrl.dispose();
    _findController.dispose();
    _replaceController.dispose();
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
        _rightCtrl.position.maxScrollExtent,
      ));
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
        _leftCtrl.position.maxScrollExtent,
      ));
    } catch (_) {}
    _syncing = false;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final diffAsync = ref.watch(diffResultProvider);
    final a = ref.watch(preprocessedOriginalProvider);
    final b = ref.watch(preprocessedModifiedProvider);

    return diffAsync.when(
      loading: () => Scaffold(
        appBar: _buildAppBar(null),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: _buildAppBar(null),
        body: Center(child: Text('错误：$e')),
      ),
      data: (diff) {
        if (diff == null) {
          return Scaffold(
            appBar: _buildAppBar(null),
            body: const Center(child: Text('请先导入两份文档')),
          );
        }
        if (!identical(_dataForDiff, diff)) {
          _dataForDiff = diff;
          _data = buildGroupedData(diff, a, b);
          _visible = null;
          _chunkHeights.clear();
          _matches = const [];
          _matchPos = -1;
        }
        return _buildScaffold(_data!);
      },
    );
  }

  Widget _buildScaffold(GroupedDiffData data) {
    final viewMode = ref.watch(viewModeProvider);
    return Scaffold(
      appBar: _buildAppBar(data),
      body: Column(
        children: [
          _buildBanners(data),
          if (_showFind) _buildFindBar(),
          _buildChips(viewMode),
          _buildToolbar(),
          if (_processing) _buildProcessingBanner(),
          Expanded(child: _buildContent(data)),
        ],
      ),
    );
  }

  // ==================== AppBar ====================

  PreferredSizeWidget _buildAppBar(GroupedDiffData? data) {
    final ruleCount = ref.watch(toolbarRulesOrderedProvider).length;
    return AppBar(
      toolbarHeight: 43,
      titleSpacing: 1,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _appBarBtn(
            key: const Key('g-page-up'),
            onTap: _pageUp,
            onLongPress: _jumpToTop,
            child: Builder(builder: (ctx) {
              final c = IconTheme.of(ctx).color ?? Colors.black;
              return CustomPaint(
                size: const Size.square(24),
                painter: _PageUpIconPainter(color: c),
              );
            }),
          ),
          _appBarBtn(
            key: const Key('g-page-down'),
            onTap: _pageDown,
            onLongPress: _jumpToBottom,
            child: Builder(builder: (ctx) {
              final c = IconTheme.of(ctx).color ?? Colors.black;
              return CustomPaint(
                size: const Size.square(24),
                painter: _PageDownIconPainter(color: c),
              );
            }),
          ),
        ],
      ),
      actions: [
        _appBarBtn(
          onTap: _jumpToPrevDiff,
          onLongPress: _jumpToTop,
          child: const Icon(Icons.arrow_upward, size: 26),
        ),
        _appBarBtn(
          onTap: _jumpToNextDiff,
          onLongPress: _jumpToBottom,
          child: const Icon(Icons.arrow_downward, size: 26),
        ),
        _appBarBtn(
          onTap: () => setState(() => _showFind = !_showFind),
          child: const Icon(Icons.search, size: 26),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.tune),
          tooltip: '更多操作',
          onSelected: _onMenu,
          itemBuilder: (c) => [
            const PopupMenuItem(value: 'edit', child: Row(
              children: [Icon(Icons.edit), SizedBox(width: 10),
                Text('编辑对比中的2个文档')],
            )),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'displaySettings', child: Row(
              children: [Icon(Icons.format_size), SizedBox(width: 10),
                Text('显示设置')],
            )),
            const PopupMenuItem(value: 'comparisonSettings', child: Row(
              children: [Icon(Icons.rule), SizedBox(width: 10),
                Text('比较设置')],
            )),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'diag', child: Row(
              children: [Icon(Icons.bug_report), SizedBox(width: 10),
                Text('诊断')],
            )),
            PopupMenuItem(value: 'orientation', child: Row(
              children: [
                Icon(_landscape ? Icons.screen_rotation : Icons.rotate_left),
                const SizedBox(width: 10),
                Text(_landscape ? '切换到竖屏' : '切换到横屏'),
              ],
            )),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'delOriginal',
              child: const Row(children: [
                Icon(Icons.delete_outline, color: Colors.red),
                SizedBox(width: 10),
                Text('删除左边文件'),
              ]),
            ),
            PopupMenuItem(
              value: 'delModified',
              child: const Row(children: [
                Icon(Icons.delete_outline, color: Colors.red),
                SizedBox(width: 10),
                Text('删除右边文件'),
              ]),
            ),
          ],
        ),
      ],
    );
  }

  Widget _appBarBtn({
    Key? key,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    required Widget child,
  }) {
    return SizedBox(
      width: 56,
      height: 42,
      child: InkWell(
        key: key,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }

  // ==================== 横幅 ====================

  Widget _buildBanners(GroupedDiffData data) {
    final encA = ref.watch(originalEncodingProvider);
    final encB = ref.watch(modifiedEncodingProvider);
    final diffCount = data.blocks
        .where((b) => b.kind != GroupedBlockKind.equal)
        .length;
    final rows = <Widget>[];
    if (encA != encB) {
      rows.add(Container(
        width: double.infinity,
        color: Colors.amber.shade50,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text('两份文件编码不同（$encA / $encB）',
            style: TextStyle(fontSize: 11, color: Colors.amber.shade900)),
      ));
    }
    if (diffCount < 6) {
      rows.add(Container(
        width: double.infinity,
        color: Colors.green.shade800,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(children: [
          const Icon(Icons.check_circle_outline, size: 20, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              diffCount == 0
                  ? '两份文档完全相同'
                  : '共 $diffCount 处差异，已全部显示',
              style: const TextStyle(
                  fontSize: 15, color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
      ));
    }
    return Column(children: rows);
  }

  Widget _buildProcessingBanner() {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(_processingText,
          style: TextStyle(fontSize: 12, color: s.onTertiaryContainer)),
    );
  }

  // ==================== chips ====================

  Widget _buildChips(ViewMode current) {
    Widget chip(String label, ViewMode v, {int flex = 3, bool compact = false}) {
      final sel = v == current;
      final s = Theme.of(context).colorScheme;
      return Expanded(
        flex: flex,
        child: GestureDetector(
          onTap: () => _switchView(v),
          child: Container(
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: sel ? s.primary : Colors.transparent,
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
                fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                color: sel ? s.primary : s.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          chip('差异行+上下2行', ViewMode.diffOnly),
          chip('仅显示差异行', ViewMode.diffOnlyPlain),
          chip('并排', ViewMode.sideBySide, flex: 1, compact: true),
          chip('上下', ViewMode.merged, flex: 1, compact: true),
          chip('跨行块', ViewMode.grouped, flex: 2, compact: true),
        ],
      ),
    );
  }

  void _switchView(ViewMode v) {
    if (v == ViewMode.grouped) return;
    ref.read(viewModeProvider.notifier).state = v;
    Navigator.of(context).pop();
  }

  // ==================== 规则栏 ====================

  Widget _buildToolbar() {
    final rules = ref.watch(toolbarRulesOrderedProvider);
    final colors = ref.watch(toolbarButtonColorsProvider);
    final s = Theme.of(context).colorScheme;
    return Container(
      height: 42,
      color: s.surfaceVariant.withOpacity(0.25),
      child: Row(
        children: [
          Expanded(
            child: rules.isEmpty
                ? Center(
                    child: Text('点 + 添加按钮（长按编辑）',
                        style: TextStyle(
                            fontSize: 10, color: s.onSurfaceVariant)),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    itemCount: rules.length,
                    itemBuilder: (ctx, i) {
                      final r = rules[i];
                      final c = colors[r.id];
                      final bg = c?.bg ?? Colors.white;
                      final fg = c?.fg ?? Colors.black;
                      final border =
                          c?.border ?? Colors.black.withOpacity(0.5);
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 1, vertical: 3),
                        child: GestureDetector(
                          onTap: () => _onToolbarTap(r),
                          onLongPress: () => _editToolbarRule(r),
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 2),
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
                                  fontSize: 11, color: fg,
                                  fontWeight: FontWeight.w500),
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

  Future<void> _onToolbarTap(PreprocessingRule rule) async {
    final side = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text('「${rule.name}」应用到：',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
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
      final o = ref.read(preprocessedOriginalProvider);
      final m = ref.read(preprocessedModifiedProvider);
      if ((side == 'left' || side == 'both') && o.isNotEmpty) {
        ref.read(editedOriginalProvider.notifier).state = applyOneRule(o, rule);
      }
      if ((side == 'right' || side == 'both') && m.isNotEmpty) {
        ref.read(editedModifiedProvider.notifier).state = applyOneRule(m, rule);
      }
      ref.read(importRevisionProvider.notifier).state++;
      _dataForDiff = null;
      if (mounted) _toast('已应用「${rule.name}」');
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
      builder: (_) => const RuleEditorDialog(showCopyToPreprocess: false),
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
        onCopyToPreprocess: (c) => _toast('「${c.name}」已复制到预处理规则'),
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
      builder: (c) => ToolbarOrderDialog(rules: rules),
    );
  }

  // ==================== 内容 ====================

  Widget _buildContent(GroupedDiffData data) {
    final showLine = ref.watch(showLineNumbersProvider);
    final fontSize = ref.watch(bodyFontSizeProvider);
    final gutterSize = ref.watch(gutterFontSizeProvider);
    final mq = MediaQuery.of(context);
    final viewportW = mq.size.width;
    final halfW = (viewportW - 1) / 2;
    final contentW = halfW - (showLine ? 42.0 : 8.0);

    if (_cacheWidth != contentW ||
        _cacheFont != fontSize ||
        _cacheScaler != mq.textScaler) {
      _chunkHeights.clear();
      _cacheWidth = contentW;
      _cacheFont = fontSize;
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
        Expanded(
          child: _SidePane(
            data: data, blocks: visible, side: _Side.left,
            controller: _leftCtrl, showLineNumbers: showLine,
            bodyFontSize: fontSize, gutterFontSize: gutterSize,
            heightForBlock: _heightForBlock,
            findQuery: _findQuery,
            currentMatchBlock: _matchPos >= 0 && _matchPos < _matches.length
                ? _matches[_matchPos].blockIdx : null,
            currentMatchIsLeft: _matchPos >= 0 && _matchPos < _matches.length
                ? _matches[_matchPos].isLeft : null,
            blockIndexOffset: 0,
          ),
        ),
        divider,
        Expanded(
          child: _SidePane(
            data: data, blocks: visible, side: _Side.right,
            controller: _rightCtrl, showLineNumbers: showLine,
            bodyFontSize: fontSize, gutterFontSize: gutterSize,
            heightForBlock: _heightForBlock,
            findQuery: _findQuery,
            currentMatchBlock: _matchPos >= 0 && _matchPos < _matches.length
                ? _matches[_matchPos].blockIdx : null,
            currentMatchIsLeft: _matchPos >= 0 && _matchPos < _matches.length
                ? _matches[_matchPos].isLeft : null,
            blockIndexOffset: 0,
          ),
        ),
      ],
    );
  }

  double _heightForBlock(int blockIndex) {
    final cached = _chunkHeights[blockIndex];
    if (cached != null) return cached;
    final visible = _visible;
    final data = _data;
    if (visible == null || data == null ||
        blockIndex < 0 || blockIndex >= visible.length) {
      return 24.0;
    }
    final b = visible[blockIndex];
    final width = _cacheWidth ?? 100.0;
    final scaler = _cacheScaler ?? TextScaler.noScaling;
    final style = TextStyle(
      fontSize: ref.read(bodyFontSizeProvider), height: 1.35);
    double lh = 0;
    for (var i = b.leftStart; i < b.leftEnd; i++) {
      if (i < 0 || i >= data.linesA.length) continue;
      lh += measureTextHeight(
        text: data.linesA[i].isEmpty ? ' ' : data.linesA[i],
        maxWidth: width, style: style, textScaler: scaler,
      );
    }
    double rh = 0;
    for (var i = b.rightStart; i < b.rightEnd; i++) {
      if (i < 0 || i >= data.linesB.length) continue;
      rh += measureTextHeight(
        text: data.linesB[i].isEmpty ? ' ' : data.linesB[i],
        maxWidth: width, style: style, textScaler: scaler,
      );
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

  // ==================== 翻屏 / 跳转 ====================

  void _pageUp() {
    if (!_leftCtrl.hasClients) return;
    final p = _leftCtrl.position;
    final t = (p.pixels - p.viewportDimension * 0.95)
        .clamp(0.0, p.maxScrollExtent);
    if ((t - p.pixels).abs() < 0.5) return;
    _leftCtrl.jumpTo(t);
  }

  void _pageDown() {
    if (!_leftCtrl.hasClients) return;
    final p = _leftCtrl.position;
    final t = (p.pixels + p.viewportDimension * 0.95)
        .clamp(0.0, p.maxScrollExtent);
    if ((t - p.pixels).abs() < 0.5) return;
    _leftCtrl.jumpTo(t);
  }

  void _jumpToTop() {
    if (_leftCtrl.hasClients) _leftCtrl.jumpTo(0);
  }

  void _jumpToBottom() {
    if (_leftCtrl.hasClients) {
      _leftCtrl.jumpTo(_leftCtrl.position.maxScrollExtent);
    }
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

  void _jumpToNextDiff() {
    final visible = _visible;
    if (visible == null || !_leftCtrl.hasClients) return;
    final cur = _currentBlockIdx() ?? -1;
    for (var i = cur + 1; i < visible.length; i++) {
      if (visible[i].kind != GroupedBlockKind.equal) {
        final off = _blockOffset(i);
        _leftCtrl.jumpTo(off.clamp(
            0, _leftCtrl.position.maxScrollExtent));
        return;
      }
    }
    _toast('到底了');
  }

  void _jumpToPrevDiff() {
    final visible = _visible;
    if (visible == null || !_leftCtrl.hasClients) return;
    final cur = _currentBlockIdx() ?? visible.length;
    for (var i = cur - 1; i >= 0; i--) {
      if (visible[i].kind != GroupedBlockKind.equal) {
        final off = _blockOffset(i);
        _leftCtrl.jumpTo(off.clamp(
            0, _leftCtrl.position.maxScrollExtent));
        return;
      }
    }
    _toast('到顶了');
  }

  // ==================== 菜单 ====================

  Future<void> _onMenu(String v) async {
    switch (v) {
      case 'edit':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const EditScreen()),
        );
        _dataForDiff = null;
        if (mounted) setState(() {});
        break;
      case 'displaySettings':
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => const DisplaySettingsSheet(),
        );
        break;
      case 'comparisonSettings':
        await Navigator.of(context).push<bool>(
          MaterialPageRoute<bool>(
            builder: (_) => const ComparisonSettingsScreen(confirmOnExit: true),
          ),
        );
        _dataForDiff = null;
        if (mounted) setState(() {});
        break;
      case 'diag':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const DiagnosticScreen()),
        );
        break;
      case 'orientation':
        setState(() => _landscape = !_landscape);
        await SystemChrome.setPreferredOrientations(_landscape
            ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
            : const [DeviceOrientation.portraitUp]);
        break;
      case 'delOriginal':
        await _deleteSide(true);
        break;
      case 'delModified':
        await _deleteSide(false);
        break;
    }
  }

  Future<void> _deleteSide(bool isOriginal) async {
    final path = ref.read(isOriginal
        ? originalFilePathProvider
        : modifiedFilePathProvider);
    if (path == null) return;
    final label = isOriginal ? '左边文件' : '右边文件';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除$label？'),
        content: Text('路径：$path\n\n删除后无法恢复。'),
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
    if (ok != true || !mounted) return;
    try {
      await File(path).delete();
      if (mounted) _toast('$label 已删除');
    } catch (e) {
      if (mounted) _toast('删除失败：$e');
    }
  }

  // ==================== 查找 ====================

  Widget _buildFindBar() {
    final total = _matches.length;
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
                  onPressed: () => setState(() {
                    _showFind = false;
                    _findQuery = '';
                    _matches = const [];
                    _matchPos = -1;
                    _findController.clear();
                  }),
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
                  ),
                ),
                Text('${_matchPos + 1}/$total',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
            Row(
              children: [
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  visualDensity: VisualDensity.compact,
                  onPressed: total == 0 ? null : _prevMatch,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward),
                  visualDensity: VisualDensity.compact,
                  onPressed: total == 0 ? null : _nextMatch,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _onFindInput(String q) {
    _findDebounce?.cancel();
    _findDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _runFind(q);
    });
  }

  void _runFind(String q) {
    _findQuery = q;
    final data = _data;
    final visible = _visible;
    if (data == null || visible == null || q.isEmpty) {
      setState(() {
        _matches = const [];
        _matchPos = -1;
      });
      return;
    }
    final list = <({int blockIdx, bool isLeft})>[];
    for (var i = 0; i < visible.length; i++) {
      final b = visible[i];
      for (var li = b.leftStart; li < b.leftEnd; li++) {
        if (li < 0 || li >= data.linesA.length) continue;
        if (data.linesA[li].contains(q)) {
          list.add((blockIdx: i, isLeft: true));
          break;
        }
      }
      for (var li = b.rightStart; li < b.rightEnd; li++) {
        if (li < 0 || li >= data.linesB.length) continue;
        if (data.linesB[li].contains(q)) {
          list.add((blockIdx: i, isLeft: false));
          break;
        }
      }
    }
    setState(() {
      _matches = list;
      _matchPos = list.isEmpty ? -1 : 0;
    });
    if (list.isNotEmpty) _scrollToMatch(0);
  }

  void _scrollToMatch(int idx) {
    if (idx < 0 || idx >= _matches.length) return;
    final off = _blockOffset(_matches[idx].blockIdx);
    if (_leftCtrl.hasClients) {
      _leftCtrl.jumpTo(off.clamp(0, _leftCtrl.position.maxScrollExtent));
    }
  }

  void _nextMatch() {
    if (_matches.isEmpty) return;
    setState(() => _matchPos = (_matchPos + 1) % _matches.length);
    _scrollToMatch(_matchPos);
  }

  void _prevMatch() {
    if (_matches.isEmpty) return;
    setState(() => _matchPos = (_matchPos - 1 + _matches.length) % _matches.length);
    _scrollToMatch(_matchPos);
  }
}

// ==================== 侧栏 ====================

enum _Side { left, right }

class _SidePane extends StatelessWidget {
  const _SidePane({
    required this.data, required this.blocks, required this.side,
    required this.controller, required this.showLineNumbers,
    required this.bodyFontSize, required this.gutterFontSize,
    required this.heightForBlock,
    required this.findQuery,
    required this.currentMatchBlock,
    required this.currentMatchIsLeft,
    required this.blockIndexOffset,
  });

  final GroupedDiffData data;
  final List<GroupedBlock> blocks;
  final _Side side;
  final ScrollController? controller;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
  final double Function(int) heightForBlock;
  final String findQuery;
  final int? currentMatchBlock;
  final bool? currentMatchIsLeft;
  final int blockIndexOffset;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
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
            bodyFontSize: bodyFontSize, gutterFontSize: gutterFontSize,
            findQuery: findQuery,
            isCurrentMatch: currentMatchBlock == i &&
                currentMatchIsLeft == (side == _Side.left),
          ),
        );
      },
    );
  }
}

class _BlockTile extends StatelessWidget {
  const _BlockTile({
    required this.block, required this.data, required this.side,
    required this.showLineNumbers, required this.bodyFontSize,
    required this.gutterFontSize,
    required this.findQuery,
    required this.isCurrentMatch,
  });

  final GroupedBlock block;
  final GroupedDiffData data;
  final _Side side;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
  final String findQuery;
  final bool isCurrentMatch;

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

    final bg = _bg();
    final fg = Theme.of(context).textTheme.bodyMedium?.color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white : Colors.black);
    final outline = Theme.of(context).colorScheme.outline;
    final base = TextStyle(fontSize: bodyFontSize, color: fg, height: 1.35);

    final rows = <Widget>[];
    for (var li = start; li < end; li++) {
      if (li < 0 || li >= lines.length) continue;
      final local = li - start;
      final marks = local >= 0 && local < hi.length
          ? hi[local].toSet() : <int>{};
      rows.add(Row(
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
          Expanded(
            child: Text.rich(TextSpan(children: _spans(
              lines[li], marks, base, findQuery, isCurrentMatch))),
          ),
        ],
      ));
    }
    if (rows.isEmpty) rows.add(SizedBox(height: bodyFontSize * 1.35));

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
        return side == _Side.left ? _kDiffLeftBg : _kDiffRightBg;
    }
  }

  List<InlineSpan> _spans(
    String text, Set<int> marks, TextStyle base,
    String findQuery, bool isCurrentMatch,
  ) {
    final lineEndMarked = marks.contains(text.length);
    final innerMarks = marks.where((m) => m < text.length).toSet();
    final out = <InlineSpan>[];

    if (text.isEmpty) {
      out.add(TextSpan(text: ' ', style: base));
    } else if (innerMarks.isEmpty) {
      // 没有 diff 高亮时，看查找
      if (findQuery.isEmpty || !text.contains(findQuery)) {
        out.add(TextSpan(text: text, style: base));
      } else {
        _appendFindSpans(out, text, base, findQuery, isCurrentMatch);
      }
    } else {
      var i = 0;
      while (i < text.length) {
        final marked = innerMarks.contains(i);
        var j = i;
        while (j < text.length && innerMarks.contains(j) == marked) j++;
        final chunk = text.substring(i, j);
        if (marked) {
          final c = _isWs(text.codeUnitAt(i)) ? _kWsHighlight : _kCharHighlight;
          out.add(TextSpan(
            text: chunk,
            style: base.copyWith(
              backgroundColor: c, fontWeight: FontWeight.bold,
            ),
          ));
        } else {
          if (findQuery.isEmpty || !chunk.contains(findQuery)) {
            out.add(TextSpan(text: chunk, style: base));
          } else {
            _appendFindSpans(out, chunk, base, findQuery, isCurrentMatch);
          }
        }
        i = j;
      }
    }

    if (lineEndMarked) {
      out.add(TextSpan(
        text: '↵',
        style: base.copyWith(
          backgroundColor: _kWsHighlight, fontWeight: FontWeight.bold,
        ),
      ));
    }
    return out;
  }

  void _appendFindSpans(
    List<InlineSpan> out, String text, TextStyle base,
    String q, bool isCurrentMatch,
  ) {
    final bg = isCurrentMatch ? const Color(0xFFFF4081) : const Color(0xFFFFF59D);
    var s = 0;
    int idx;
    while ((idx = text.indexOf(q, s)) != -1) {
      if (idx > s) out.add(TextSpan(text: text.substring(s, idx), style: base));
      out.add(TextSpan(
        text: q,
        style: base.copyWith(backgroundColor: bg, fontWeight: FontWeight.bold),
      ));
      s = idx + q.length;
    }
    if (s < text.length) out.add(TextSpan(text: text.substring(s), style: base));
  }
}

// ==================== 翻屏图标 ====================

class _PageDownIconPainter extends CustomPainter {
  _PageDownIconPainter({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    canvas.save();
    canvas.scale(s, s);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pd = Paint()
      ..color = color.withValues(alpha: color.a * 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRect(const Rect.fromLTWH(9, 1, 6, 10), p);
    canvas.drawPath(
      Path()..moveTo(9.5, 14.5)..lineTo(12, 16.5)..lineTo(14.5, 14.5), pd);
    canvas.drawPath(
      Path()..moveTo(8.5, 18)..lineTo(12, 20.5)..lineTo(15.5, 18), p);
    canvas.restore();
  }
  @override
  bool shouldRepaint(_PageDownIconPainter old) => old.color != color;
}

class _PageUpIconPainter extends CustomPainter {
  _PageUpIconPainter({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    canvas.save();
    canvas.scale(s, s);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pd = Paint()
      ..color = color.withValues(alpha: color.a * 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRect(const Rect.fromLTWH(9, 13, 6, 10), p);
    canvas.drawPath(
      Path()..moveTo(9.5, 9.5)..lineTo(12, 7.5)..lineTo(14.5, 9.5), pd);
    canvas.drawPath(
      Path()..moveTo(8.5, 6)..lineTo(12, 3.5)..lineTo(15.5, 6), p);
    canvas.restore();
  }
  @override
  bool shouldRepaint(_PageUpIconPainter old) => old.color != color;
}
