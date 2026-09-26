import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../../preprocessing/application/builtin_rules.dart';
import '../../../preprocessing/application/preprocessing_service.dart';
import '../../../preprocessing/domain/preprocessing_rule.dart';
import '../../domain/import_source.dart';

/// 正则缓存：同一个 pattern 只编译一次，之后复用。
/// key 里带 multiLine 标志，避免同一个 pattern 用不同 multiLine 时串味。
final Map<String, RegExp> _regexCache = {};

RegExp _cachedRegex(String pattern, {bool multiLine = false}) =>
    _regexCache.putIfAbsent(
      '$multiLine|$pattern',
      () => RegExp(pattern, multiLine: multiLine),
    );

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

/// User-defined preprocessing rules (mutable list).
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

  /// 注意：这里叫 updateRule，因为基类已占用 `update` 这个名字（改值+写盘）。
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

/// Built-in rule enabled-states, keyed by rule id.
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
    // 从当前默认值起步：这样新增的内置规则自动用默认状态，
    // 已经删掉的旧规则 id 也不会被当成有效项保留。
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

  /// 便捷方法：单个规则开关。
  void setOne(String id, bool enabled) {
    update({...state, id: enabled});
  }
}

/// Built-in rules resolved against the user-selected enabled-states.
final builtinRulesWithStateProvider = Provider<List<PreprocessingRule>>((ref) {
  final overrides = ref.watch(builtinRuleEnablesProvider);
  return <PreprocessingRule>[
    for (final r in BuiltinRules.all())
      r.copyWith(enabled: overrides[r.id] ?? r.enabled),
  ];
});

// ==================== 关键词 / 正则替换规则（持久化） ====================
//
// 两段纯文本，一行一条规则：
//   xxx               → 删掉 xxx
//   xxx->=>yyy        → 把 xxx 换成 yyy
//
// 替换串支持转义：\n \r \t \\ \0
//   xxx->=>a\nb       → 把 xxx 换成 "a 换行 b"

/// 关键词规则原文。
final keywordRulesTextProvider =
    NotifierProvider<KeywordRulesTextNotifier, String>(
  KeywordRulesTextNotifier.new,
);

class KeywordRulesTextNotifier extends StringPrefNotifier {
  KeywordRulesTextNotifier() : super(key: PrefKeys.keywordRulesText);
}

/// 正则规则原文。
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
String applyKeywordRules(String text, String rulesText) {
  if (text.isEmpty || rulesText.isEmpty) return text;

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

  var out = text;

  if (deletions.isNotEmpty) {
    deletions.sort((a, b) => b.length.compareTo(a.length));
    try {
      final pattern = deletions.map(RegExp.escape).join('|');
      out = out.replaceAll(_cachedRegex(pattern), '');
    } catch (_) {
      for (final w in deletions) {
        out = out.replaceAll(w, '');
      }
    }
  }

  for (final r in replacements) {
    final repl = _unescapeReplacement(r.replace);
    try {
      out = out.replaceAll(_cachedRegex(RegExp.escape(r.find)), repl);
    } catch (_) {
      out = out.replaceAll(r.find, repl);
    }
  }

  return out;
}

/// 应用正则规则到 [text]。逐条 replaceAll，非法正则跳过。
String applyRegexRules(String text, String rulesText) {
  if (text.isEmpty || rulesText.isEmpty) return text;

  var out = text;
  for (final raw in rulesText.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final idx = line.indexOf('->=>');
    String find;
    String replace;
    if (idx >= 0) {
      find = line.substring(0, idx);
      replace = line.substring(idx + 4);
    } else {
      find = line;
      replace = '';
    }
    if (find.isEmpty) continue;
    try {
      out = out.replaceAll(_cachedRegex(find), _unescapeReplacement(replace));
    } catch (_) {
      // 非法正则忽略，不影响其它规则。
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
