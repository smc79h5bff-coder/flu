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
