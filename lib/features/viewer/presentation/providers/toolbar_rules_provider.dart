import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../../preprocessing/domain/preprocessing_rule.dart';

/// 对比页按钮栏里的规则。
///
/// 复用 PreprocessingRule 数据结构。以下字段在按钮规则里无意义：
///   - enabled    写死 true
///   - scope      写死 both（点击时弹窗选哪侧，覆盖 scope）
///   - isBuiltin  写死 false
/// UI 上不显示这三个字段。
final toolbarRulesProvider =
    NotifierProvider<ToolbarRulesNotifier, List<PreprocessingRule>>(
  ToolbarRulesNotifier.new,
);

class ToolbarRulesNotifier
    extends PersistentNotifier<List<PreprocessingRule>> {
  @override
  String get key => PrefKeys.toolbarRules;

  @override
  List<PreprocessingRule> get defaultValue => const [];

  @override
  List<PreprocessingRule> decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in list)
        _normalizeForToolbar(
          PreprocessingRule.fromJson(e as Map<String, dynamic>),
        ),
    ];
  }

  @override
  String encode(List<PreprocessingRule> value) =>
      jsonEncode([for (final r in value) r.toJson()]);

  void add(PreprocessingRule rule) {
    final normalized = _normalizeForToolbar(rule);
    update([...state, normalized]);
    ref.read(toolbarOrderProvider.notifier).append(normalized.id);
  }

  void updateRule(PreprocessingRule rule) {
    final normalized = _normalizeForToolbar(rule);
    update([
      for (final r in state)
        if (r.id == normalized.id) normalized else r,
    ]);
  }

  void remove(String id) {
    update(state.where((r) => r.id != id).toList());
    ref.read(toolbarOrderProvider.notifier).removeId(id);
  }

  void setAll(List<PreprocessingRule> rules) {
    update(rules.map(_normalizeForToolbar).toList());
  }
}

/// 把规则里对按钮无意义的字段强制成固定值。
/// 直接构造新对象，避免 copyWith 改不了 isBuiltin 的问题。
PreprocessingRule _normalizeForToolbar(PreprocessingRule r) {
  return PreprocessingRule(
    id: r.id,
    name: r.name,
    kind: r.kind,
    findPattern: r.findPattern,
    replaceWith: r.replaceWith,
    scope: RuleScope.both,
    enabled: true,
    isBuiltin: false,
    script: r.script,
    findRegex: r.findRegex,
    findLiteral: r.findLiteral,
    findEscape: r.findEscape,
    replaceDollar: r.replaceDollar,
    replaceBackslash: r.replaceBackslash,
    replaceLiteral: r.replaceLiteral,
    replaceEscape: r.replaceEscape,
    presetId: r.presetId,
    params: r.params,
    jsScript: r.jsScript,
  );
}

/// 按钮顺序（持久化）。
final toolbarOrderProvider =
    NotifierProvider<ToolbarOrderNotifier, List<String>>(
  ToolbarOrderNotifier.new,
);

class ToolbarOrderNotifier extends PersistentNotifier<List<String>> {
  @override
  String get key => PrefKeys.toolbarOrder;

  @override
  List<String> get defaultValue => const [];

  @override
  List<String> decode(String raw) {
    if (raw.isEmpty) return const [];
    return raw.split('\u0000').where((s) => s.isNotEmpty).toList();
  }

  @override
  String encode(List<String> value) => value.join('\u0000');

  void setAll(List<String> ids) => update(List<String>.from(ids));

  void append(String id) {
    if (state.contains(id)) return;
    update([...state, id]);
  }

  void removeId(String id) {
    if (!state.contains(id)) return;
    update(state.where((s) => s != id).toList());
  }

  void reorder(int oldIndex, int newIndex) {
    final list = List<String>.from(state);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex < 0) newIndex = 0;
    if (newIndex > list.length - 1) newIndex = list.length - 1;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    update(list);
  }
}

/// 合并按钮规则 + 顺序，返回排好序的列表。
final toolbarRulesOrderedProvider =
    Provider<List<PreprocessingRule>>((ref) {
  final rules = ref.watch(toolbarRulesProvider);
  final order = ref.watch(toolbarOrderProvider);

  final byId = <String, PreprocessingRule>{};
  for (final r in rules) byId[r.id] = r;

  final result = <PreprocessingRule>[];
  final seen = <String>{};
  for (final id in order) {
    final r = byId[id];
    if (r != null && !seen.contains(id)) {
      result.add(r);
      seen.add(id);
    }
  }
  // 不在 order 里的兜底补上。
  for (final r in rules) {
    if (!seen.contains(r.id)) result.add(r);
  }
  return result;
});
