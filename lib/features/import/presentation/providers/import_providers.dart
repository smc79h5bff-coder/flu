import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../preprocessing/application/builtin_rules.dart';
import '../../../preprocessing/application/preprocessing_service.dart';
import '../../../preprocessing/domain/preprocessing_rule.dart';
import '../../domain/import_source.dart';

/// Holds the *raw* text imported from a local file / clipboard.
/// Preprocessing produces the *processed* variant used by diff.
final originalRawTextProvider = StateProvider<String?>((ref) => null);
final modifiedRawTextProvider = StateProvider<String?>((ref) => null);

/// 导入文件的文件名（用于在导入卡片旁展示）。
final originalFileNameProvider = StateProvider<String?>((ref) => null);
final modifiedFileNameProvider = StateProvider<String?>((ref) => null);

/// 导入文件的真实磁盘路径（FilePicker 返回，可能为 null）。用于编辑后
/// “覆盖原文件 + 自动 .bak 备份”；拿不到路径时保存会降级为另存为。
final originalFilePathProvider = StateProvider<String?>((ref) => null);
final modifiedFilePathProvider = StateProvider<String?>((ref) => null);

/// Encoding label surfaced in the export footer.
final originalEncodingProvider = StateProvider<String>((ref) => 'UTF-8');
final modifiedEncodingProvider = StateProvider<String>((ref) => 'UTF-8');

/// Toggles "show processed text" vs "show original text" in the viewer.
/// PRD §2 Module 3.4 — diff is always computed on processed text.
final showProcessedTextProvider = StateProvider<bool>((ref) => false);

/// User-defined preprocessing rules (mutable list).
final userRulesProvider =
    StateNotifierProvider<UserRulesNotifier, List<PreprocessingRule>>(
  (ref) => UserRulesNotifier(),
);

/// Built-in rule enabled-states, keyed by rule id. Lets the user select which
/// built-in rules run during preprocessing (seeded from defaults).
final builtinRuleEnablesProvider =
    StateProvider<Map<String, bool>>((ref) {
  return <String, bool>{
    for (final r in BuiltinRules.all()) r.id: r.enabled,
  };
});

/// Built-in rules resolved against the user-selected enabled-states.
final builtinRulesWithStateProvider = Provider<List<PreprocessingRule>>((ref) {
  final overrides = ref.watch(builtinRuleEnablesProvider);
  return <PreprocessingRule>[
    for (final r in BuiltinRules.all())
      r.copyWith(enabled: overrides[r.id] ?? r.enabled),
  ];
});

class UserRulesNotifier extends StateNotifier<List<PreprocessingRule>> {
  UserRulesNotifier() : super(const []);

  void add(PreprocessingRule rule) => state = [...state, rule];

  void update(PreprocessingRule rule) => state = [
        for (final r in state)
          if (r.id == rule.id) rule else r,
      ];

  void remove(String id) =>
      state = state.where((r) => r.id != id).toList();

  void toggle(String id) => state = [
        for (final r in state)
          if (r.id == id) r.copyWith(enabled: !r.enabled) else r,
      ];

  void importFromJson(List<Map<String, dynamic>> json) =>
      state = json.map(PreprocessingRule.fromJson).toList();
}

// ==================== 关键词 / 正则替换规则 ====================
//
// 两段纯文本，一行一条规则：
//   xxx               → 删掉 xxx
//   xxx->=>yyy        → 把 xxx 换成 yyy
//
// 替换串支持转义：\n \r \t \\ \0
//   xxx->=>a\nb       → 把 xxx 换成 "a 换行 b"
//
// 关键词规则里 xxx / yyy 都是普通文字（特殊字符自动转义）。
// 正则规则里 xxx 是正则，yyy 是普通替换串（$1 $2 是捕获组）。

/// 关键词规则原文。
final keywordRulesTextProvider = StateProvider<String>((ref) => '');

/// 正则规则原文。
final regexRulesTextProvider = StateProvider<String>((ref) => '');

/// 把替换串里的转义序列（\n \r \t \\ \0）转成真正的控制字符。
/// 这样用户能在编辑器里写 `->=>a\nb` 表示"替换成 a 换行 b"。
String _unescapeReplacement(String s) {
  if (!s.contains(r'\')) return s; // 没有反斜杠，直接返回，零开销
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
/// 删除项会合并成一个正则一次扫完；替换项逐条 replaceAll。
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

  // 删除：合并成一个正则，一次扫描。
  if (deletions.isNotEmpty) {
    // 长的排前面，避免短词先命中把长词切碎。
    deletions.sort((a, b) => b.length.compareTo(a.length));
    try {
      final pattern = deletions.map(RegExp.escape).join('|');
      out = out.replaceAll(RegExp(pattern), '');
    } catch (_) {
      for (final w in deletions) {
        out = out.replaceAll(w, '');
      }
    }
  }

  // 替换：逐条（替换串支持转义）。
  for (final r in replacements) {
    final repl = _unescapeReplacement(r.replace);
    try {
      out = out.replaceAll(RegExp(RegExp.escape(r.find)), repl);
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
      out = out.replaceAll(RegExp(find), _unescapeReplacement(replace));
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

/// Bumped whenever a new import succeeds — used by the viewer to know
/// a recomputation is needed.
final importRevisionProvider = StateProvider<int>((ref) => 0);

/// Currently selected import source (for UI affordances).
final selectedSourceProvider =
    StateProvider<ImportSource?>((ref) => null);
