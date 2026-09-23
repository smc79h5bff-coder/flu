import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';
import '../application/edit_saver.dart';

/// 支持查找高亮的文本控制器：重写 [buildTextSpan]，把命中的子串以
/// 黄色背景 + 加粗标出。高亮只在“绘制可见行”时计算，成本低、不卡顿。
class _HighlightController extends TextEditingController {
  _HighlightController({super.text, this.highlightText = ''});

  /// 当前查找词；为空则不高亮。
  String highlightText;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = this.text;
    final q = highlightText;
    if (q.isEmpty || text.isEmpty || withComposing) {
      return TextSpan(style: style, text: text);
    }
    final spans = <InlineSpan>[];
    var start = 0;
    int idx;
    while (start <= text.length && (idx = text.indexOf(q, start)) != -1) {
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(
        text: q,
        style: const TextStyle(
          backgroundColor: Color(0xFFFFF59D),
          fontWeight: FontWeight.bold,
        ),
      ));
      start = idx + q.length;
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return TextSpan(style: style, children: spans.isEmpty ? [TextSpan(text: text)] : spans);
  }
}

/// 逐行对齐的双栏可编辑页：原文与修改后文档同一逻辑行强制对齐。
///
/// 每个列表项 = [`行号(原)`  |  原行编辑框  |`行号(改)`  |  修改行编辑框]。
/// 顶部提供 **查找 / 替换**（可选支持正则），作用于原版与修改版两侧文本。
class EditScreen extends ConsumerStatefulWidget {
  const EditScreen({super.key});

  @override
  ConsumerState<EditScreen> createState() => _EditScreenState();
}

/// 一次查找命中的位置（side: 0=原版, 1=修改版；line+start/end 在行内文本坐标）。
class _Occ {
  const _Occ(this.side, this.line, this.start, this.end);
  final int side;
  final int line;
  final int start;
  final int end;
}

class _EditScreenState extends ConsumerState<EditScreen> {
  late List<_HighlightController> _orig;
  late List<_HighlightController> _mod;
  final ScrollController _editScroll = ScrollController();
  int _rows = 0;
  bool _saving = false;

  // 查找 / 替换状态。
  final TextEditingController _findCtrl = TextEditingController();
  final TextEditingController _replaceCtrl = TextEditingController();
  bool _regexEnable = false;
  List<_Occ> _occ = const <_Occ>[];
  int _occPos = -1;
  int _occTotal = 0; // 实际命中总数（可能 > _occ.length，用于上限展示）
  Timer? _findDebounce;

