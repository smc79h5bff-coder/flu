import 'package:charset/charset.dart';

import '../domain/preprocessing_rule.dart';

/// 正则缓存：同一个 pattern 只编译一次，之后复用。
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

/// 展开替换串里的 $0 $1 $2 … 为捕获组内容。
/// $0 = 整个匹配。$1 = 第 1 组。找不到的组展开为空串。
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

/// 展开替换串里的 \1 \2 … 为捕获组内容。
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
/// 6 个开关的分工：
///   findRegex    → 查找用正则引擎 or 字面
///   findEscape   → 查找前把 \n \t 等还原
///   findDollar   → 保留 $ 的正则锚点含义（关则转义成字面）
///   replaceRegex → 替换时展开 \1 \2
///   replaceEscape→ 替换前把 \n \t 等还原
///   replaceDollar→ 替换时展开 $1 $2
///
/// 全部关闭 = 纯字符串查找 + 纯字符串替换。
String applyOneRule(String text, PreprocessingRule rule) {
  // 内置脚本优先，不走上面 6 个开关。
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

  // 1. 处理查找串
  var find = rule.findPattern;
  if (rule.findEscape) {
    find = unescapeEscapes(find);
  }
  if (find.isEmpty) return text;

  if (rule.findRegex) {
    // 2a. 正则匹配
    if (!rule.findDollar) {
      // 把 $ 当字面 → 转义掉
      find = find.replaceAll(r'$', r'\$');
    }
    RegExp re;
    try {
      re = _cachedRegex(find);
    } catch (_) {
      return text;
    }
    // 3a. 替换：有任意替换开关开 → 走 mapped 展开；否则直接 replaceAll。
    final needExpand =
        rule.replaceRegex || rule.replaceDollar || rule.replaceEscape;
    if (needExpand) {
      return text.replaceAllMapped(re, (m) => _buildReplacement(rule, m));
    }
    return text.replaceAll(re, rule.replaceWith);
  } else {
    // 2b. 字面匹配
    if (!text.contains(find)) return text;
    // 3b. 替换
    var replacement = rule.replaceWith;
    if (rule.replaceEscape) {
      replacement = unescapeEscapes(replacement);
    }
    if (rule.replaceDollar) {
      // 字面匹配无捕获组，$0 = 整个 find，$1 $2 … = 空
      replacement = replacement.replaceAll(r'$0', find);
      replacement = replacement.replaceAll(RegExp(r'\$\d+'), '');
    }
    if (rule.replaceRegex) {
      // \1 \2 … 无捕获组，全展开为空
      replacement = replacement.replaceAll(RegExp(r'\\\d+'), '');
    }
    return text.replaceAll(find, replacement);
  }
}

String _buildReplacement(PreprocessingRule rule, Match m) {
  var tpl = rule.replaceWith;
  if (rule.replaceEscape) {
    tpl = unescapeEscapes(tpl);
  }
  if (rule.replaceDollar) {
    tpl = expandDollarRefs(tpl, m);
  }
  if (rule.replaceRegex) {
    tpl = expandBackslashRefs(tpl, m);
  }
  return tpl;
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
