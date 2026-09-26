/// 预置功能。
///
/// 每条预置功能有：
///   - id：稳定标识，存进 PreprocessingRule.presetId
///   - name：显示名
///   - description：一句话说明
///   - params：参数定义（UI 根据它生成表单）
///   - apply：真正干活的函数
///
/// 参数在存储里都是字符串（Map<String, String>）。
/// 执行时用 _pInt / _pStr / _pBool 安全解析。

import 'dart:convert';

// ==================== 参数 ====================

/// 参数类型。UI 根据它决定用什么控件。
enum PresetParamType {
  /// 单行文本输入。
  text,

  /// 整数输入（数字键盘）。
  integer,

  /// 下拉选择。
  choice,
}

/// 一个参数的定义。
class PresetParam {
  const PresetParam({
    required this.key,
    required this.label,
    required this.type,
    this.defaultValue = '',
    this.options = const <String>[],
    this.hint = '',
  });

  final String key;
  final String label;
  final PresetParamType type;
  final String defaultValue;

  /// type == choice 时用。每项格式 'value|显示名'，无 '|' 则 value = 显示名。
  final List<String> options;

  final String hint;

  String labelFor(String value) {
    for (final o in options) {
      final idx = o.indexOf('|');
      if (idx < 0) {
        if (o == value) return o;
      } else {
        if (o.substring(0, idx) == value) return o.substring(idx + 1);
      }
    }
    return value;
  }
}

// ==================== Preset ====================

class Preset {
  const Preset({
    required this.id,
    required this.name,
    required this.description,
    required this.params,
    required this.apply,
  });

  final String id;
  final String name;
  final String description;
  final List<PresetParam> params;
  final String Function(String text, Map<String, String> params) apply;
}

// ==================== Presets 列表 ====================

class Presets {
  Presets._();