  /// 惰性行 GlobalKey（keyed by 行号）：只有命中行才登记，供
  /// [Scrollable.ensureVisible] 精确定位查找命中。
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};

  static const double _rowHeight = 44.0;
  static const int _occCap = 3000; // 最多收集的命中数，防止巨量对象卡顿

  @override
  void initState() {
    super.initState();
    _loadFromProviders();
  }

  void _loadFromProviders() {
    final o = ref.read(originalRawTextProvider) ?? '';
    final m = ref.read(modifiedRawTextProvider) ?? '';
    _orig = [for (final l in o.split('\n')) _HighlightController(text: l)];
    _mod = [for (final l in m.split('\n')) _HighlightController(text: l)];
    _rows = _orig.length > _mod.length ? _orig.length : _mod.length;
  }

  @override
  void dispose() {
    _findDebounce?.cancel();
    _editScroll.dispose();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    for (final c in _orig) c.dispose();
    for (final c in _mod) c.dispose();
    super.dispose();
  }

  String _join(List<TextEditingController> list) =>
      list.map((c) => c.text).join('\n');

  /// 根据查找框内容 + 正则开关构建 [Pattern]。空串/非法正则 → 永不匹配。
  Pattern get _pattern {
    final q = _findCtrl.text;
    if (q.isEmpty) return RegExp(r'(?!)');
    try {
      return _regexEnable ? RegExp(q) : RegExp(RegExp.escape(q));
    } catch (_) {
      return RegExp(r'(?!)');
    }
  }

  /// 全量扫描两侧文本，统计命中总数并收集命中（封顶 [_occCap] 条）。
  /// 空查找词直接清零返回，不扫描。仅在防抖/替换后调用，避免高频全量扫描。
  void _recomputeOccurrences() {
    final q = _findCtrl.text;
    if (q.isEmpty) {
      _occ = const <_Occ>[];
      _occTotal = 0;
      _occPos = -1;
      _scannedQuery = '';
      return;
    }
    final p = _pattern;
    final occ = <_Occ>[];
    var total = 0;
    for (final (side, list) in [(0, _orig), (1, _mod)]) {
      for (var li = 0; li < list.length; li++) {
        final line = list[li].text;
        for (final m in p.allMatches(line)) {
          if (m.start == m.end) continue; // 忽略空匹配
          total++;
          if (occ.length < _occCap) occ.add(_Occ(side, li, m.start, m.end));
        }
      }
    }
    _occ = occ;
    _occTotal = total;
    _scannedQuery = q;
    // 为每个命中行惰性登记 GlobalKey，供精确 ensureVisible 滚动。
    for (final o in _occ) _rowKeys.putIfAbsent(o.line, () => GlobalKey());
    if (_occPos >= occ.length) _occPos = occ.isEmpty ? -1 : 0;
  }

  /// 查找框输入变化：只更新全局查找词 + 用防抖延迟全量扫描命中。
  /// 行文本高亮由 _LineRow 在构建可见行时按 [_findQuery] 计算，无需为每行
  /// 控制器赋值，避免大文件下整表重建卡顿。
  void _onFindChanged(String _) {
    final q = _findCtrl.text;
    _findDebounce?.cancel();
    _findDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _findQuery = q;
        _recomputeOccurrences();
      });
    });
    setState(() => _findQuery = q); // 立即刷新可见行的高亮
  }

  String _findQuery = '';

  Future<void> _scrollToLine(int line) async {
    Future<void> locate(int round) async {
      final ctx = _rowKeys[line]?.currentContext;
      if (ctx != null) {
        // 目标行已构建 → 精确定位到视口上部。
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: 0.2,
        );
        return;
      }
      if (round > 10 || !_editScroll.hasClients) return; // 兜底避免死循环
      final pos = _editScroll.position;
      final viewport = pos.viewportDimension;
      final maxExtent = pos.maxScrollExtent;
      // 行高随换行可变，估算仅用于把目标行拉进构建范围；首轮按固定行高估算，
      // 之后沿目标方向每轮推进大半个视口（上一处/下一处都能收敛）。
      var offset = line * _rowHeight;
      if (round > 0) {
        final curLine = pos.pixels / _rowHeight;
        final dir = (line + 0.5) >= curLine ? 1 : -1;
        offset += dir * round * viewport * 0.7;
      }
      offset = offset.clamp(0.0, maxExtent);
      if ((pos.pixels - offset).abs() < 1.0) return;
      if ((pos.pixels - offset).abs() > viewport * 3) {
        pos.jumpTo(offset); // 大距离瞬移
      } else {
        await _editScroll.animateTo(
          offset,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeInOut,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await locate(round + 1);
    }

    if (!_editScroll.hasClients) return;
    await locate(0);
  }

  String _scannedQuery = ''; // 上次已扫描过的查找词，避免箭头键重复全量扫描

  /// 仅在查找词变化时（防抖尚未触发前按了箭头）才补扫一次，避免每次按键
  /// 都重复全量扫描大文本导致卡顿。
  void _ensureScanned() {
    if (_scannedQuery != _findCtrl.text) {
      _scannedQuery = _findCtrl.text;
      _recomputeOccurrences();
    }
  }

  void _nextOcc() {
    _ensureScanned();
    if (_occ.isEmpty) {
      setState(() => _occPos = -1);
      return;
    }
    setState(() {
      _occPos = (_occPos + 1) % _occ.length;
      final o = _occ[_occPos];
      _scrollToLine(o.line);
    });
  }

  void _prevOcc() {
    _ensureScanned();
    if (_occ.isEmpty) {
      setState(() => _occPos = -1);
      return;
    }
    setState(() {
      _occPos = (_occPos - 1 + _occ.length) % _occ.length;
      final o = _occ[_occPos];
      _scrollToLine(o.line);
    });
  }

  /// 替换当前命中；无命中则提示。
  void _replaceCurrent() {
    _recomputeOccurrences();
    if (_occ.isEmpty) {
      _showMsg('没有可替换的内容');
      return;
    }
    if (_occPos < 0) _occPos = 0;
    final o = _occ[_occPos];
    final list = o.side == 0 ? _orig : _mod;
    // 该行可能已被用户修改而与扫描结果不同，做长度保护，避免越界崩溃。
    final line = list[o.line];
    final old = line.text;
    if (o.start > old.length || o.end > old.length || o.start > o.end) {
      _showMsg('该位置已变化，请重新查找');
      return;
    }
    line.text = old.substring(0, o.start) + _replaceCtrl.text + old.substring(o.end);
    // 替换后让命中跳到下一处（或回到第一处），便于连续替换。
    _recomputeOccurrences();
    setState(() {
      if (_occ.isEmpty) {
        _occPos = -1;
      } else if (_occPos >= _occ.length) {
        _occPos = 0;
      }
      if (_occ.isNotEmpty) {
        final n = _occ[_occPos];
        _scrollToLine(n.line);
      }
    });
  }

  /// 全文替换（两侧各自 replaceAll），随后重建编辑行控制器。
  void _replaceAll() {
    final p = _pattern;
    if (_findCtrl.text.isEmpty) {
      _showMsg('请输入要查找的内容');
      return;
    }
    final newOrig = _join(_orig).replaceAll(p, _replaceCtrl.text);
    final newMod = _join(_mod).replaceAll(p, _replaceCtrl.text);
    final findQ = _findCtrl.text;
    for (final c in _orig) c.dispose();
    for (final c in _mod) c.dispose();
    setState(() {
      _orig = [for (final l in newOrig.split('\n')) _HighlightController(text: l, highlightText: findQ)];
      _mod = [for (final l in newMod.split('\n')) _HighlightController(text: l, highlightText: findQ)];
      _rows = _orig.length > _mod.length ? _orig.length : _mod.length;
      _recomputeOccurrences();
      _occPos = -1;
    });
    _showMsg('全文替换完成');
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  Future<void> _save() async {
    final origText = _join(_orig);
    final modText = _join(_mod);
    final ref0 = ref;

    ref0.read(originalRawTextProvider.notifier).state = origText;
    ref0.read(modifiedRawTextProvider.notifier).state = modText;
    ref0.read(importRevisionProvider.notifier).state++;

    setState(() => _saving = true);
    const saver = EditSaver();
    final ok = <String>[];
    final errs = <String>[];

    // 一律走“另存为”，不再覆盖原文件（保留另存功能）。
    Future<void> saveSide({
      required String text,
      required String fileName,
      required String side,
    }) async {
      try {
        final r = await saver.saveAs(
            text, fileName: fileName.isEmpty ? 'docdiff.txt' : fileName);
        if (r != null) ok.add('$side：${r.savedPath} 已另存');
        else errs.add('$side：已取消另存');
      } catch (e) {
        errs.add('$side：保存失败 $e');
      }
    }

    await saveSide(
      text: origText,
      fileName: ref0.read(originalFileNameProvider) ?? '',
      side: '原版',
    );
    await saveSide(
      text: modText,
      fileName: ref0.read(modifiedFileNameProvider) ?? '',
      side: '修改版',
    );

    if (!mounted) return;
    setState(() => _saving = false);
    final msg = [...ok, if (errs.isNotEmpty) '${errs.join('；')}'].join('\n');
    _showMsg(msg.isEmpty ? '保存完成' : msg);
  }

  @override
  Widget build(BuildContext context) {
    final origName = ref.watch(originalFileNameProvider) ?? '原文';
    final modName = ref.watch(modifiedFileNameProvider) ?? '修改后';

    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑'),
        actions: [
          IconButton(
            icon: const Icon(Icons.find_in_page),
            tooltip: '查找 / 替换',
            onPressed: () => setState(
              () => _showFindReplace = !_showFindReplace,
            ),
          ),
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: Icon(_saving ? Icons.hourglass_top : Icons.save),
            label: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_showFindReplace) _buildFindReplaceBar(),
          _Header(origName: origName, modName: modName),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _editScroll,
              itemCount: _rows,
              itemBuilder: (_, i) {
                final row = _LineRow(
                  index: i,
                  orig: i < _orig.length ? _orig[i] : null,
                  mod: i < _mod.length ? _mod[i] : null,
                  findQuery: _findQuery,
                );
                final key = _rowKeys[i];
                return key == null ? row : KeyedSubtree(key: key, child: row);
              },
            ),
          ),
        ],
      ),
    );
  }

  bool _showFindReplace = false;

  /// 查找 / 替换工具栏：分三行布局，避免窄屏按钮被挤出屏幕。
  /// 行1：查找框 + 命中计数 + 上/下一个；行2：替换框 + 正则开关；
  /// 行3：替换当前 / 全部替换（等宽按钮）。
  Widget _buildFindReplaceBar() {
    final s = Theme.of(context).colorScheme;
    final displayTotal = _occTotal > 0 ? _occTotal : _occ.length;
    final total = displayTotal;
    final current = total == 0 ? 0 : (_occPos < 0 ? 0 : _occPos + 1);
    final labelStyle = Theme.of(context).textTheme.labelSmall;
    return Material(
      color: s.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _findCtrl,
                    decoration: const InputDecoration(
                      hintText: '查找内容',
                      prefixIcon: Icon(Icons.manage_search, size: 20),
                      isDense: true,
                      border: UnderlineInputBorder(),
                    ),
                    onSubmitted: (_) => _nextOcc(),
                    onChanged: _onFindChanged,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 60,
                  child: Text('$current/$total',
                      textAlign: TextAlign.center, style: labelStyle),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '上一个',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: total == 0 ? null : _prevOcc,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '下一个',
                  icon: const Icon(Icons.arrow_downward),
                  onPressed: total == 0 ? null : _nextOcc,
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _replaceCtrl,
                    decoration: const InputDecoration(
                      hintText: '替换为',
                      prefixIcon: Icon(Icons.find_replace, size: 20),
                      isDense: true,
                      border: UnderlineInputBorder(),
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => setState(() {
                    _regexEnable = !_regexEnable;
                    _recomputeOccurrences();
                  }),
                  child: Text(
                    _regexEnable ? '正则:开' : '正则:关',
                    style: TextStyle(
                      fontSize: 12,
                      color: _regexEnable ? s.primary : s.onSurfaceVariant,
                      fontWeight:
                          _regexEnable ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.find_replace, size: 16),
                    label: const Text('替换当前'),
                    onPressed: _replaceCurrent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.done_all, size: 16),
                    label: const Text('全部替换'),
                    onPressed: _replaceAll,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.origName, required this.modName});

  final String origName;
  final String modName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceVariant,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SizedBox(width: 40, child: Text('行', style: theme.textTheme.labelSmall)),
          Expanded(
            child: Text(origName, style: theme.textTheme.labelSmall),
          ),
          SizedBox(
            width: 40,
            child: Text('行', style: theme.textTheme.labelSmall),
          ),
          Expanded(
            child: Text(modName, style: theme.textTheme.labelSmall),
          ),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.index,
    required this.orig,
    required this.mod,
    required this.findQuery,
  });

  final int index;
  final TextEditingController? orig;
  final TextEditingController? mod;
  final String findQuery;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _Gutter(number: index + 1),
        Expanded(child: _Cell(controller: orig, findQuery: findQuery)),
        const VerticalDivider(width: 1),
        _Gutter(number: index + 1),
        Expanded(child: _Cell(controller: mod, findQuery: findQuery)),
      ],
    );
  }
}

class _Gutter extends StatelessWidget {
  const _Gutter({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          '$number',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.controller, required this.findQuery});

  final TextEditingController? controller;
  final String findQuery;

  @override
  Widget build(BuildContext context) {
    // 只在可见行构建时同步高亮词（ListView.builder 惰性构建，行数大时开销小）。
    if (controller is _HighlightController) {
      (controller as _HighlightController).highlightText = findQuery;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: controller == null
          ? const SizedBox(height: 48)
          : TextField(
              controller: controller,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 14, height: 1.4),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
              ),
            ),
    );
  }
}