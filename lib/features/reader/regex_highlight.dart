import 'package:flutter/material.dart';

import 'reader_models.dart';
import 'reader_pagination.dart' show HighlightSpan;

// ==================== 正则编译缓存 ====================
//
// 同一个 pattern 只编译一次。编辑高亮后调 invalidateRegexCache() 清空。

final Map<String, RegExp?> _regexCache = {};

/// 拿一个已编译的正则。非法返回 null（不抛异常）。
RegExp? getCompiledRegex(String pattern) {
  if (_regexCache.containsKey(pattern)) return _regexCache[pattern];
  RegExp? re;
  try {
    re = RegExp(pattern, multiLine: true);
  } catch (_) {
    re = null;
  }
  _regexCache[pattern] = re;
  return re;
}

/// 清编译缓存。高亮条目变更后调用。
void invalidateRegexCache() {
  _regexCache.clear();
}

// ==================== 捕获组位置计算 ====================

/// 从 [m] 里取出第 [gi] 个捕获组在原文本中的起止位置。
///
/// Dart 的 `Match` 只有 `start` / `end`（整个匹配）和 `group(i)`（文本），
/// 没有 `start(i)` / `end(i)`。所以只能拿捕获组文本，在完整匹配里从左往右
/// 反查位置。
///
/// [gi] = 0 → 返回整个匹配的位置。
/// 返回 null 表示这个捕获组不存在（越界 / 未参与匹配 / 空文本）。
({int start, int end})? _captureRange(Match m, int gi) {
  if (gi <= 0) {
    return (start: m.start, end: m.end);
  }
  if (gi > m.groupCount) return null;

  final fullText = m.group(0) ?? '';
  final groupText = m.group(gi) ?? '';
  if (fullText.isEmpty || groupText.isEmpty) return null;

  // 从左往右扫描，跳过前面 gi-1 个捕获组。
  var scanFrom = 0;
  for (var i = 1; i <= gi; i++) {
    final t = m.group(i);
    if (t == null || t.isEmpty) continue;
    final rel = fullText.indexOf(t, scanFrom);
    if (rel < 0) return null;
    if (i == gi) {
      return (start: m.start + rel, end: m.start + rel + t.length);
    }
    scanFrom = rel + t.length;
  }
  return null;
}

// ==================== 页级匹配 ====================

/// 对整页文本跑所有正则高亮。
///
/// [pageText] 是把若干行拼起来 + '\n' 分隔的整页文本。
/// [lineStartInBuf] 第 i 段在 pageText 里的起点。
/// [lineIdxAtPos] 第 i 段对应的原行号。
/// [regexEntries] 所有 `isRegex == true` 的高亮条目。
///
/// 返回：原行号 → List<HighlightSpan>。
/// 跨行匹配会被丢弃（只支持单行内匹配）。
Map<int, List<HighlightSpan>> matchRegexOnPage({
  required String pageText,
  required List<int> lineStartInBuf,
  required List<int> lineIdxAtPos,
  required List<HighlightEntry> regexEntries,
}) {
  final byLine = <int, List<HighlightSpan>>{};
  if (regexEntries.isEmpty || lineStartInBuf.isEmpty) return byLine;

  final pageLen = pageText.length;

  for (final entry in regexEntries) {
    final re = getCompiledRegex(entry.keyword);
    if (re == null) continue;

    for (final m in re.allMatches(pageText)) {
      // 空匹配跳过（防 a* 之类死循环）
      if (m.start == m.end) continue;

      final range = _captureRange(m, entry.groupIndex);
      if (range == null) continue;
      final start = range.start;
      final end = range.end;
      if (start < 0 || end <= start || end > pageLen) continue;

      // 二分定位 start 所在行
      final rowIdx = _findRowIdx(lineStartInBuf, start);
      if (rowIdx < 0) continue;

      final lineStart = lineStartInBuf[rowIdx];
      final lineEnd = rowIdx + 1 < lineStartInBuf.length
          ? lineStartInBuf[rowIdx + 1] - 1
          : pageLen - 1;
      // 跨行匹配丢掉
      if (end > lineEnd) continue;

      final actualLineIdx = lineIdxAtPos[rowIdx];
      (byLine[actualLineIdx] ??= <HighlightSpan>[]).add(HighlightSpan(
        startInLine: start - lineStart,
        endInLine: end - lineStart,
        entry: entry,
      ));
    }
  }

  return byLine;
}

