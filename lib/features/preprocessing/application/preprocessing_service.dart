import 'package:charset/charset.dart';

import '../domain/preprocessing_rule.dart';
import 'js_runtime.dart';
import 'presets.dart';

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
/// 三种 kind：
///   replace → 走 7 开关的查找替换（含内置脚本）
///   preset  → 走 presets.dart 里的预置功能
///   js      → 走 js_runtime.dart 里的 JS 引擎
String applyOneRule(String text, PreprocessingRule rule) {
  switch (rule.kind) {
    case RuleKind.preset:
      return _applyPreset(text, rule);
    case RuleKind.js:
      return _applyJs(text, rule);
    case RuleKind.replace:
      break;
  }
  return _applyReplace(text, rule);
}

// ==================== preset ====================

String _applyPreset(String text, PreprocessingRule rule) {
  final id = rule.presetId;
  if (id == null || id.isEmpty) return text;
  final preset = Presets.byId(id);
  if (preset == null) return text;
  try {
    return preset.apply(text, rule.params);
  } catch (_) {
    return text;
  }
}

// ==================== js ====================

String _applyJs(String text, PreprocessingRule rule) {
  final script = rule.jsScript;
  if (script == null || script.trim().isEmpty) return text;
  try {
    return JsRuntime.instance.run(script, text);
  } catch (_) {
    return text;
  }
}

// ==================== replace ====================

String _applyReplace(String text, PreprocessingRule rule) {
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
  final useRegex = rule.findRegex && !rule.findLiteral;

  if (useRegex) {
    RegExp re;
    try {
      re = _cachedRegex(find);
    } catch (_) {
      return text;
    }
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