  static List<Preset> all() => const <Preset>[
        // ==================== 行操作 ====================
        Preset(
          id: 'lineFilter',
          name: '按关键词过滤行',
          description: '按关键词保留或删除整行',
          params: [
            PresetParam(
              key: 'mode',
              label: '模式',
              type: PresetParamType.choice,
              defaultValue: 'drop',
              options: ['drop|删除匹配的行', 'keep|只保留匹配的行'],
            ),
            PresetParam(
              key: 'keyword',
              label: '关键词',
              type: PresetParamType.text,
              hint: '要匹配的内容',
            ),
            PresetParam(
              key: 'match',
              label: '匹配方式',
              type: PresetParamType.choice,
              defaultValue: 'contains',
              options: [
                'contains|包含',
                'equals|等于整行',
                'startsWith|开头是',
                'endsWith|结尾是',
                'regex|用正则',
              ],
            ),
            PresetParam(
              key: 'caseSensitive',
              label: '区分大小写',
              type: PresetParamType.choice,
              defaultValue: 'false',
              options: ['false|否', 'true|是'],
            ),
          ],
          apply: _lineFilter,
        ),
        Preset(
          id: 'sliceLines',
          name: '截取第 N 到第 M 行',
          description: '只保留指定范围的行',
          params: [
            PresetParam(
              key: 'start',
              label: '起始行号',
              type: PresetParamType.integer,
              defaultValue: '1',
            ),
            PresetParam(
              key: 'end',
              label: '结束行号',
              type: PresetParamType.integer,
              defaultValue: '999999999',
              hint: '留大数字表示到末尾',
            ),
          ],
          apply: _sliceLines,
        ),
        Preset(
          id: 'removeEmptyLines',
          name: '删除空行',
          description: '删除长度为 0 的行',
          params: [],
          apply: _removeEmptyLines,
        ),
        Preset(
          id: 'removeBlankLines',
          name: '删除纯空白行',
          description: '删除只有空格/Tab 的行',
          params: [],
          apply: _removeBlankLines,
        ),
        Preset(
          id: 'addLineNumbers',
          name: '加行号',
          description: '每行前加序号，空行也编号',
          params: [
            PresetParam(
              key: 'start',
              label: '起始号',
              type: PresetParamType.integer,
              defaultValue: '1',
            ),
            PresetParam(
              key: 'format',
              label: '格式',
              type: PresetParamType.text,
              defaultValue: 'N. ',
              hint: 'N 会被替换成数字，如 "N." 或 "[N] " 或 "第N章 "',
            ),
          ],
          apply: _addLineNumbers,
        ),
        Preset(
          id: 'addLineNumbersSkipEmpty',
          name: '非空行加行号',
          description: '跳过空行和纯空白行',
          params: [
            PresetParam(
              key: 'start',
              label: '起始号',
              type: PresetParamType.integer,
              defaultValue: '1',
            ),
            PresetParam(
              key: 'format',
              label: '格式',
              type: PresetParamType.text,
              defaultValue: 'N. ',
              hint: 'N 会被替换成数字',
            ),
          ],
          apply: _addLineNumbersSkipEmpty,
        ),
        Preset(
          id: 'trimLines',
          name: '行首尾去空白',
          description: '删掉每行开头和结尾的空格/Tab',
          params: [],
          apply: _trimLines,
        ),
        Preset(
          id: 'trimLinesLeft',
          name: '行首去空白',
          description: '只删每行开头的空白',
          params: [],
          apply: _trimLinesLeft,
        ),
        Preset(
          id: 'trimLinesRight',
          name: '行尾去空白',
          description: '只删每行结尾的空白',
          params: [],
          apply: _trimLinesRight,
        ),
        Preset(
          id: 'mergeAllLines',
          name: '合并所有行为一行',
          description: '用连接符把所有行拼成一行',
          params: [
            PresetParam(
              key: 'separator',
              label: '连接符',
              type: PresetParamType.text,
              defaultValue: ' ',
              hint: '留空 = 直接贴在一起；可用 \\n \\t 转义',
            ),
          ],
          apply: _mergeAllLines,
        ),

        // ==================== 字符替换 ====================
        Preset(
          id: 'deleteString',
          name: '删除所有出现的字符串',
          description: '全篇查找一个固定字符串并删除',
          params: [
            PresetParam(
              key: 'target',
              label: '要删除的字符串',
              type: PresetParamType.text,
            ),
          ],
          apply: _deleteString,
        ),
        Preset(
          id: 'replaceString',
          name: '替换所有出现的字符串',
          description: '全篇查找一个固定字符串并替换',
          params: [
            PresetParam(
              key: 'target',
              label: '查找',
              type: PresetParamType.text,
            ),
            PresetParam(
              key: 'replacement',
              label: '替换为',
              type: PresetParamType.text,
              hint: '留空 = 删掉',
            ),
          ],
          apply: _replaceString,
        ),

        // ==================== 空白处理 ====================
        Preset(
          id: 'removeAllSpaces',
          name: '删除所有空格',
          description: '删掉全部半角空格（不含 Tab 和全角空格）',
          params: [],
          apply: _removeAllSpaces,
        ),
        Preset(
          id: 'removeAllTabs',
          name: '删除所有 Tab',
          description: '删掉全部 Tab 制表符',
          params: [],
          apply: _removeAllTabs,
        ),
        Preset(
          id: 'removeAllWhitespace',
          name: '删除所有空白',
          description: '删掉所有空格、Tab、换行、全角空格（危险，会连成一片）',
          params: [],
          apply: _removeAllWhitespace,
        ),
        Preset(
          id: 'removePunctuation',
          name: '删除所有标点',
          description: '删掉中英文标点，保留字母数字汉字',
          params: [],
          apply: _removePunctuation,
        ),
        Preset(
          id: 'removeDigits',
          name: '删除所有数字',
          description: '删掉全部半角数字 0-9',
          params: [],
          apply: _removeDigits,
        ),
        Preset(
          id: 'removeEnglish',
          name: '删除所有英文',
          description: '删掉全部英文字母 a-z A-Z',
          params: [],
          apply: _removeEnglish,
        ),
        Preset(
          id: 'removeNonChinese',
          name: '删除所有非中文',
          description: '只保留常用汉字，其它全删',
          params: [],
          apply: _removeNonChinese,
        ),
        Preset(
          id: 'removeInvisible',
          name: '删除不可见字符',
          description: '删掉零宽空格、BOM、方向控制符等看不见的字符',
          params: [],
          apply: _removeInvisible,
        ),
        Preset(
          id: 'collapseSpaces',
          name: '连续空白折叠成一个空格',
          description: '多个连续空格/Tab/全角空格压成一个半角空格',
          params: [],
          apply: _collapseSpaces,
        ),
        Preset(
          id: 'collapseNewlines',
          name: '连续换行折叠成一个',
          description: '多个连续换行压成一个，删掉所有空行',
          params: [],
          apply: _collapseNewlines,
        ),
        Preset(
          id: 'foldNewlines',
          name: '连续 N 换行折成 M 个',
          description: '连续超过 N 个换行压到 M 个（N=3 M=2 → 最多留一个空行）',
          params: [
            PresetParam(
              key: 'n',
              label: '触发阈值 N',
              type: PresetParamType.integer,
              defaultValue: '3',
            ),
            PresetParam(
              key: 'm',
              label: '压到 M 个',
              type: PresetParamType.integer,
              defaultValue: '2',
            ),
          ],
          apply: _foldNewlines,
        ),
        Preset(
          id: 'collapseDots',
          name: '连续点号折成省略号',
          description: '2 个以上连续点号压成一个 …',
          params: [],
          apply: _collapseDots,
        ),
        Preset(
          id: 'trimTrailingSpaces',
          name: '删除行尾多余空格',
          description: '删掉每行末尾的空格和 Tab',
          params: [],
          apply: _trimLinesRight,
        ),

        // ==================== 大小写与全半角 ====================
        Preset(
          id: 'toUpperCase',
          name: '小写转大写',
          description: '所有英文小写字母转大写',
          params: [],
          apply: _toUpperCase,
        ),
        Preset(
          id: 'fullToHalf',
          name: '全角转半角',
          description: '全角字母、数字、标点、空格转半角',
          params: [],
          apply: _fullToHalf,
        ),
        Preset(
          id: 'halfToFull',
          name: '半角转全角',
          description: '半角字母、数字、标点、空格转全角',
          params: [],
          apply: _halfToFull,
        ),
        Preset(
          id: 'fullSpaceToHalf',
          name: '全角空格转半角',
          description: '只转全角空格，不动其它全角字符',
          params: [],
          apply: _fullSpaceToHalf,
        ),
        Preset(
          id: 'tabToSpaces',
          name: 'Tab 转 N 个空格',
          description: '每个 Tab 换成一串半角空格',
          params: [
            PresetParam(
              key: 'n',
              label: 'N',
              type: PresetParamType.integer,
              defaultValue: '4',
            ),
          ],
          apply: _tabToSpaces,
        ),
        Preset(
          id: 'spacesToTab',
          name: 'N 个空格转 Tab',
          description: '正好 N 个连续半角空格换成一个 Tab',
          params: [
            PresetParam(
              key: 'n',
              label: 'N',
              type: PresetParamType.integer,
              defaultValue: '4',
            ),
          ],
          apply: _spacesToTab,
        ),

        // ==================== 标点转换 ====================
        Preset(
          id: 'cnPunctToEn',
          name: '中文标点转英文',
          description: '把中文标点替换成英文标点',
          params: [],
          apply: _cnPunctToEn,
        ),
        Preset(
          id: 'enPunctToCn',
          name: '英文标点转中文',
          description: '把英文标点替换成中文标点',
          params: [],
          apply: _enPunctToCn,
        ),
        Preset(
          id: 'unifyQuotes',
          name: '中文引号统一',
          description: '各种方向引号统一成一对',
          params: [
            PresetParam(
              key: 'target',
              label: '目标引号',
              type: PresetParamType.choice,
              defaultValue: 'curly',
              options: [
                'curly|中文弯引号 ""',
                'straight|英文直引号 ""',
                'corner|日式角括号 「」',
                'double-corner|日式双角括号 『』',
              ],
            ),
          ],
          apply: _unifyQuotes,
        ),

        // ==================== 数字 ====================
        Preset(
          id: 'digitsToPlaceholder',
          name: '数字替换成占位符',
          description: '连续数字替换成一个占位符',
          params: [
            PresetParam(
              key: 'placeholder',
              label: '占位符',
              type: PresetParamType.text,
              defaultValue: '<NUM>',
            ),
          ],
          apply: _digitsToPlaceholder,
        ),
        Preset(
          id: 'chineseToArabic',
          name: '中文数字转阿拉伯',
          description: '一二三 / 壹贰叁 转 123',
          params: [],
          apply: _chineseToArabic,
        ),
        Preset(
          id: 'arabicToChinese',
          name: '阿拉伯数字转中文',
          description: '123 转 一二三 或 一百二十三',
          params: [
            PresetParam(
              key: 'style',
              label: '样式',
              type: PresetParamType.choice,
              defaultValue: 'digit',
              options: [
                'digit|逐字式（123 → 一二三）',
                'read|读法式（123 → 一百二十三）',
              ],
            ),
          ],
          apply: _arabicToChinese,
        ),

        // ==================== Unicode ====================
        Preset(
          id: 'normalizeNfc',
          name: '规范化 Unicode（NFC）',
          description: '把 "基字符 + 组合符" 合并成单字符',
          params: [],
          apply: _normalizeNfc,
        ),
      ];

