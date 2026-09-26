import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../../preprocessing/application/aho_corasick.dart';
import '../../../preprocessing/application/builtin_rules.dart';
import '../../../preprocessing/application/preprocessing_service.dart';
import '../../../preprocessing/domain/preprocessing_rule.dart';
import '../../domain/import_source.dart';

// ==================== 特殊块标记 ====================

/// 统一规则顺序列表里，关键词块 / 正则块用这两个特殊 id 占位。
class RuleBlockIds {
  const RuleBlockIds._();
  static const String keyword = '__block_keyword__';
  static const String regex = '__block_regex__';
}

// ==================== 正则缓存 ====================

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

final RegExp _regexMeta = RegExp(r'[\^$.*+?()\[\]{}|\\]');

bool _isPlainText(String s) => !_regexMeta.hasMatch(s);

// ==================== 写死水印词库（可选） ====================

const List<String> builtinWatermarks = <String>[
  // 你的词填这里
];

final AhoCorasick? _watermarkAc = builtinWatermarks.isEmpty
    ? null
    : AhoCorasick(
        patterns: builtinWatermarks,
        replacements: List<String>.filled(builtinWatermarks.length, ''),
      );

// ==================== 关键词规则解析缓存 + AC 缓存 ====================

class _ParsedKeywordRules {
  const _ParsedKeywordRules(this.deleteAc, this.replaceAc);
  final AhoCorasick? deleteAc;
  final AhoCorasick? replaceAc;
}

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

// ==================== 文本 provider ====================

/// 原始文本（导入后从没被改过）。**不持久化**。
final originalRawTextProvider = StateProvider<String?>((ref) => null);
final modifiedRawTextProvider = StateProvider<String?>((ref) => null);

/// 用户在对比页编辑后的临时文本。
/// null = 没有编辑过，走规则计算。
final editedOriginalProvider = StateProvider<String?>((ref) => null);
final editedModifiedProvider = StateProvider<String?>((ref) => null);

final originalFileNameProvider = StateProvider<String?>((ref) => null);
final modifiedFileNameProvider = StateProvider<String?>((ref) => null);

final originalFilePathProvider = StateProvider<String?>((ref) => null);
final modifiedFilePathProvider = StateProvider<String?>((ref) => null);

final originalEncodingProvider = StateProvider<String>((ref) => 'UTF-8');
final modifiedEncodingProvider = StateProvider<String>((ref) => 'UTF-8');

final showProcessedTextProvider = StateProvider<bool>((ref) => false);

final importRevisionProvider = StateProvider<int>((ref) => 0);

final selectedSourceProvider = StateProvider<ImportSource?>((ref) => null);

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

  void add(PreprocessingRule rule) {
    update([...state, rule]);
    // 追加到统一顺序列表末尾。
    ref.read(ruleOrderProvider.notifier).append(rule.id);
  }

  void updateRule(PreprocessingRule rule) => update([
        for (final r in state)
          if (r.id == rule.id) rule else r,
      ]);

  void remove(String id) {
    update(state.where((r) => r.id != id).toList());
    ref.read(ruleOrderProvider.notifier).removeId(id);
  }

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

/// id → 规则 的索引，内置 + 自定义都在里面。
final ruleByIdProvider = Provider<Map<String, PreprocessingRule>>((ref) {
  final builtins = ref.watch(builtinRulesWithStateProvider);
  final user = ref.watch(userRulesProvider);
  final map = <String, PreprocessingRule>{};
  for (final r in builtins) map[r.id] = r;
  for (final r in user) map[r.id] = r;
  return map;
});

// ==================== 统一规则顺序（持久化） ====================

final ruleOrderProvider =
    NotifierProvider<RuleOrderNotifier, List<String>>(
  RuleOrderNotifier.new,
);

class RuleOrderNotifier extends PersistentNotifier<List<String>> {
  @override
  String get key => PrefKeys.ruleOrder;

  @override
  List<String> get defaultValue => <String>[
        for (final r in BuiltinRules.all()) r.id,
        RuleBlockIds.keyword,
        RuleBlockIds.regex,
      ];

  @override
  List<String> decode(String raw) {
    if (raw.isEmpty) return defaultValue;
    return raw.split('\u0000').where((s) => s.isNotEmpty).toList();
  }

  @override
  String encode(List<String> value) => value.join('\u0000');

  void setAll(List<String> value) => update(List<String>.from(value));

  void append(String id) {
    if (state.contains(id)) return;
    update([...state, id]);
  }

  void removeId(String id) {
    if (!state.contains(id)) return;
    update(state.where((s) => s != id).toList());
  }
}

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

/// 关键词规则：整块 Aho-Corasick 一次扫。
String applyKeywordRules(String text, String rulesText) {
  if (text.isEmpty) return text;

  var out = text;

  final wm = _watermarkAc;
  if (wm != null) {
    out = wm.replaceAll(out);
  }

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

/// 正则规则：逐条 replaceAll。
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
      } catch (_) {}
    }
  }
  return out;
}

// ==================== 预处理管线 ====================

bool _inScope(PreprocessingRule rule, {required bool isOriginal}) {
  switch (rule.scope) {
    case RuleScope.both:
      return true;
    case RuleScope.originalOnly:
      return isOriginal;
    case RuleScope.modifiedOnly:
      return !isOriginal;
  }
}

/// 按用户排序，依次执行所有规则。
String _runPipeline(
  WidgetRef ref, {
  required String raw,
  required bool isOriginal,
}) {
  final order = ref.watch(ruleOrderProvider);
  final byId = ref.watch(ruleByIdProvider);
  final keywordText = ref.watch(keywordRulesTextProvider);
  final regexText = ref.watch(regexRulesTextProvider);

  var out = raw;
  for (final id in order) {
    if (id == RuleBlockIds.keyword) {
      out = applyKeywordRules(out, keywordText);
    } else if (id == RuleBlockIds.regex) {
      out = applyRegexRules(out, regexText);
    } else {
      final rule = byId[id];
      if (rule == null) continue;
      if (!rule.enabled) continue;
      if (!_inScope(rule, isOriginal: isOriginal)) continue;
      out = applyOneRule(out, rule);
    }
  }
  return out;
}

/// 左边当前显示的文本。
final preprocessedOriginalProvider = Provider<String>((ref) {
  final edited = ref.watch(editedOriginalProvider);
  if (edited != null) return edited;

  final raw = ref.watch(originalRawTextProvider);
  if (raw == null) return '';

  return _runPipeline(ref, raw: raw, isOriginal: true);
});

/// 右边当前显示的文本。
final preprocessedModifiedProvider = Provider<String>((ref) {
  final edited = ref.watch(editedModifiedProvider);
  if (edited != null) return edited;

  final raw = ref.watch(modifiedRawTextProvider);
  if (raw == null) return '';

  return _runPipeline(ref, raw: raw, isOriginal: false);
});
