import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../../preprocessing/application/aho_corasick.dart';
import '../../../preprocessing/application/builtin_rules.dart';
import '../../../preprocessing/application/preprocessing_service.dart';
import '../../../preprocessing/domain/preprocessing_rule.dart';
import '../../domain/import_source.dart';

// ==================== 正则缓存 ====================

/// 上限 [_regexCacheCap] 条，超出后清空重建。
const int _regexCacheCap = 512;
final Map<String, RegExp> _regexCache = {};

RegExp _cachedRegex(String pattern, {bool multiLine = false}) {
  final key = '$multiLine|$pattern';
  final hit = _regexCache[key];
  if (hit != null) return hit;
  if (_regexCache.length >= _regexCacheCap) {
    _regexCache.clear();
  }
  final re = RegExp(pattern, multiLine: multiLine);
  _regexCache[key] = re;
  return re;
}

/// 正则元字符。findPattern 含任意一个 → 走正则引擎；否则走 String 快路径。
final RegExp _regexMeta = RegExp(r'[\^$.*+?()\[\]{}|\\]');

bool _isPlainText(String s) => !_regexMeta.hasMatch(s);

// ==================== 写死水印词库（可选） ====================

/// 固定水印词库。全部走 Aho-Corasick 一次扫描删除。
/// 留空表示不用。填的话直接往里加字符串。
///
/// 例：
///   'xx小说网',
///   'xx整理',
const List<String> builtinWatermarks = <String>[
  // 你的 300 个词填这里
];

/// 顶层 AC，写死词库只建一次 trie，永远不重建。
/// 词库为空时是 null，运行时跳过。
final AhoCorasick? _watermarkAc = builtinWatermarks.isEmpty
    ? null
    : AhoCorasick(
        patterns: builtinWatermarks,
        replacements: List<String>.filled(builtinWatermarks.length, ''),
      );

// ==================== 关键词规则解析缓存 + AC 缓存 ====================

/// 一条规则文本解析出来的成果：删除类 AC + 替换类 AC。
class _ParsedKeywordRules {
  const _ParsedKeywordRules(this.deleteAc, this.replaceAc);
  final AhoCorasick? deleteAc;
  final AhoCorasick? replaceAc;
}

/// 上限 [_keywordRulesCacheCap] 条，超出清空。
const int _keywordRulesCacheCap = 16;
final Map<String, _ParsedKeywordRules> _keywordRulesCache = {};

_ParsedKeywordRules _parseKeywordRules(String rulesText) {
  final hit = _keywordRulesCache[rulesText];
  if (hit != null) return hit;

  final deletions = <String>[];
  final replacements = <({String find, String replace})>[];

  for (final raw in rulesText.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final idx = line.indexOf('->=>');
    if (idx >= 0) {
      final find = line.substring(0, idx);
      final replace = line.substring(idx + 4);
      if (find.isNotEmpty) {
        replacements.add((find: find, replace: replace));
      }
    } else {
      deletions.add(line);
    }
  }

  final deleteAc = deletions.isEmpty
      ? null
      : AhoCorasick(
          patterns: deletions,
          replacements: List<String>.filled(deletions.length, ''),
        );

  AhoCorasick? replaceAc;
  if (replacements.isNotEmpty) {
    final patterns = <String>[];
    final reps = <String>[];
    for (final r in replacements) {
      patterns.add(r.find);
      reps.add(_unescapeReplacement(r.replace));
    }
    replaceAc = AhoCorasick(patterns: patterns, replacements: reps);
  }

  final parsed = _ParsedKeywordRules(deleteAc, replaceAc);
  if (_keywordRulesCache.length >= _keywordRulesCacheCap) {
    _keywordRulesCache.clear();
  }
  _keywordRulesCache[rulesText] = parsed;
  return parsed;
}

// ==================== 正则规则解析缓存 ====================

class _ParsedRegexRule {
  const _ParsedRegexRule(this.find, this.replace, this.isPlain);
  final String find;
  final String replace;
  final bool isPlain;
}

const int _regexRulesCacheCap = 16;
final Map<String, List<_ParsedRegexRule>> _regexRulesCache = {};