/// 二分：返回最后一个 <= pos 的下标。
int _findRowIdx(List<int> lineStartInBuf, int pos) {
  if (lineStartInBuf.isEmpty) return -1;
  if (pos < lineStartInBuf[0]) return -1;
  var lo = 0;
  var hi = lineStartInBuf.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (lineStartInBuf[mid] <= pos) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

// ==================== 行级匹配（滚动模式用） ====================

/// 对单行文本跑所有正则高亮。
List<HighlightSpan> matchRegexOnLine({
  required String lineText,
  required List<HighlightEntry> regexEntries,
}) {
  if (regexEntries.isEmpty || lineText.isEmpty) return const [];
  final out = <HighlightSpan>[];
  final lineLen = lineText.length;

  for (final entry in regexEntries) {
    final re = getCompiledRegex(entry.keyword);
    if (re == null) continue;
    for (final m in re.allMatches(lineText)) {
      if (m.start == m.end) continue;

      final range = _captureRange(m, entry.groupIndex);
      if (range == null) continue;
      final start = range.start;
      final end = range.end;
      if (start < 0 || end <= start || end > lineLen) continue;

      out.add(HighlightSpan(
        startInLine: start,
        endInLine: end,
        entry: entry,
      ));
    }
  }
  return out;
}

// ==================== 新建高亮表单 ====================

/// 弹出"新建高亮"表单。返回用户创建的 HighlightEntry，取消返回 null。
///
/// [presetColor] 可选。从"色块编辑页"进来时传当前色块的主色，
/// 表单会预选这个色块。其他入口传 null，默认选第一个色块。
Future<HighlightEntry?> showNewHighlightDialog({
  required BuildContext context,
  required List<HighlightPalette> palettes,
  required List<HighlightGroup> groups,
  int? presetColor,
}) {
  return showDialog<HighlightEntry>(
    context: context,
    builder: (_) => _NewHighlightDialog(
      palettes: palettes,
      groups: groups,
      presetColor: presetColor,
    ),
  );
}

class _NewHighlightDialog extends StatefulWidget {
  const _NewHighlightDialog({
    required this.palettes,
    required this.groups,
    this.presetColor,
  });

  final List<HighlightPalette> palettes;
  final List<HighlightGroup> groups;
  final int? presetColor;

  @override
  State<_NewHighlightDialog> createState() => _NewHighlightDialogState();
}

class _NewHighlightDialogState extends State<_NewHighlightDialog> {
  final _nameCtrl = TextEditingController();
  final _kwCtrl = TextEditingController();
  bool _isRegex = false;
  int _groupIndex = 0;
  int _colorIndex = 0;
  String? _groupId;
  String? _regexError;

  @override
  void initState() {
    super.initState();
    if (widget.presetColor != null) {
      for (var i = 0; i < widget.palettes.length; i++) {
        if (widget.palettes[i].colors.first == widget.presetColor) {
          _colorIndex = i;
          break;
        }
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _kwCtrl.dispose();
    super.dispose();
  }

  void _validateRegex() {
    final kw = _kwCtrl.text.trim();
    if (!_isRegex || kw.isEmpty) {
      if (_regexError != null) {
        setState(() => _regexError = null);
      }
      return;
    }
    try {
      RegExp(kw);
      if (_regexError != null) {
        setState(() => _regexError = null);
      }
    } catch (e) {
      setState(() => _regexError = '正则无效：$e');
    }
  }

  void _save() {
    final kw = _kwCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    if (kw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('关键词 / 正则不能为空')),
      );
      return;
    }
    if (_isRegex) {
      try {
        RegExp(kw);
      } catch (e) {
        setState(() => _regexError = '正则无效：$e');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正则无效，请检查')),
        );
        return;
      }
    }
    final palette = widget.palettes[_colorIndex];
    final entry = HighlightEntry(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      keyword: kw,
      colors: List<int>.from(palette.colors),
      stops: List<double>.from(palette.stops),
      angle: palette.angle,
      textColor: palette.textColor,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      name: name,
      groupId: _groupId,
      isRegex: _isRegex,
      groupIndex: _isRegex ? _groupIndex : 0,
    );
    Navigator.pop(context, entry);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      title: const Text('新建高亮'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.75,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 名称
              const Text('名称'),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                  hintText: '给这条高亮起个名（可留空）',
                ),
              ),
              const SizedBox(height: 12),

              // 关键词 / 正则
              Text(_isRegex ? '正则表达式' : '关键词 / 正则'),
              TextField(
                controller: _kwCtrl,
                onChanged: (_) => _validateRegex(),
                style: _isRegex
                    ? const TextStyle(fontFamily: 'monospace')
                    : null,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  isDense: true,
                  hintText: _isRegex
                      ? r'例如：(?<=「)[^」]+(?=」)'
                      : '要匹配的内容',
                ),
              ),
              const SizedBox(height: 8),

              // 使用正则开关
              Row(
                children: [
                  const Text('使用正则', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 4),
                  const Tooltip(
                    message: '开：上方内容按正则解析\n'
                        '关：按字面匹配',
                    child: Icon(Icons.info_outline, size: 14),
                  ),
                  const Spacer(),
                  Switch(
                    value: _isRegex,
                    onChanged: (v) {
                      setState(() => _isRegex = v);
                      _validateRegex();
                    },
                  ),
                ],
              ),
              if (_regexError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _regexError!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),

              // 捕获组索引（仅正则模式显示）
              if (_isRegex) ...[
                const SizedBox(height: 12),
                const Text('高亮第几个捕获组'),
                TextFormField(
                  key: ValueKey('new_group_$_groupIndex'),
                  initialValue: _groupIndex.toString(),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: '0 = 整个匹配；1 = 第 1 对括号；2 = 第 2 对括号',
                  ),
                  onFieldSubmitted: (v) {
                    final n = int.tryParse(v.trim());
                    setState(() => _groupIndex = n ?? 0);
                  },
                  onChanged: (v) {
                    final n = int.tryParse(v.trim());
                    if (n != null && n >= 0) {
                      _groupIndex = n;
                    }
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '例：正则 "([^"]+)" 填 1，只高亮引号里的字。\n'
                    '   正则 (?<=「)[^」]+(?=」) 填 0，一样效果。',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),

              // 颜色选择
              const Text('颜色',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SizedBox(
                height: 56,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.palettes.length,
                  itemBuilder: (ctx, i) {
                    final p = widget.palettes[i];
                    final selected = i == _colorIndex;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: GestureDetector(
                        onTap: () => setState(() => _colorIndex = i),
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color:
                                p.isGradient ? null : Color(p.colors.first),
                            gradient: p.isGradient
                                ? LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: p.colors
                                        .map((c) => Color(c))
                                        .toList(growable: false),
                                    stops: p.stops.length == p.colors.length
                                        ? p.stops
                                        : null,
                                  )
                                : null,
                            border: Border.all(
                              color: selected ? Colors.blue : Colors.black12,
                              width: selected ? 3 : 1,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Color(p.textColor),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),

              // 分组
              const Text('分组',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String?>(
                value: _groupId,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('未分组'),
                  ),
                  for (final g in widget.groups)
                    DropdownMenuItem<String?>(
                      value: g.id,
                      child: Text(g.name),
                    ),
                ],
                onChanged: (v) => setState(() => _groupId = v),
              ),
            ],
          ),
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
}
