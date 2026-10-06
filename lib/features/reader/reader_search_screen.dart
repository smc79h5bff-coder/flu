import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'reader_repository.dart';
import 'reader_search_provider.dart';

// ==================== 全屏搜索页 ====================

class ReaderSearchScreen extends ConsumerStatefulWidget {
  const ReaderSearchScreen({
    super.key,
    required this.text,
    required this.fileKey,
    this.initialQuery = '',
    this.initialRegex = false,
    this.initialCaseSensitive = false,
  });

  final String text;
  final String fileKey;
  final String initialQuery;
  final bool initialRegex;
  final bool initialCaseSensitive;

  @override
  ConsumerState<ReaderSearchScreen> createState() =>
      _ReaderSearchScreenState();
}

class _ReaderSearchScreenState extends ConsumerState<ReaderSearchScreen> {
  late final TextEditingController _ctrl;
  final ScrollController _scrollCtrl = ScrollController();
  bool _regex = false;
  bool _caseSensitive = false;
  bool _searching = false;

  List<String>? _lines;
  List<int>? _lineStarts;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialQuery);
    _regex = widget.initialRegex;
    _caseSensitive = widget.initialCaseSensitive;

    final state = ref.read(readerSearchProvider);
    if (state.fileKey == widget.fileKey && state.hits.isNotEmpty) {
      // 已经有当前文件的结果，滚动到 currentPos。
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    } else if (widget.initialQuery.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _doSearch(widget.initialQuery);
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _ensureLines() {
    if (_lines != null) return;
    final t = widget.text;
    final lines = <String>[];
    final starts = <int>[];
    var start = 0;
    for (var i = 0; i < t.length; i++) {
      if (t.codeUnitAt(i) == 0x0A) {
        lines.add(t.substring(start, i));
        starts.add(start);
        start = i + 1;
      }
    }
    lines.add(t.substring(start));
    starts.add(start);
    _lines = lines;
    _lineStarts = starts;
  }

  Future<void> _doSearch(String query) async {
    if (query.isEmpty) {
      ref.read(readerSearchProvider.notifier).clear();
      setState(() {});
      return;
    }
     ref.read(readerFindHistoryProvider.notifier).add(query);   // ← 加这一行
    
    setState(() => _searching = true);
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    _ensureLines();
    final lines = _lines!;
    final lineStarts = _lineStarts!;

    RegExp? re;
    try {
      re = _regex
          ? RegExp(query, caseSensitive: _caseSensitive, multiLine: true)
          : RegExp(RegExp.escape(query), caseSensitive: _caseSensitive);
    } catch (_) {
      re = null;
    }

    final hits = <ReaderSearchHit>[];
    if (re != null) {
      for (var li = 0; li < lines.length; li++) {
        final line = lines[li];
        if (line.isEmpty) continue;
        for (final m in re.allMatches(line)) {
          if (m.start == m.end) continue;
          hits.add(_buildHit(
            lines: lines,
            lineStarts: lineStarts,
            lineIndex: li,
            startInLine: m.start,
            endInLine: m.end,
          ));
        }
      }
    }

    if (!mounted) return;
    setState(() => _searching = false);

    ref.read(readerSearchProvider.notifier).setResult(
          fileKey: widget.fileKey,
          query: query,
          regex: _regex,
          caseSensitive: _caseSensitive,
          hits: hits,
          currentPos: hits.isEmpty ? -1 : 0,
        );

    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
  }

  /// 生成一条结果的显示内容。
  /// 匹配词前 ~25 字、后 ~25 字，本行不够就向上/下借。
  ReaderSearchHit _buildHit({
    required List<String> lines,
    required List<int> lineStarts,
    required int lineIndex,
    required int startInLine,
    required int endInLine,
  }) {
    const half = 25;
    final line = lines[lineIndex];

    // ---- 前文 ----
    var preBudget = half;
    final preStart = (startInLine - preBudget).clamp(0, startInLine);
    var pre = line.substring(preStart, startInLine);
    preBudget -= pre.length;
    var preEllipsis = preStart > 0;
    if (preBudget > 0 && lineIndex > 0) {
      final prev = lines[lineIndex - 1];
      if (prev.isNotEmpty) {
        final takeFrom = (prev.length - preBudget).clamp(0, prev.length);
        pre = prev.substring(takeFrom) + pre;
        preEllipsis = true;
      }
    }

    // ---- 后文 ----
    var postBudget = half;
    final postEnd = (endInLine + postBudget).clamp(0, line.length);
    var post = line.substring(endInLine, postEnd);
    postBudget -= post.length;
    var postEllipsis = postEnd < line.length;
    if (postBudget > 0 && lineIndex + 1 < lines.length) {
      final next = lines[lineIndex + 1];
      if (next.isNotEmpty) {
        final takeTo = postBudget.clamp(0, next.length);
        post = post + next.substring(0, takeTo);
        postEllipsis = true;
      }
    }

    return ReaderSearchHit(
      globalStart: lineStarts[lineIndex] + startInLine,
      globalEnd: lineStarts[lineIndex] + endInLine,
      lineIndex: lineIndex,
      startInLine: startInLine,
      endInLine: endInLine,
      pre: pre,
      preEllipsis: preEllipsis,
      match: line.substring(startInLine, endInLine),
      post: post,
      postEllipsis: postEllipsis,
    );
  }

  void _scrollToCurrent() {
    final state = ref.read(readerSearchProvider);
    if (state.currentPos < 0) return;
    if (!_scrollCtrl.hasClients) return;
    const itemHeight = 36.0;
    final offset = state.currentPos * itemHeight;
    final max = _scrollCtrl.position.maxScrollExtent;
    _scrollCtrl.jumpTo(offset.clamp(0, max));
  }

  void _onTapHit(int pos) {
    ref.read(readerSearchProvider.notifier).setCurrentPos(pos);
    final state = ref.read(readerSearchProvider);
    Navigator.of(context).pop(state.hits[pos].globalStart);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerSearchProvider);
    final hits = state.hits;
    final s = Theme.of(context).colorScheme;

    return Scaffold(


      appBar: AppBar(
  leading: IconButton(
    icon: const Icon(Icons.arrow_back),
    tooltip: '关闭搜索',
    onPressed: () {
      // 点返回按钮 = 关闭搜索：
      // 清掉当前文件的搜索状态，这样回到阅读器后半开条不显示。
      // 如果用户是想"跳转到某条结果"，应该点具体的结果行，
      // 而不是点返回按钮。
      ref.read(readerSearchProvider.notifier).clear();
      Navigator.of(context).pop();  // 不带 result，不跳转
    },
  ),
  title: const Text('搜索'),
  actions: [
    IconButton(
      tooltip: '历史',
      icon: const Icon(Icons.history),
      onPressed: _showHistory,
    ),
  ],
),



      
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '查找…',
                      isDense: true,
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search, size: 18),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    ),
                    onSubmitted: (v) => _doSearch(v.trim()),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed:
                      _searching ? null : () => _doSearch(_ctrl.text.trim()),
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _flag(
                  label: '正则',
                  value: _regex,
                  onTap: () => setState(() => _regex = !_regex),
                ),
                _flag(
                  label: '区分大小写',
                  value: _caseSensitive,
                  onTap: () =>
                      setState(() => _caseSensitive = !_caseSensitive),
                ),
                const Spacer(),
                if (hits.isNotEmpty)
                  Text(
                    '共 ${hits.length} 处',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : hits.isEmpty
                    ? Center(
                        child: Text(
                          _ctrl.text.isEmpty ? '输入关键词开始搜索' : '无匹配',
                          style: TextStyle(color: s.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        itemCount: hits.length,
                        itemExtent: 36,
                        itemBuilder: (ctx, i) {
                          final hit = hits[i];
                          final isCurrent = i == state.currentPos;
                          return InkWell(
                            onTap: () => _onTapHit(i),
                            child: Container(
                              color: isCurrent
                                  ? Colors.blue.withValues(alpha: 0.10)
                                  : null,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              alignment: Alignment.centerLeft,
                              child: _buildResultRow(hit),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultRow(ReaderSearchHit hit) {
    // 匹配词深粉
    const deepPink = Color(0xFFD50057);

    final children = <InlineSpan>[
      TextSpan(
        text: '第 ${hit.lineIndex + 1} 行  ',
        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
      ),
    ];
    if (hit.preEllipsis) children.add(const TextSpan(text: '…'));
    if (hit.pre.isNotEmpty) children.add(TextSpan(text: hit.pre));
    children.add(TextSpan(
      text: hit.match,
      style: const TextStyle(
        backgroundColor: deepPink,
        color: Colors.white,
        fontWeight: FontWeight.bold,
      ),
    ));
    if (hit.post.isNotEmpty) children.add(TextSpan(text: hit.post));
    if (hit.postEllipsis) children.add(const TextSpan(text: '…'));

    return Text.rich(
      TextSpan(
        children: children,
        style: const TextStyle(fontSize: 13, height: 1.2),
      ),
      maxLines: 1,
      overflow: TextOverflow.clip,
      softWrap: false,
    );
  }







  Widget _flag({
  required String label,
  required bool value,
  required VoidCallback onTap,
}) {
  final s = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: value ? s.primary.withValues(alpha: 0.14) : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: value
                ? s.primary.withValues(alpha: 0.55)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: value ? FontWeight.bold : FontWeight.normal,
            color: value ? s.primary : s.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );
}







  

  Future<void> _showHistory() async {
    final items = ref.read(readerFindHistoryProvider.notifier).sorted();
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有搜索记录')),
      );
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('搜索历史'),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.6,
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (ctx, i) {
              final it = items[i];
              return ListTile(
                dense: true,
                leading: Icon(
                  it.isFavorite ? Icons.star : Icons.history,
                  size: 20,
                  color: it.isFavorite ? Colors.amber : null,
                ),
                title: Text(it.word),
                onTap: () => Navigator.pop(c, it.word),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (picked != null && mounted) {
      _ctrl.text = picked;
      _doSearch(picked);
    }
  }
}

// ==================== 半开条 ====================

/// 跳转后浮在正文底部的半开条。
///
/// · 占屏幕高度约 10%
/// · 背景半透明白（80% 透明）
/// · 显示 [↑] N/M [↓] [展开] [✕]
class ReaderSearchMinibar extends ConsumerWidget {
  const ReaderSearchMinibar({
    super.key,
    required this.onJump,
    required this.onExpand,
    required this.onClose,
  });

  final void Function(int charOffset) onJump;
  final VoidCallback onExpand;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerSearchProvider);
    if (!state.hasSearch) return const SizedBox.shrink();

    final pos = state.currentPos;
    final total = state.hits.length;

    return Material(
      color: Colors.white.withValues(alpha: 0.2),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.10,
        child: Row(
          children: [
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.arrow_upward, color: Colors.black87),
              tooltip: '上一处',
              visualDensity: VisualDensity.compact,
              onPressed: pos <= 0
                  ? null
                  : () {
                      ref
                          .read(readerSearchProvider.notifier)
                          .setCurrentPos(pos - 1);
                      onJump(state.hits[pos - 1].globalStart);
                    },
            ),
            Expanded(
              child: Text(
                '${pos + 1}/$total',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_downward, color: Colors.black87),
              tooltip: '下一处',
              visualDensity: VisualDensity.compact,
              onPressed: pos >= total - 1
                  ? null
                  : () {
                      ref
                          .read(readerSearchProvider.notifier)
                          .setCurrentPos(pos + 1);
                      onJump(state.hits[pos + 1].globalStart);
                    },
            ),
            IconButton(
              icon: const Icon(Icons.open_in_full, color: Colors.black87),
              tooltip: '展开',
              visualDensity: VisualDensity.compact,
              onPressed: onExpand,
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.black87),
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}