List<_ParsedRegexRule> _parseRegexRules(String rulesText) {
  final hit = _regexRulesCache[rulesText];
  if (hit != null) return hit;

  final out = <_ParsedRegexRule>[];
  for (final raw in rulesText.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final idx = line.indexOf('->=>');
    final find = idx >= 0 ? line.substring(0, idx) : line;
    final replace = idx >= 0 ? line.substring(idx + 4) : '';
    if (find.isEmpty) continue;
    out.add(_ParsedRegexRule(
      find,
      _unescapeReplacement(replace),
      _isPlainText(find),
    ));
  }

  if (_regexRulesCache.length >= _regexRulesCacheCap) {
    _regexRulesCache.clear();
  }
  _regexRulesCache[rulesText] = out;
  return out;
}

// ==================== Providers ====================

/// Holds the *raw* text imported from a local file / clipboard.
/// **不持久化**：重启后清空。
final originalRawTextProvider = StateProvider<String?>((ref) => null);
final modifiedRawTextProvider = StateProvider<String?>((ref) => null);

/// 导入文件的文件名（用于在导入卡片旁展示）。**不持久化**。
final originalFileNameProvider = StateProvider<String?>((ref) => null);
final modifiedFileNameProvider = StateProvider<String?>((ref) => null);

/// 导入文件的真实磁盘路径。**不持久化**。
final originalFilePathProvider = StateProvider<String?>((ref) => null);
final modifiedFilePathProvider = StateProvider<String?>((ref) => null);

/// Encoding label surfaced in the export footer. **不持久化**。
final originalEncodingProvider = StateProvider<String>((ref) => 'UTF-8');
final modifiedEncodingProvider = StateProvider<String>((ref) => 'UTF-8');

/// Toggles "show processed text" vs "show original text" in the viewer.
/// **不持久化**。
final showProcessedTextProvider = StateProvider<bool>((ref) => false);

// ==================== 自定义预处理规则（持久化） ====================

final userRulesProvider =
    NotifierProvider<UserRulesNotifier, List<PreprocessingRule>>(
  UserRulesNotifier.new,
);

class UserRulesNotifier extends PersistentNotifier<List<PreprocessingRule>> {
  @override
  String get key => PrefKeys.userRules;

  @override
  List<PreprocessingRule> get defaultValue => const [];

  @override
  List<PreprocessingRule> decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in list)
        PreprocessingRule.fromJson(e as Map<String, dynamic>),
    ];
  }

  @override
  String encode(List<PreprocessingRule> value) =>
      jsonEncode([for (final r in value) r.toJson()]);

  void add(PreprocessingRule rule) => update([...state, rule]);

  void updateRule(PreprocessingRule rule) => update([
        for (final r in state)
          if (r.id == rule.id) rule else r,
      ]);

  void remove(String id) =>
      update(state.where((r) => r.id != id).toList());

  void toggle(String id) => update([
        for (final r in state)
          if (r.id == id) r.copyWith(enabled: !r.enabled) else r,
      ]);

  void importFromJson(List<Map<String, dynamic>> json) =>
      update(json.map(PreprocessingRule.fromJson).toList());
}

// ==================== 内置规则启用状态（持久化） ====================

final builtinRuleEnablesProvider =
    NotifierProvider<BuiltinRuleEnablesNotifier, Map<String, bool>>(
  BuiltinRuleEnablesNotifier.new,
);

class BuiltinRuleEnablesNotifier
    extends PersistentNotifier<Map<String, bool>> {
  @override
  String get key => PrefKeys.builtinRuleEnables;

  @override
  Map<String, bool> get defaultValue => <String, bool>{
        for (final r in BuiltinRules.all()) r.id: r.enabled,
      };

  @override
  Map<String, bool> decode(String raw) {
    final saved = jsonDecode(raw) as Map<String, dynamic>;
    final out = <String, bool>{
      for (final r in BuiltinRules.all()) r.id: r.enabled,
    };
    for (final e in saved.entries) {
      if (out.containsKey(e.key)) {
        out[e.key] = e.value == true;
      }
    }
    return out;
  }

  @override
  String encode(Map<String, bool> value) => jsonEncode(value);

  void setOne(String id, bool enabled) {
    update({...state, id: enabled});
  }
}

final builtinRulesWithStateProvider = Provider<List<PreprocessingRule>>((ref) {
  final overrides = ref.watch(builtinRuleEnablesProvider);
  return <PreprocessingRule>[
    for (final r in BuiltinRules.all())
      r.copyWith(enabled: overrides[r.id] ?? r.enabled),
  ];
});

