import 'dart:convert';

import 'package:flutter/material.dart';
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
    // 同时清掉它的颜色设置。
    ref.read(toolbarButtonColorsProvider.notifier).remove(id);
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

// ==================== 按钮独立颜色 ====================

/// 一个按钮的 3 个颜色。null = 用主题色。
class ToolbarButtonColor {
  const ToolbarButtonColor({this.bg, this.fg, this.border});

  final Color? bg;
  final Color? fg;
  final Color? border;

  bool get isEmpty => bg == null && fg == null && border == null;

  Map<String, dynamic> toJson() => {
        if (bg != null) 'bg': _colorToHex(bg!),
        if (fg != null) 'fg': _colorToHex(fg!),
        if (border != null) 'border': _colorToHex(border!),
      };

  factory ToolbarButtonColor.fromJson(Map<String, dynamic> j) {
    Color? parse(Object? v) =>
        v is String ? _hexToColor(v) : null;
    return ToolbarButtonColor(
      bg: parse(j['bg']),
      fg: parse(j['fg']),
      border: parse(j['border']),
    );
  }
}

String _colorToHex(Color c) {
  final v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color? _hexToColor(String s) {
  if (s.length != 7 || !s.startsWith('#')) return null;
  final v = int.tryParse(s.substring(1), radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// Map<ruleId, ToolbarButtonColor>，持久化。
final toolbarButtonColorsProvider =
    NotifierProvider<ToolbarButtonColorsNotifier,
        Map<String, ToolbarButtonColor>>(
  ToolbarButtonColorsNotifier.new,
);

class ToolbarButtonColorsNotifier
    extends PersistentNotifier<Map<String, ToolbarButtonColor>> {
  @override
  String get key => PrefKeys.toolbarButtonColors;

  @override
  Map<String, ToolbarButtonColor> get defaultValue => const {};

  @override
  Map<String, ToolbarButtonColor> decode(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map(
      (k, v) => MapEntry(
        k,
        ToolbarButtonColor.fromJson(v as Map<String, dynamic>),
      ),
    );
  }

  @override
  String encode(Map<String, ToolbarButtonColor> value) =>
      jsonEncode(value.map((k, v) => MapEntry(k, v.toJson())));

  /// 设置一个按钮的颜色。全部为 null 时删除这条记录。
  void setColor(String id, ToolbarButtonColor color) {
    final next = Map<String, ToolbarButtonColor>.from(state);
    if (color.isEmpty) {
      next.remove(id);
    } else {
      next[id] = color;
    }
    update(next);
  }

  void remove(String id) {
    if (!state.containsKey(id)) return;
    final next = Map<String, ToolbarButtonColor>.from(state)..remove(id);
    update(next);
  }
}
