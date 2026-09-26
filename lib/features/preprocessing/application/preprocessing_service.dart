import 'package:charset/charset.dart';

import '../domain/preprocessing_rule.dart';

/// 正则缓存。
const int _regexCacheCap = 512;
final Map<String, RegExp> _regexCache = {};

RegExp _cachedRegex(String pattern) {
  final hit = _regexCache[pattern];
  if (hit != null) return hit;
  if (_regexCache.length >= _regexCacheCap) {
    _regexCache.clear();
  }
  final re = RegExp(pattern, multiLine: true);
  _regexCache[pattern] = re;
  return re;
}

/// 还原 \n \r \t \\ \0 成真字符。
String unescapeEscapes(String s) {
  if (!s.contains(r'\')) return s;
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      final n = s[i + 1];
      switch (n) {
        case 'n':
          sb.write('\n');
          i++;
          continue;
        case 'r':
          sb.write('\r');
          i++;
          continue;
        case 't':
          sb.write('\t');
          i++;
          continue;
        case '0':
          sb.write('\u0000');
          i++;
          continue;
        case r'\':
          sb.write(r'\');
          i++;
          continue;
      }
    }
    sb.write(c);
  }
  return sb.toString();
}

/// 展开 $0 $1 $2 … 为捕获组内容。
String expandDollarRefs(String tpl, Match m) {
  if (!tpl.contains(r'$')) return tpl;
  final re = RegExp(r'\$(\d+)');
  final out = StringBuffer();
  var last = 0;
  for (final match in re.allMatches(tpl)) {
    out.write(tpl.substring(last, match.start));
    final idx = int.parse(match.group(1)!);
    if (idx == 0) {
      out.write(m.group(0) ?? '');
    } else {
      out.write(m.group(idx) ?? '');
    }
    last = match.end;
  }
  out.write(tpl.substring(last));
  return out.toString();
}

/// 展开 \1 \2 … 为捕获组内容。
String expandBackslashRefs(String tpl, Match m) {
  if (!tpl.contains(r'\')) return tpl;
  final re = RegExp(r'\\(\d+)');
  final out = StringBuffer();
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

/// 对一段文本执行一条规则。
///
/// 7 个开关分工：
///   查找侧：
///     findRegex      → 按正则解析（与 findLiteral 互斥）
///     findLiteral    → 按字面匹配（与 findRegex 互斥）
///     findEscape     → 先还原 \n \t 等再匹配
///   替换侧：
///     replaceDollar    → 展开 $1 $2
///     replaceBackslash → 展开 \1 \2
///     replaceLiteral   → 字面输出（与上面两个互斥）
///     replaceEscape    → 先还原 \n \t 等再输出
String applyOneRule(String text, PreprocessingRule rule) {
  // 内置脚本优先。
  final script = rule.script;
  if (script != null && script.isNotEmpty) {
    switch (script) {
      case 'lowercase':
        return text.toLowerCase();
      case 'dropEmptyLines':
        return text.split('\n').where((l) => l.trim().isNotEmpty).join('\n');
      case 'unifyAnsi':
        return unifyToAnsi(text);
    }
    return text;
  }

  if (rule.findPattern.isEmpty) return text;

  // 1. 查找串预处理。
  var find = rule.findPattern;
  if (rule.findEscape) find = unescapeEscapes(find);
  if (find.isEmpty) return text;

  // 2. 用正则还是字面。
  //    findLiteral=true → 强制字面。
  //    findRegex=false 且 findLiteral=false → 兜底也走字面。
  final useRegex = rule.findRegex && !rule.findLiteral;

  if (useRegex) {
    RegExp re;
    try {
      re = _cachedRegex(find);
    } catch (_) {
      return text;
    }
    // 替换需要展开或需要转义时才走 mapped；否则直接 replaceAll 更快。
    final needExpand =
        !rule.replaceLiteral && (rule.replaceDollar || rule.replaceBackslash);
    final needEscape = rule.replaceEscape;
    if (needExpand || needEscape) {
      return text.replaceAllMapped(re, (m) => _buildReplacement(rule, m));
    }
    return text.replaceAll(re, rule.replaceWith);
  } else {
    // 字面匹配。
    if (!text.contains(find)) return text;
    final replacement = _buildLiteralReplacement(rule, find);
    return text.replaceAll(find, replacement);
  }
}

String _buildReplacement(PreprocessingRule rule, Match m) {
  var tpl = rule.replaceWith;
  if (rule.replaceEscape) tpl = unescapeEscapes(tpl);
  if (rule.replaceLiteral) return tpl;
  if (rule.replaceDollar) tpl = expandDollarRefs(tpl, m);
  if (rule.replaceBackslash) tpl = expandBackslashRefs(tpl, m);
  return tpl;
}

String _buildLiteralReplacement(PreprocessingRule rule, String find) {
  var replacement = rule.replaceWith;
  if (rule.replaceEscape) replacement = unescapeEscapes(replacement);
  if (rule.replaceLiteral) return replacement;
  // 字面匹配无捕获组：$0 = 整个 find，$1+ = 空；\1+ = 空。
  if (rule.replaceDollar) {
    replacement = replacement.replaceAll(r'$0', find);
    replacement = replacement.replaceAll(RegExp(r'\$\d+'), '');
  }
  if (rule.replaceBackslash) {
    replacement = replacement.replaceAll(RegExp(r'\\\d+'), '');
  }
  return replacement;
}

/// 转 GBK 后能无损还原的字符保留，其余删掉。
String unifyToAnsi(String text) {
  try {
    final bytes = gbk.encode(text);
    if (gbk.decode(bytes) == text) return text;
  } catch (_) {}
  final sb = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    try {
      final bytes = gbk.encode(ch);
      if (gbk.decode(bytes) != ch) continue;
      sb.write(ch);
    } catch (_) {}
  }
  return sb.toString();
}