  /// 按 id 查找。
  static Preset? byId(String id) {
    for (final p in all()) {
      if (p.id == id) return p;
    }
    return null;
  }
}

// ==================== 参数解析辅助 ====================

String _pStr(Map<String, String> p, String key, [String fallback = '']) {
  final v = p[key];
  if (v == null) return fallback;
  return v;
}

int _pInt(Map<String, String> p, String key, [int fallback = 0]) {
  final v = p[key];
  if (v == null || v.isEmpty) return fallback;
  return int.tryParse(v) ?? fallback;
}

bool _pBool(Map<String, String> p, String key, [bool fallback = false]) {
  final v = p[key];
  if (v == null) return fallback;
  return v == 'true';
}

/// 把字符串里的 \n \r \t \\ \0 还原成真字符。
String _unescape(String s) {
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

// ==================== 行操作实现 ====================

String _lineFilter(String text, Map<String, String> p) {
  final keyword = _pStr(p, 'keyword');
  if (keyword.isEmpty) return text;
  final mode = _pStr(p, 'mode', 'drop');
  final match = _pStr(p, 'match', 'contains');
  final caseSensitive = _pBool(p, 'caseSensitive', false);

  RegExp? re;
  if (match == 'regex') {
    try {
      re = RegExp(keyword, caseSensitive: caseSensitive);
    } catch (_) {
      return text;
    }
  }

  bool hit(String l) {
    switch (match) {
      case 'equals':
        return caseSensitive
            ? l == keyword
            : l.toLowerCase() == keyword.toLowerCase();
      case 'startsWith':
        return caseSensitive
            ? l.startsWith(keyword)
            : l.toLowerCase().startsWith(keyword.toLowerCase());
      case 'endsWith':
        return caseSensitive
            ? l.endsWith(keyword)
            : l.toLowerCase().endsWith(keyword.toLowerCase());
      case 'regex':
        return re!.hasMatch(l);
      case 'contains':
      default:
        return caseSensitive
            ? l.contains(keyword)
            : l.toLowerCase().contains(keyword.toLowerCase());
    }
  }

  final lines = text.split('\n');
  final out = <String>[];
  for (final l in lines) {
    final h = hit(l);
    if (mode == 'keep' ? h : !h) out.add(l);
  }
  return out.join('\n');
}

String _sliceLines(String text, Map<String, String> p) {
  final start = _pInt(p, 'start', 1);
  final end = _pInt(p, 'end', 999999999);
  final lines = text.split('\n');
  var s = start - 1;
  if (s < 0) s = 0;
  if (s > lines.length) s = lines.length;
  var e = end;
  if (e < s) e = s;
  if (e > lines.length) e = lines.length;
  return lines.sublist(s, e).join('\n');
}

String _removeEmptyLines(String text, Map<String, String> p) {
  return text.split('\n').where((l) => l.isNotEmpty).join('\n');
}

String _removeBlankLines(String text, Map<String, String> p) {
  return text.split('\n').where((l) => l.trim().isNotEmpty).join('\n');
}

String _addLineNumbers(String text, Map<String, String> p) {
  return _applyLineNumbers(text, p, skipEmpty: false);
}

String _addLineNumbersSkipEmpty(String text, Map<String, String> p) {
  return _applyLineNumbers(text, p, skipEmpty: true);
}

String _applyLineNumbers(
  String text,
  Map<String, String> p, {
  required bool skipEmpty,
}) {
  final start = _pInt(p, 'start', 1);
  var format = _pStr(p, 'format', 'N. ');
  if (format.isEmpty) format = 'N. ';
  final lines = text.split('\n');
  final out = <String>[];
  var n = start;
  for (final l in lines) {
    if (skipEmpty && l.trim().isEmpty) {
      out.add(l);
    } else {
      out.add(format.replaceAll('N', n.toString()) + l);
      n++;
    }
  }
  return out.join('\n');
}

String _trimLines(String text, Map<String, String> p) {
  return text.split('\n').map((l) => l.trim()).join('\n');
}

String _trimLinesLeft(String text, Map<String, String> p) {
  return text.split('\n').map((l) => l.trimLeft()).join('\n');
}

String _trimLinesRight(String text, Map<String, String> p) {
  return text.split('\n').map((l) => l.trimRight()).join('\n');
}

String _mergeAllLines(String text, Map<String, String> p) {
  final sep = _unescape(_pStr(p, 'separator', ' '));
  return text.split('\n').join(sep);
}

// ==================== 字符替换实现 ====================

String _deleteString(String text, Map<String, String> p) {
  final target = _pStr(p, 'target');
  if (target.isEmpty) return text;
  return text.replaceAll(target, '');
}

String _replaceString(String text, Map<String, String> p) {
  final target = _pStr(p, 'target');
  if (target.isEmpty) return text;
  final rep = _pStr(p, 'replacement');
  return text.replaceAll(target, rep);
}

// ==================== 空白处理实现 ====================

String _removeAllSpaces(String text, Map<String, String> p) {
  return text.replaceAll(' ', '');
}

String _removeAllTabs(String text, Map<String, String> p) {
  return text.replaceAll('\t', '');
}

/// \s 在 Dart 里覆盖所有 Unicode 空白（含全角空格 U+3000、NBSP、换行）。
String _removeAllWhitespace(String text, Map<String, String> p) {
  return text.replaceAll(RegExp(r'\s+'), '');
}

/// 中英文标点集合。
const Set<String> _punctuationSet = {
  // ASCII 标点
  '!', '"', '#', r'$', '%', '&', "'", '(', ')', '*', '+', ',', '-', '.', '/',
  ':', ';', '<', '=', '>', '?', '@', '[', r'\', ']', '^', '_', '`', '{', '|',
  '}', '~',
  // 中文标点
  '，', '。', '！', '？', '；', '：', '、',
  '\u201C', '\u201D', '\u2018', '\u2019', // 左右弯引号
  '（', '）', '【', '】', '《', '》', '〈', '〉', '「', '」', '『', '』',
  '—', '…', '·', '～', '＿', '－', '／', '＼',
  '\u3000', // 全角空格不算标点，这行删掉
};

/// 只删上面这些。注意 _punctuationSet 里我误加了全角空格，实现里跳过它。
String _removePunctuation(String text, Map<String, String> p) {
  final sb = StringBuffer();
  for (final rune in text.runes) {
    final c = String.fromCharCode(rune);
    if (c == '\u3000') {
      // 全角空格不算标点
      sb.write(c);
      continue;
    }
    if (!_punctuationSet.contains(c)) sb.write(c);
  }
  return sb.toString();
}

String _removeDigits(String text, Map<String, String> p) {
  return text.replaceAll(RegExp(r'[0-9]'), '');
}

String _removeEnglish(String text, Map<String, String> p) {
  return text.replaceAll(RegExp(r'[a-zA-Z]'), '');
}

String _removeNonChinese(String text, Map<String, String> p) {
  // 保留 CJK 基本汉字区 U+4E00 ~ U+9FA5
  return text.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '');
}

/// 零宽、软连字符、BOM、方向控制符等。
final RegExp _invisibleChars = RegExp(
  '[\u00AD\u200B-\u200F\u202A-\u202E'
  '\u2060-\u2064\u2066-\u2069\uFEFF]',
);

String _removeInvisible(String text, Map<String, String> p) {
  return text.replaceAll(_invisibleChars, '');
}

/// 所有空白类字符（不含换行），一个或多个连续，压成一个半角空格。
final RegExp _runOfSpaces = RegExp(
  '[ \t\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000\u200B\u200C\u200D'
  '\u2060\uFEFF]+',
);

String _collapseSpaces(String text, Map<String, String> p) {
  return text.replaceAll(_runOfSpaces, ' ');
}

String _collapseNewlines(String text, Map<String, String> p) {
  // 先把 \r\n、\r 归一成 \n，再把 2 个以上 \n 压成 1 个。
  var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return t.replaceAll(RegExp(r'\n{2,}'), '\n');
}

String _foldNewlines(String text, Map<String, String> p) {
  var n = _pInt(p, 'n', 3);
  var m = _pInt(p, 'm', 2);
  if (n < 1) n = 1;
  if (m < 0) m = 0;
  var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final re = RegExp('\n{$n,}');
  return t.replaceAllMapped(re, (_) => '\n' * m);
}

/// 连续 2 个以上点号（. 。 … ‥），压成一个 …
final RegExp _runOfDots = RegExp('[.\u3002\u2026\u2025]{2,}');

String _collapseDots(String text, Map<String, String> p) {
  return text.replaceAll(_runOfDots, '\u2026');
}

// ==================== 大小写与全半角实现 ====================

String _toUpperCase(String text, Map<String, String> p) {
  return text.toUpperCase();
}

/// 全角 → 半角。U+FF01 ~ U+FF5E → 减 0xFEE0；U+3000 → U+0020。
String _fullToHalf(String text, Map<String, String> p) {
  return String.fromCharCodes(text.runes.map((c) {
    if (c >= 0xFF01 && c <= 0xFF5E) return c - 0xFEE0;
    if (c == 0x3000) return 0x20;
    return c;
  }));
}

/// 半角 → 全角。U+0021 ~ U+007E → 加 0xFEE0；U+0020 → U+3000。
String _halfToFull(String text, Map<String, String> p) {
  return String.fromCharCodes(text.runes.map((c) {
    if (c >= 0x21 && c <= 0x7E) return c + 0xFEE0;
    if (c == 0x20) return 0x3000;
    return c;
  }));
}

String _fullSpaceToHalf(String text, Map<String, String> p) {
  return text.replaceAll('\u3000', ' ');
}

String _tabToSpaces(String text, Map<String, String> p) {
  var n = _pInt(p, 'n', 4);
  if (n < 1) n = 1;
  return text.replaceAll('\t', ' ' * n);
}

String _spacesToTab(String text, Map<String, String> p) {
  var n = _pInt(p, 'n', 4);
  if (n < 1) n = 1;
  final re = RegExp(' ' + '{$n}');
  return text.replaceAll(re, '\t');
}

// ==================== 标点转换实现 ====================

const Map<String, String> _cnToEnPunct = {
  '，': ',',
  '。': '.',
  '！': '!',
  '？': '?',
  '；': ';',
  '：': ':',
  '\u201C': '"',
  '\u201D': '"',
  '\u2018': "'",
  '\u2019': "'",
  '（': '(',
  '）': ')',
  '【': '[',
  '】': ']',
  '《': '<',
  '》': '>',
  '〈': '<',
  '〉': '>',
  '「': '"',
  '」': '"',
  '『': '"',
  '』': '"',
  '、': ',',
  '—': '-',
  '…': '...',
  '～': '~',
  '・': '·',
};

const Map<String, String> _enToCnPunct = {
  ',': '，',
  '.': '。',
  '!': '！',
  '?': '？',
  ';': '；',
  ':': '：',
  '(': '（',
  ')': '）',
  '[': '【',
  ']': '】',
  '<': '《',
  '>': '》',
  '-': '—',
  '~': '～',
};

String _cnPunctToEn(String text, Map<String, String> p) {
  var out = text;
  for (final e in _cnToEnPunct.entries) {
    out = out.replaceAll(e.key, e.value);
  }
  return out;
}

String _enPunctToCn(String text, Map<String, String> p) {
  var out = text;
  for (final e in _enToCnPunct.entries) {
    out = out.replaceAll(e.key, e.value);
  }
  return out;
}

String _unifyQuotes(String text, Map<String, String> p) {
  final target = _pStr(p, 'target', 'curly');
  String left, right;
  switch (target) {
    case 'straight':
      left = '"';
      right = '"';
      break;
    case 'corner':
      left = '「';
      right = '」';
      break;
    case 'double-corner':
      left = '『';
      right = '』';
      break;
    case 'curly':
    default:
      left = '\u201C';
      right = '\u201D';
      break;
  }
  // 左引号来源。
  const leftSources = ['\u201C', '「', '『', '\u2018'];
  // 右引号来源。
  const rightSources = ['\u201D', '」', '』', '\u2019'];

  var out = text;
  for (final c in leftSources) {
    out = out.replaceAll(c, left);
  }
  for (final c in rightSources) {
    out = out.replaceAll(c, right);
  }
  return out;
}

// ==================== 数字实现 ====================

String _digitsToPlaceholder(String text, Map<String, String> p) {
  final ph = _pStr(p, 'placeholder', '<NUM>');
  return text.replaceAll(RegExp(r'[0-9]+'), ph);
}

// ---- 中文数字 → 阿拉伯 ----

const Map<String, int> _cnDigitMap = {
  '零': 0, '〇': 0,
  '一': 1, '壹': 1, '幺': 1,
  '二': 2, '贰': 2, '两': 2,
  '三': 3, '叁': 3, '仨': 3,
  '四': 4, '肆': 4,
  '五': 5, '伍': 5,
  '六': 6, '陆': 6,
  '七': 7, '柒': 7,
  '八': 8, '捌': 8,
  '九': 9, '玖': 9,
};

const Map<String, int> _cnUnitMap = {
  '十': 10, '拾': 10,
  '百': 100, '佰': 100,
  '千': 1000, '仟': 1000,
  '万': 10000, '萬': 10000,
  '亿': 100000000, '億': 100000000,
};

String _chineseToArabic(String text, Map<String, String> p) {
  // 构造一个能匹配"连续中文数字字符"的正则。
  final allChars = <String>[
    ..._cnDigitMap.keys,
    ..._cnUnitMap.keys,
  ];
  final escaped = allChars.map((c) => RegExp.escape(c)).join();
  final re = RegExp('[$escaped]+');
  return text.replaceAllMapped(re, (m) {
    final s = m[0]!;
    final n = _parseChineseNumber(s);
    return n.toString();
  });
}

int _parseChineseNumber(String s) {
  // 没有单位（十百千万亿）→ 纯数字串，逐位拼。
  final hasUnit = s.split('').any(_cnUnitMap.containsKey);
  if (!hasUnit) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      n = n * 10 + (_cnDigitMap[s[i]] ?? 0);
    }
    return n;
  }

  // 有单位 → 按节解析。
  int result = 0;
  int section = 0;
  int current = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (_cnDigitMap.containsKey(c)) {
      current = _cnDigitMap[c]!;
    } else if (_cnUnitMap.containsKey(c)) {
      final u = _cnUnitMap[c]!;
      if (u >= 10000) {
        section = (section + current) * u;
        result += section;
        section = 0;
        current = 0;
      } else {
        if (current == 0) current = 1;
        section += current * u;
        current = 0;
      }
    }
  }
  return result + section + current;
}

// ---- 阿拉伯 → 中文 ----

const List<String> _cnDigits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];

String _arabicToChinese(String text, Map<String, String> p) {
  final style = _pStr(p, 'style', 'digit');
  return text.replaceAllMapped(RegExp(r'[0-9]+'), (m) {
    final s = m[0]!;
    if (style == 'digit') {
      return s.split('').map((c) => _cnDigits[int.parse(c)]).join();
    }
    final n = int.tryParse(s);
    if (n == null) return s;
    return _intToChinese(n);
  });
}

String _intToChinese(int n) {
  if (n == 0) return '零';
  if (n < 0) return '负' + _intToChinese(-n);

  final sections = <int>[];
  var m = n;
  while (m > 0) {
    sections.add(m % 10000);
    m ~/= 10000;
  }

  const unitSmall = ['', '十', '百', '千'];
  const unitBig = ['', '万', '亿', '兆'];

  final parts = <String>[];
  bool lastZero = false;

  for (var i = sections.length - 1; i >= 0; i--) {
    final sec = sections[i];
    if (sec == 0) {
      if (parts.isNotEmpty) lastZero = true;
      continue;
    }
    if (lastZero && parts.isNotEmpty) {
      parts.add('零');
    }
    lastZero = false;

    final secParts = <String>[];
    var s = sec;
    var unitIdx = 0;
    bool pendingZero = false;
    while (s > 0) {
      final d = s % 10;
      if (d == 0) {
        if (secParts.isNotEmpty) pendingZero = true;
      } else {
        if (pendingZero) {
          secParts.insert(0, '零');
          pendingZero = false;
        }
        secParts.insert(0, _cnDigits[d] + unitSmall[unitIdx]);
      }
      s ~/= 10;
      unitIdx++;
    }
    var secStr = secParts.join();
    if (secStr.startsWith('一十')) secStr = secStr.substring(1);
    parts.add(secStr + unitBig[i]);
  }

  var out = parts.join();
  if (out.startsWith('一十')) out = out.substring(1);
  return out;
}

// ==================== Unicode NFC（近似实现） ====================

/// 预组合字符映射。key = 基字符 + 组合符，value = 单字符。
const Map<String, String> _nfcCombos = {
  'a\u0300': '\u00E0', 'a\u0301': '\u00E1', 'a\u0302': '\u00E2',
  'a\u0303': '\u00E3', 'a\u0308': '\u00E4', 'a\u030A': '\u00E5',
  'e\u0300': '\u00E8', 'e\u0301': '\u00E9', 'e\u0302': '\u00EA',
  'e\u0308': '\u00EB',
  'i\u0300': '\u00EC', 'i\u0301': '\u00ED', 'i\u0302': '\u00EE',
  'i\u0308': '\u00EF',
  'o\u0300': '\u00F2', 'o\u0301': '\u00F3', 'o\u0302': '\u00F4',
  'o\u0303': '\u00F5', 'o\u0308': '\u00F6',
  'u\u0300': '\u00F9', 'u\u0301': '\u00FA', 'u\u0302': '\u00FB',
  'u\u0308': '\u00FC',
  'A\u0300': '\u00C0', 'A\u0301': '\u00C1', 'A\u0302': '\u00C2',
  'A\u0303': '\u00C3', 'A\u0308': '\u00C4', 'A\u030A': '\u00C5',
  'E\u0300': '\u00C8', 'E\u0301': '\u00C9', 'E\u0302': '\u00CA',
  'E\u0308': '\u00CB',
  'I\u0300': '\u00CC', 'I\u0301': '\u00CD', 'I\u0302': '\u00CE',
  'I\u0308': '\u00CF',
  'O\u0300': '\u00D2', 'O\u0301': '\u00D3', 'O\u0302': '\u00D4',
  'O\u0303': '\u00D5', 'O\u0308': '\u00D6',
  'U\u0300': '\u00D9', 'U\u0301': '\u00DA', 'U\u0302': '\u00DB',
  'U\u0308': '\u00DC',
  'n\u0303': '\u00F1', 'N\u0303': '\u00D1',
  'c\u0327': '\u00E7', 'C\u0327': '\u00C7',
};

String _normalizeNfc(String text, Map<String, String> p) {
  // 简易 NFC：只处理常见拉丁字母的"基础 + 组合符"。
  // 完整 NFC 需要 unorm_dart 或 unicode 包，用户如有需要可换。
  if (!text.contains('\u0300') &&
      !text.contains('\u0301') &&
      !text.contains('\u0302') &&
      !text.contains('\u0303') &&
      !text.contains('\u0308') &&
      !text.contains('\u030A') &&
      !text.contains('\u0327')) {
    return text;
  }
  var out = text;
  for (final e in _nfcCombos.entries) {
    out = out.replaceAll(e.key, e.value);
  }
  return out;
}

// ==================== JSON 辅助（给 UI 用） ====================

/// 序列化参数 map。
String encodeParams(Map<String, String> p) => jsonEncode(p);

/// 反序列化参数 map。
Map<String, String> decodeParams(String raw) {
  if (raw.isEmpty) return const {};
  try {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, v?.toString() ?? ''));
  } catch (_) {
    return const {};
  }
}