// ==================== 关键词 / 正则替换规则（持久化） ====================

final keywordRulesTextProvider =
    NotifierProvider<KeywordRulesTextNotifier, String>(
  KeywordRulesTextNotifier.new,
);

class KeywordRulesTextNotifier extends StringPrefNotifier {
  KeywordRulesTextNotifier() : super(key: PrefKeys.keywordRulesText);
}

final regexRulesTextProvider =
    NotifierProvider<RegexRulesTextNotifier, String>(
  RegexRulesTextNotifier.new,
);

class RegexRulesTextNotifier extends StringPrefNotifier {
  RegexRulesTextNotifier() : super(key: PrefKeys.regexRulesText);
}

/// 把替换串里的转义序列（\n \r \t \\ \0）转成真正的控制字符。
String _unescapeReplacement(String s) {
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

/// 应用关键词规则到 [text]。
///
/// 顺序：
///   1. 先跑写死水印词库（顶层 AC，永不重建）
///   2. 再跑用户关键词规则（解析 + AC 按规则文本缓存，规则不变不重建）
///
/// 语义：
/// - 最长模式优先（AC 天然支持）
/// - 非重叠匹配
/// - 删除类和替换类**不链式触发**（一次扫完，不回头处理新文本）
String applyKeywordRules(String text, String rulesText) {
  if (text.isEmpty) return text;

  var out = text;

  // 1. 写死水印词库
  final wm = _watermarkAc;
  if (wm != null) {
    out = wm.replaceAll(out);
  }

  // 2. 用户关键词规则
  if (rulesText.isEmpty) return out;
  final parsed = _parseKeywordRules(rulesText);
  if (parsed.deleteAc != null) {
    out = parsed.deleteAc!.replaceAll(out);
  }
  if (parsed.replaceAc != null) {
    out = parsed.replaceAc!.replaceAll(out);
  }
  return out;
}

/// 应用正则规则到 [text]。逐条 replaceAll，非法正则跳过。
///
/// 纯文本 find 走 String.replaceAll 快路径：
///   - 目标串在文本里不存在 → 跳过，不编译正则
///   - 存在 → String.replaceAll，绕开正则引擎
/// 含元字符的 find 走正则引擎（带缓存）。
///
/// 解析结果按规则文本缓存，规则不变不重复解析。
String applyRegexRules(String text, String rulesText) {
  if (text.isEmpty || rulesText.isEmpty) return text;

  final rules = _parseRegexRules(rulesText);
  var out = text;
  for (final r in rules) {
    if (r.isPlain) {
      if (!out.contains(r.find)) continue;
      out = out.replaceAll(r.find, r.replace);
    } else {
      try {
        out = out.replaceAll(_cachedRegex(r.find), r.replace);
      } catch (_) {
        // 非法正则忽略，不影响其它规则。
      }
    }
  }
  return out;
}

/// Computed: produces preprocessed text for both sides.
final preprocessedOriginalProvider = Provider<String>((ref) {
  final raw = ref.watch(originalRawTextProvider);
  if (raw == null) return '';
  final rules = ref.watch(userRulesProvider);
  final builtins = ref.watch(builtinRulesWithStateProvider);
  var out = PreprocessingService(userRules: rules, builtinRules: builtins)
      .apply(raw, isOriginal: true);
  out = applyKeywordRules(out, ref.watch(keywordRulesTextProvider));
  out = applyRegexRules(out, ref.watch(regexRulesTextProvider));
  return out;
});

final preprocessedModifiedProvider = Provider<String>((ref) {
  final raw = ref.watch(modifiedRawTextProvider);
  if (raw == null) return '';
  final rules = ref.watch(userRulesProvider);
  final builtins = ref.watch(builtinRulesWithStateProvider);
  var out = PreprocessingService(userRules: rules, builtinRules: builtins)
      .apply(raw, isOriginal: false);
  out = applyKeywordRules(out, ref.watch(keywordRulesTextProvider));
  out = applyRegexRules(out, ref.watch(regexRulesTextProvider));
  return out;
});

/// Bumped whenever a new import succeeds. **不持久化**。
final importRevisionProvider = StateProvider<int>((ref) => 0);

/// Currently selected import source. **不持久化**。
final selectedSourceProvider =
    StateProvider<ImportSource?>((ref) => null);
